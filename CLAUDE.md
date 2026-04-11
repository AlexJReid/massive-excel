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
zig build                          # XLL → zig-out/lib/standalone.xll (Windows cross-compile)
zig build massive-cli              # native CLI → zig-out/bin/massive-cli
zig build run-cli -- T.AAPL T.MSFT # build + run CLI (pass channels as trailing args)
```

The `-D` build options still exist but now act as **compile-time defaults**
for fields that `config.json` doesn't override. An unconfigured install will
still build and run against whatever host was baked in. Most users should
ignore the flags and configure via `config.json` at runtime.

```bash
zig build -Dmassive_host=<host>        # default: delayed.massive.com
          -Dmassive_port=<port>        # default: 443
          -Dmassive_path=<path>        # default: /stocks
          -Dmassive_insecure=true      # default: false
```

`massive_path` is interpreted as the **default market** — `/stocks` means
"if the user's topic doesn't name a market, route it to the stocks feed".
Each market the workbook actually subscribes to gets its own connection
regardless; this only decides the default for unqualified topics.

## Runtime config (`config.json`)

Host, port, default path, `insecure`, and `api_key` are loaded at startup
from a JSON file. Search order:

- **Windows XLL:** `<dir containing the XLL>\config.json`, then
  `%APPDATA%\zigxll-massive\config.json`
- **Native CLI:** `./config.json`, then `./src/config.json`

Schema (all fields optional — missing ones fall back to `-D` build defaults):

```json
{
  "host": "delayed.massive.com",
  "port": 443,
  "path": "/stocks",
  "insecure": false,
  "api_key": "pk_live_..."
}
```

**API key precedence:** `$MASSIVE_API_KEY` env var wins over the JSON file.
If neither is set, the RTD worker logs `no API key configured` and the
`init()` pre-flight surfaces a dialog so the user sees the problem on load.

**The config is cached for the life of the process.** Rotating the key now
requires an Excel restart — previously each reconnect re-read
`massive_api_key.txt` from disk. If live key rotation is needed, clear
`cached` in `src/config.zig` on a signal of your choosing.

**`insecure: true` footgun:** disables TLS verification for **every**
connection, including accidental hits against a real endpoint. `onStart`
logs a loud warning when this is set.

## Code layout

- `src/ws_client.zig` — **hand-rolled TLS+WebSocket client.** Sits on top of
  `std.crypto.tls.Client` and `std.net`. Does the RFC 6455 handshake, masked
  frame writes, unmasked frame reads, auto-pong, close handling. ~300 lines.
  Read this first if you're touching anything networking-related.

- `src/massive_protocol.zig` — Massive wire-format helpers. `authenticate()`,
  `subscribe()`, `unsubscribe()`, `parseTopic()`, `defaultFieldFor()`.
  Shared between the RTD handler and the CLI, hence the extraction.

- `src/massive_rtd.zig` — The RTD `Handler` struct plus a pool of
  `MarketConn` structs (one per active market), each with its own worker
  thread, TLS+WS client, channel refcounts, pending sub/unsub queues, and
  frame arena. The Handler owns a flat `topics` map keyed by `topic_id` that
  carries a `market` field, so dispatch from a given MarketConn's worker only
  touches topics belonging to its market. MarketConns are created lazily on
  the first `onConnect` for a new market, and live until `onTerminate`.

- `src/massive_cli.zig` — `main()` for the native CLI. Loads the same API key
  and CA bundle, calls the same `ws_client` and `massive_protocol` helpers,
  prints decoded events.

- `src/functions.zig` — `=MASSIVE(topic[, market])` plus per-event wrappers
  (`=MASSIVE.TRADE`, `=MASSIVE.QUOTE`, ...). All of them accept an optional
  trailing `market` argument that maps to the second RTD string parameter,
  and delegate to `rtd_call.subscribeDynamic`.

- `src/main.zig` — ZigXLL framework entry: declares `function_modules` and
  `rtd_servers`.

- `src/ca_bundle.pem` — Mozilla CA roots from curl.se. Checked in for
  reproducible builds. Regenerate with `curl -sS -L -o src/ca_bundle.pem https://curl.se/ca/cacert.pem`.

- `src/config.zig` — runtime config loader. Parses `config.json` via Win32
  `CreateFileA`/`ReadFile` (std.fs is unreliable in cross-compiled XLL
  context). Exposes `config.load()` which returns a `*const Config` cached
  for the life of the process. Lifts the pattern from
  `../zigxll-nats/src/config.zig`.

- `src/config.json` — gitignored. Deployed alongside the XLL at runtime.
  Schema in the "Runtime config" section above; example at
  `src/config.json.example`.

