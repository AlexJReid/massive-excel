# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this is

An Excel XLL that streams live market data from the **Massive** WebSocket API
into Excel cells via RTD. Also ships a **native CLI** that exercises the same
TLS+WS+JSON stack on mac/linux/windows without needing Excel.

Built on the [ZigXLL](https://github.com/AlexJReid/zigxll) framework. No C deps,
no npm deps for the XLL itself. The mock server uses `ws` (Node) only for local
smoke testing.

## Build commands

```bash
zig build                          # XLL → zig-out/lib/standalone.xll (Windows cross-compile)
zig build massive-cli              # native CLI → zig-out/bin/massive-cli
zig build run-cli -- T.AAPL T.MSFT # build + run CLI (pass channels as trailing args)
```

Build options (flow through to both the XLL and the CLI via an `Options` module):

```bash
zig build -Dmassive_host=<host>        # default: delayed.massive.com
          -Dmassive_port=<port>        # default: 443
          -Dmassive_path=<path>        # default: /stocks
          -Dmassive_insecure=true      # skip TLS verification (LOCAL MOCK ONLY)
```

## Code layout

- `src/ws_client.zig` — **hand-rolled TLS+WebSocket client.** Sits on top of
  `std.crypto.tls.Client` and `std.net`. Does the RFC 6455 handshake, masked
  frame writes, unmasked frame reads, auto-pong, close handling. ~300 lines.
  Read this first if you're touching anything networking-related.

- `src/massive_protocol.zig` — Massive wire-format helpers. `authenticate()`,
  `subscribe()`, `unsubscribe()`, `parseTopic()`, `defaultFieldFor()`.
  Shared between the RTD handler and the CLI, hence the extraction.

- `src/massive_rtd.zig` — The RTD `Handler` struct + worker thread. Where
  most of the interesting business logic lives: topic registration, per-channel
  refcounting, JSON event dispatch, reconnect loop.

- `src/massive_cli.zig` — `main()` for the native CLI. Loads the same API key
  and CA bundle, calls the same `ws_client` and `massive_protocol` helpers,
  prints decoded events.

- `src/functions.zig` — The `=MASSIVE(topic)` convenience wrapper (an
  `ExcelFunction` that calls `rtd_call.subscribeDynamic`).

- `src/main.zig` — ZigXLL framework entry: declares `function_modules` and
  `rtd_servers`.

- `src/ca_bundle.pem` — Mozilla CA roots from curl.se. Checked in for
  reproducible builds. Regenerate with `curl -sS -L -o src/ca_bundle.pem https://curl.se/ca/cacert.pem`.

- `src/config.zig` — runtime loader for the Massive API key. Checks
  `$MASSIVE_API_KEY` first, then falls back to `massive_api_key.txt`: the XLL
  reads it from the directory containing the `.xll` file (via
  `GetModuleFileNameA`); the native CLI reads from `./massive_api_key.txt`
  then `./src/massive_api_key.txt`. Key is re-loaded on every reconnect, so
  rotating it takes effect without a rebuild.

- `src/massive_api_key.txt` — gitignored. Deployed alongside the XLL at runtime;
  NOT `@embedFile`'d. There's a `.example` file in the repo.

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

## Topic parsing and refcounting

`src/massive_protocol.zig:parseTopic` returns `.ev`, `.sym`, `.field`, and
`.channel_len`. The **channel** is always `topic[0..channel_len]`, i.e. the
wire-level string we send to Massive.

The RTD handler keeps:

- `topics: AutoHashMap(topic_id → TopicState)` — one entry per live cell.
- `channel_refs: StringHashMap(channel → refcount)` — decides when to send
  `subscribe` and `unsubscribe`. Key is **owned** by the map.

Two cells for `T.AAPL.p` and `T.AAPL.s` share one wire subscription:
first `onConnect` inc's refcount from 0 to 1 and queues `subscribe T.AAPL`;
second `onConnect` inc's from 1 to 2, queues nothing. `onDisconnect`
decrements; at 0 it queues `unsubscribe T.AAPL`.

The worker thread drains these queues between incoming messages. **Known
latency:** off-hours (no incoming traffic), queued sub/unsub won't flush until
any frame arrives. Acceptable for a first cut, not trivial to fix without
non-blocking I/O.

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
  then `zig build run-cli -Dmassive_host=localhost -Dmassive_port=8443 -Dmassive_insecure=true -- T.AAPL T.MSFT`
- **The mock expects API key `test-key`**. Put the real key back in
  `src/massive_api_key.txt` (the CLI reads from there) before testing
  against the real endpoint. No rebuild required — the key is loaded at
  runtime on every reconnect.
- There's no `zig build test` target in this repo — the framework has its own.
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
