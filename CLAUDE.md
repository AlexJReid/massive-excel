# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this is

An Excel XLL that streams live market data from the **Massive** WebSocket API
into Excel cells via RTD. Also ships a **native CLI** that exercises the same
TLS+WS+JSON stack on mac/linux/windows without needing Excel.

Massive exposes one WebSocket per asset-class market (`wss://.../stocks`,
`wss://.../crypto`, `.../forex`, `.../options`, `.../indices`, `.../futures`).
A single connection can only carry channels for one market, so the RTD
handler holds a **pool** of per-market connections, each with its own worker
thread. Which markets you can actually reach is determined by your API key's
Massive plan entitlements — cells referencing unauthorized markets will fail
auth and stay `#N/A`. Nothing in the XLL knows ahead of time what you're
entitled to.

Built on the [ZigXLL](https://github.com/AlexJReid/zigxll) framework. No C deps,
no npm deps for the XLL itself. The mock server uses `ws` (Node) only for local
smoke testing.

## Build commands

```bash
zig build                          # XLL → zig-out/lib/massive_excel.xll (Windows cross-compile)
zig build massive-cli              # native CLI → zig-out/bin/massive-cli
zig build run-cli -- T.AAPL T.MSFT # build + run CLI (pass channels as trailing args)
```

`-D` build options (`massive_host`, `massive_port`, `massive_path`,
`massive_insecure`) supply **compile-time defaults** for fields that
`config.json` doesn't override. Most users should ignore them and configure
via `config.json` at runtime. `massive_path` is the **default market** —
`/stocks` means "if a topic's market arg is empty, route it to stocks". Each
market the workbook actually subscribes to gets its own connection regardless.

## Runtime config

Loaded once at process start from `config.json`. Full search order, schema,
and API-key precedence rules live in the header comment of `src/config.zig` —
read that file, don't duplicate it here. Two things worth knowing that aren't
obvious from the code:

- **Config is cached for the life of the process.** Rotating the API key
  requires an Excel restart. If you ever need live rotation, clear `cached`
  in `src/config.zig` on a signal.
- **`insecure: true` footgun.** Disables TLS verification for **every**
  connection on that process, including accidental hits against a real
  endpoint. Keep mock and prod installs in separate directories — never let
  a mock `config.json` sit next to a build that might see prod. `onStart`
  logs a loud warning when this is set.

## Key files

The layout is mostly self-explanatory — `ls src/` and read the file header
comments. Only these need extra context:

- `src/ws_client.zig` — **hand-rolled TLS+WebSocket client** on top of
  `std.crypto.tls.Client` and `std.net`. ~475 lines. If you're touching
  anything networking-related, read this first — the Gotchas section below
  only makes sense in the context of this file.
- `src/massive_rtd.zig` — the RTD `Handler` plus a pool of `MarketConn`
  structs (one per active market, each with its own worker thread, TLS+WS
  client, channel refcounts, pending sub/unsub queues). See "Topic routing"
  below for the data flow.
- `src/config.zig` — runtime config loader. Uses Win32 `CreateFileA`/
  `ReadFile` rather than `std.fs` because the latter is unreliable in
  cross-compiled XLL context. Pattern lifted from `../zigxll-nats/src/config.zig`.
- `src/ca_bundle.pem` — Mozilla CA roots from curl.se. Regenerate with
  `curl -sS -L -o src/ca_bundle.pem https://curl.se/ca/cacert.pem`.

## Wire protocol (from the Massive docs)

```json
// server greet on connect:
[{"ev":"status","status":"connected","message":"Connected Successfully"}]

// client auth:
{"action":"auth","params":"YOUR_API_KEY"}

// server confirmation:
[{"ev":"status","status":"auth_success","message":"authenticated"}]

// client subscribe:
{"action":"subscribe","params":"T.AAPL,T.MSFT,AM.TSLA"}

// server data (always an array of events, even for a single event):
[{"ev":"T","sym":"MSFT","p":114.125,"s":100,"t":1536036818784, ...}]
```

Wire channel names are `<ev>.<sym>` (e.g. `T.AAPL`). Our **topic** strings
extend that with an optional `.<field>` suffix (e.g. `T.AAPL.p`). The field
is stripped before subscribing on the wire — many topics can share one
subscription. `massive_protocol.zig:parseTopic` returns `.channel_len` so
`topic[0..channel_len]` is always the wire channel.

## Topic routing, refcounting, and cross-market dispatch

The Handler owns a single flat `topics: AutoHashMap(topic_id → TopicState)`,
where each `TopicState` carries a `market` field borrowed from the owning
`MarketConn.name`. Each MarketConn owns its own `channel_refs: StringHashMap`
(refcount per wire channel for THIS market) and `pending_sub`/`pending_unsub`
queues drained by the worker thread.

Refcounts are **per-market**. Two markets with a colliding channel name would
be counted independently — defensive, since the six Massive markets already
use distinct event prefixes.

**Lock ordering**: `getOrCreateMarketLocked` is called with `Handler.mu`
held, and never takes `MarketConn.mu`. The two mutexes are only ever acquired
in the order (Handler, then MarketConn). `onConnect` and `onDisconnect` both
follow this order. Don't break the invariant — there's no inversion to worry
about today precisely because of this.

**Dispatch firewall**: `handleDataMessage` runs on a specific MarketConn's
worker. It takes `Handler.mu`, iterates `handler.topics`, and **skips any
topic whose `market` field doesn't match `mc.name`**. This is the only thing
preventing an event off the crypto feed from updating a stocks cell when
`<ev>.<sym>` happens to collide.

**Read loop**: each worker uses `readMessageTimeout` (posix `poll` on the raw
socket with a 2s timeout, plus a bufferedness check on both TLS and socket
readers so we never poll away from already-arrived data). On timeout it loops
back to `flushPending` so queued sub/unsub actions flush promptly even during
idle periods. Workers send a client-initiated WS ping every 20s to keep NAT
mappings warm and surface dead connections.

## Gotchas that will bite you

### `std.http.Server.WebSocket` is server-side only

Zig 0.15.1 ships a WebSocket implementation but it's in `std.http.Server`.
It expects the **mask bit set** on reads and writes **unmasked** frames —
the opposite of what RFC 6455 requires for a *client*. The `Header0`/
`Header1`/`Opcode` types are reusable; the read/write methods are not.
That's why `ws_client.zig` rolls its own frame I/O.

### `tls.Client.stream()` returns 0 but advances the reader's `end`

Reader/Writer contract mismatch in Zig 0.15.1. The TLS client's
`Reader.stream()` decrypts a whole record into its own buffer and advances
`r.end += cleartext.len` — but **returns 0** to the caller. Combined with
`peekDelimiterInclusive`'s inner loop (`indexOfScalarPos(u8, end_cap[0..n], 0, delimiter)`),
this hangs forever: the search slice is empty because `n=0`, but the data
IS in the buffer. `std.http.Client` sidesteps it via a hand-rolled HTTP
header parser.

**Fix**: don't use `takeDelimiterInclusive` on a TLS reader. Use `takeByte`
in a loop (see `readLine()`). `takeByte` goes through
`fill → readVec → fillUnbuffered`, which checks `r.end < r.seek + n` in its
loop condition and terminates correctly when the TLS client advances `r.end`
directly.

Safe on the TLS reader: `takeByte`, `take`, `takeArray`, `takeInt`, `peek`,
`peekByte`, `fill`, `fillMore`. Unsafe: `takeDelimiterInclusive`,
`peekDelimiterInclusive`, `takeDelimiterExclusive`.

### `tls.Client.writer.flush()` does NOT flush the socket

`flush` encrypts plaintext into the underlying socket writer's buffer via
`output.advance(...)` — but **never calls `output.flush()`**. Data sits in
the stream_writer buffer waiting for the kernel. `ws_client.zig` has a
`flushChain()` helper that calls both: `tls_client.writer.flush()` then
`stream_writer.interface.flush()`. Modeled on
`std.http.Client.Connection.flush()`.

### `tls.Client` holds pointers into its parent's fields

`tls.Client` stores `input: *Reader` (pointing at a field inside the
`net.Stream.Reader` that owns it) and `output: *Writer`. Moving or copying
the parent struct invalidates those pointers. `ws.Client.connect`
**heap-allocates** the `Client` struct and returns `*Client`. Callers:
`const client = try ws.Client.connect(...); defer client.deinit();`.

### TLS buffer sizing

`tls.Client.Options.read_buffer` must be ≥ `tls.Client.min_buffer_len`. The
socket reader's buffer (passed to `stream.reader(buf)`) must also be
≥ `min_buffer_len`. The assertion fires deep inside `tls.Client.init`.
`min_buffer_len = max_ciphertext_record_len ≈ 16645`. `ws_client.zig` uses
`16645 + 1024`.

### `@embedFile` paths are relative to the importing module's package root

The XLL build uses `src/main.zig` as the user module's root, so
`@embedFile("ca_bundle.pem")` resolves to `src/ca_bundle.pem`, NOT
`ca_bundle.pem` at the repo root. Anything embedded must live under `src/`.

### Do RTD topic registration in `onConnect`, not `onConnectBatch`

For each new RTD topic, Excel calls `ConnectData`, which triggers:

1. `onConnect(ctx, topic_id, topic_count)` — per-topic, synchronously,
   BEFORE `onRefreshValue` for the same topic.
2. `onRefreshValue(ctx, topic_id)` — inline, provides the initial cell value.
3. `onConnectBatch(ctx, topic_ids[])` — LATER, once per `RefreshData` tick,
   with all connects accumulated since the last refresh.

Register topics in step 1. If you wait for step 3, events arriving before
the next RefreshData cycle will miss the topic in your `topics` map and be
dropped. `massive_rtd.zig` follows this pattern.

### Allocator: `std.heap.c_allocator`

The ZigXLL framework uses `c_allocator` and this module follows suit —
matches the framework's memory ownership assumptions for XLOPER12 values.
Don't introduce `GeneralPurposeAllocator` in anything shared between the
worker thread and the main Excel thread without a very good reason.

### The worker thread is the only one that touches the WebSocket

Main thread (Excel callbacks) touches shared state only through `self.mu`.
Keep it that way.

## Smoke testing against the mock

```bash
./tools/gen_cert.sh && npm install ws && node tools/mock_server.js &
# write src/config.json pointing at localhost:8443 with api_key "test-key"
zig build run-cli -- T.AAPL T.MSFT
```

The mock expects API key `test-key`. For mock-targeting XLL builds use
`./build-for-mock.sh`, which writes a mock `config.json` next to the XLL —
see the `insecure: true` footgun warning above before shipping it anywhere.

No `zig build test` target — the framework has its own. Per-file tests run
directly: `zig test src/massive_protocol.zig`.