- `build.zig` — declares Windows XLL (cross-compiled MSVC) and native CLI as
  separate compile units. Build options are plumbed through a single `Options`
  module.

- `tools/mock_server.js` — Node mock Massive server for smoke testing. Speaks
  the real wire protocol (greet → auth → subscribe → stream), emits fake data.
  Requires `npm install ws` and `./tools/gen_cert.sh` first.

- `tools/gen_cert.sh` — one-shot openssl invocation for a self-signed localhost cert.

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

// server data (always an array of events):
[{"ev":"T","sym":"MSFT","p":114.125,"s":100,"t":1536036818784, ...}]
```

Wire channel names are `<ev>.<sym>` (e.g. `T.AAPL`). Our **topic** strings
extend that with an optional `.<field>` suffix (e.g. `T.AAPL.p`). The field
is stripped before subscribing on the wire — many topics can share one
subscription.

## Topic parsing, market routing, and refcounting

`src/massive_protocol.zig:parseTopic` returns `.ev`, `.sym`, `.field`, and
`.channel_len`. The **channel** is always `topic[0..channel_len]`, i.e. the
wire-level string we send to Massive.

The Handler keeps a single flat map:

- `topics: AutoHashMap(topic_id → TopicState)` — one entry per live cell.
  Each `TopicState` carries a `market` field (borrowed from the owning
  `MarketConn.name`) so dispatch and `onDisconnect` know which connection
  the topic belongs to.

Each MarketConn keeps:

- `channel_refs: StringHashMap(channel → refcount)` — decides when to send
  `subscribe` / `unsubscribe` on THIS market's wire. Key is owned by the map.
- `pending_sub: ArrayList([]u8)` + `pending_unsub` — queued actions that the
  worker thread drains between reads.

Refcounts are **per-market**. If two different markets ever had the same
channel name they'd be counted independently, because each lives in a
different MarketConn's map. (In practice the six Massive markets use
distinct event prefixes so this is more defensive than necessary.)

The second RTD string parameter picks the market. `onConnect` reads
`entry.strings[1]` (defaults to the build-option default market),
validates it against `isKnownMarket`, calls `getOrCreateMarketLocked` to
find-or-spawn a MarketConn + worker thread, then updates both `topics`
and the MarketConn's channel_refs. `onDisconnect` reverses this under
the MarketConn's own mutex.

`getOrCreateMarketLocked` is called with `Handler.mu` held. It never takes
`MarketConn.mu`, so there's no lock-order inversion to worry about — the two
mutexes are only ever held in the same order (Handler, then MarketConn) and
only in the onConnect path. `onDisconnect` takes the same order.

### Read loop / latency workaround

Each worker uses `readMessageTimeout` (posix `poll` on the raw socket with a
2s timeout, plus a bufferedness check on the TLS and socket readers so we
never poll away from data that's already arrived). On timeout it loops back
to `flushPending`, so queued sub/unsub actions flush promptly even during
idle periods. The worker also sends a client-initiated WS ping every 20s to
keep NAT mappings warm and surface dead connections.

### Dispatch fan-out

`handleDataMessage` is called from a specific MarketConn's worker. It
acquires `Handler.mu`, iterates `handler.topics`, and **skips any topic
whose `market` field doesn't match `mc.name`**. This is the firewall
between markets: an event off the crypto feed can never accidentally
update a stocks cell even if the `<ev>.<sym>` happens to collide.

## Gotchas, traps, and things that bit me during development

### `std.http.Server.WebSocket` is server-side only

Zig 0.15.1 ships a WebSocket implementation but it's in `std.http.Server`.
It expects the **mask bit set** on reads and writes **unmasked** frames —
the opposite of what RFC 6455 requires for a *client*. The Header structs
(`Header0`, `Header1`, `Opcode`) are reusable but the read/write methods
are not. That's why `ws_client.zig` rolls its own frame I/O.

### `tls.Client.stream()` returns 0 but advances the reader's `end`

This is a Reader/Writer contract mismatch in Zig 0.15.1. The TLS client's
`Reader.stream()` decrypts a whole record into its own buffer and advances
`r.end += cleartext.len` — but **returns 0** to the caller. Combined with
`peekDelimiterInclusive`'s inner loop (`std.mem.indexOfScalarPos(u8, end_cap[0..n], 0, delimiter)`),
this causes an infinite hang: the search slice is empty because `n=0`, but
the data IS in the buffer. `std.http.Client` sidesteps this by using a
hand-rolled HTTP header parser.

**Fix in `ws_client.zig`:** Don't use `takeDelimiterInclusive` on a TLS
reader. Use `takeByte` in a loop instead (see `readLine()`). `takeByte`
goes through `fill → readVec → fillUnbuffered`, which *does* check
`r.end < r.seek + n` in its loop condition, so it terminates correctly
when the TLS client advances `r.end` directly.

Other reader methods that are safe on the TLS reader: `takeByte`, `take`,
`takeArray`, `takeInt`, `peek`, `peekByte`, `fill`, `fillMore`. Unsafe:
`takeDelimiterInclusive`, `peekDelimiterInclusive`, `takeDelimiterExclusive`.

### `tls.Client.writer.flush()` does NOT flush the socket

The TLS client's `flush` encrypts its plaintext buffer into the underlying
socket writer's buffer via `output.advance(...)` — but **never calls
`output.flush()`**. You'll see data sitting in the stream_writer buffer
waiting to go to the kernel. `ws_client.zig` has a `flushChain()` helper
that calls both: `tls_client.writer.flush()` then `stream_writer.interface.flush()`.

This is modeled on `std.http.Client.Connection.flush()`.

### `net.Stream.Reader`/`Writer` and `tls.Client` hold pointers into their own fields

The TLS client stores `input: *Reader` (pointing at a field inside the
`net.Stream.Reader` that owns it) and `output: *Writer`. Moving or copying
the parent struct invalidates those pointers. `Client.connect` therefore
**heap-allocates** the `Client` struct and returns `*Client`, not `Client`.
Callers write `const client = try ws.Client.connect(...); defer client.deinit();`.

### `tls.Client.Options.read_buffer` must be ≥ `tls.Client.min_buffer_len`

The socket reader's buffer (passed to `stream.reader(buf)`) must also be
≥ `min_buffer_len`. The assertion fires deep inside `tls.Client.init`.
`min_buffer_len = max_ciphertext_record_len ≈ 16645`. `ws_client.zig` rounds
up to 16645 + 1024.

### `@embedFile` paths are relative to the importing module's package root

The XLL build uses `src/main.zig` as the user module's root. So
`@embedFile("ca_bundle.pem")` resolves to `src/ca_bundle.pem`, NOT
`ca_bundle.pem` at the repo root. Anything that needs embedding must live
under `src/`.

### Handler lifecycle and `onConnect` vs `onConnectBatch`

From `rtd.zig`: for each new RTD topic, Excel calls `ConnectData`, which
triggers:

1. `onConnect(ctx, topic_id, topic_count)` — called **per-topic**,
   synchronously, BEFORE `onRefreshValue` for the same topic.
2. `onRefreshValue(ctx, topic_id)` — called **inline** right after, to
   provide the initial cell value.
3. `onConnectBatch(ctx, topic_ids[])` — called LATER, once per `RefreshData`
   tick, with all connects accumulated since the last refresh.

**Do topic registration in `onConnect`**, not `onConnectBatch`. Otherwise
events arriving before the next RefreshData cycle will miss the topic in
your `topics` map and be dropped. `massive_rtd.zig` follows this pattern.

### Default allocator is `std.heap.c_allocator`

The ZigXLL framework uses `c_allocator`. This module follows suit — it's
simpler and matches the framework's memory ownership assumptions for
XLOPER12 values. Don't introduce `GeneralPurposeAllocator` in anything
that's shared between the worker thread and the main Excel thread without
a very good reason.

## Testing workflow

- Build clean: `zig build && zig build massive-cli`
- Smoke test: `./tools/gen_cert.sh && npm install ws && node tools/mock_server.js &`
  then write a `src/config.json` with
  `{"host":"localhost","port":8443,"insecure":true,"api_key":"test-key"}`
  and run `zig build run-cli -- T.AAPL T.MSFT`.
- **The mock expects API key `test-key`**. Swap `src/config.json` (or set
  `$MASSIVE_API_KEY`) when pointing at a real endpoint — the config is read
  once per process so an Excel restart / CLI re-run is required.
- Mock-targeting XLL: same binary serves mock and prod now. Use
  `./build-for-mock.sh`, which builds the XLL and writes a mock
  `config.json` next to it. Ship both files to the Windows box. **Still
  keep mock and prod installs in separate directories** — the config file's
  `insecure: true` flag disables TLS verification for every connection, so
  a mock `config.json` must never sit next to a build that might see a real
  endpoint.
- There's no `zig build test` target in this repo - the framework has its own.
  You can add `test` blocks to files under `src/`; run them via
  `zig test src/massive_protocol.zig` directly (it has a small topic-parsing test).

## When in doubt

- Read `src/ws_client.zig` end-to-end — it's only ~300 lines and explains
  every moving part of the TLS/WS layer.
- The Massive wire format is **always an array of events**, even for a
  single event. Always iterate `root.array.items` in dispatch code.
- The RTD handler's worker thread is the *only* one that touches the
  WebSocket. The main thread (Excel callbacks) touches shared state through
  `self.mu`. Keep it that way.
