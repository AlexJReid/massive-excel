# zigxll-connectors-massive

An Excel XLL that streams live market data from the [Massive](https://massive.com) WebSocket API into Excel cells as RTD topics.

Built with [ZigXLL](https://github.com/AlexJReid/zigxll) — everything is pure Zig including the TLS client, the WebSocket framing, and the JSON dispatcher. Zero external dependencies at build time.

## What you can do with it

In any cell:

```
=RTD("zigxll-connectors-massive", , "T.AAPL.p")      last trade price for AAPL
=RTD("zigxll-connectors-massive", , "T.AAPL.s")      last trade size
=RTD("zigxll-connectors-massive", , "Q.MSFT.bp")     MSFT bid price
=RTD("zigxll-connectors-massive", , "Q.MSFT.ap")     MSFT ask price
=RTD("zigxll-connectors-massive", , "AM.TSLA.vw")    TSLA minute-bar VWAP
=RTD("zigxll-connectors-massive", , "AM.TSLA.c")     TSLA minute-bar close
```

Or use the convenience wrapper:

```
=MASSIVE("T.AAPL.p")
```

**Topic format:** `<ev>.<sym>[.<field>]`
- `<ev>` — Massive event prefix: `T` (trades), `Q` (quotes), `AM` (per-minute aggs), `A` (per-second aggs), `FMV` (fair market value), `V` (index value)
- `<sym>` — ticker or pair (e.g. `AAPL`, `BTC-USD`)
- `<field>` — any field name from the Massive message (e.g. `p`, `s`, `bp`, `ap`, `vw`, `c`, `h`, `l`, `o`, `v`). Omit for a sensible default per event type.

**One subscription per channel.** If you have cells for both `T.AAPL.p` and `T.AAPL.s`, only **one** `T.AAPL` subscribe is sent to Massive. All cells update from the same event stream via refcounting.

## Prerequisites

### 1. Zig toolchain

Zig 0.15.1 or later. Install via `brew install zig`, your package manager, or from [ziglang.org/download](https://ziglang.org/download).

### 2. Windows SDK (only needed to build the XLL)

The XLL cross-compiles from mac/linux to Windows using [xwin](https://jake-shadle.github.io/xwin/) to fetch the MSVC headers and libs. Native Windows builds don't need this.

**macOS:**
```bash
brew install xwin
xwin --accept-license splat --output ~/.xwin
```

**Linux:**
```bash
cargo install xwin
xwin --accept-license splat --output ~/.xwin
```

### 3. Massive API key

Copy the example file and drop your key in:

```bash
cp src/massive_api_key.txt.example src/massive_api_key.txt
# edit src/massive_api_key.txt and paste your key
```

The file is `.gitignore`d. The key is embedded into the XLL/CLI at build time via `@embedFile`.

## Build

```bash
zig build              # XLL (zig-out/lib/standalone.xll) — cross-compiles to Windows
zig build massive-cli  # native CLI smoke-tester (zig-out/bin/massive-cli)
```

By default the XLL and CLI connect to `wss://delayed.massive.com/stocks` (15-minute delayed, usually free). Override at build time:

```bash
zig build -Dmassive_host=socket.massive.com -Dmassive_path=/stocks       # real-time feed
zig build -Dmassive_host=socket.massive.com -Dmassive_path=/crypto       # crypto feed
zig build -Dmassive_host=localhost -Dmassive_port=8443 -Dmassive_insecure=true  # local mock
```

Options:
- `-Dmassive_host=<host>` — default `delayed.massive.com`
- `-Dmassive_port=<port>` — default `443`
- `-Dmassive_path=<path>` — default `/stocks`
- `-Dmassive_insecure=true` — skip TLS cert verification (**local mock testing only**)

## Run the XLL in Excel

1. `zig build`
2. Copy `zig-out/lib/standalone.xll` to your Windows box.
3. Unblock the file: right-click → Properties → check **Unblock** → OK. ([Why Excel blocks XLLs](https://support.microsoft.com/en-gb/topic/excel-is-blocking-untrusted-xll-add-ins-by-default-1e3752e2-1177-4444-a807-7b700266a6fb))
4. Double-click the `.xll` to load it into Excel.
5. In a cell: `=MASSIVE("T.AAPL.p")`.

The RTD server registers itself in `HKCU\Software\Classes` on load — no admin needed.

| ProgID | CLSID |
|---|---|
| `zigxll-connectors-massive` | `{C1D2E3F4-A5B6-7890-1234-567890ABCDEF}` |

## Smoke-test without Excel (mac/linux/windows)

Build a native binary that exercises the TLS client, WS framing, auth handshake, and JSON dispatch against a local mock server. Takes ~10 seconds to set up.

**One-time setup:**

```bash
./tools/gen_cert.sh      # generate self-signed TLS cert in tools/cert.pem + tools/key.pem
npm install ws           # install Node WebSocket library
echo 'test-key' > src/massive_api_key.txt   # the mock expects this key
```

**Run:**

```bash
# terminal 1: start the mock Massive server
node tools/mock_server.js

# terminal 2: run the native CLI against it
zig build run-cli \
    -Dmassive_host=localhost -Dmassive_port=8443 -Dmassive_insecure=true \
    -- T.AAPL Q.MSFT AM.TSLA
```

Expected output (on the CLI side):

```
info(massive_cli): host=localhost port=8443 path=/stocks insecure=true
warning(massive_cli): TLS verification disabled
info(massive_cli): connecting...
info(massive_cli): connected
info(massive_cli): authenticated
info(massive_cli): subscribed to 3 channel(s)
< ev=T sym=AAPL x=4 i="631529681" z=3 p=256.7998 s=363 ...
< ev=Q sym=MSFT bp=532.6017 bs=259 ap=532.6217 as=54 t=...
< ev=AM sym=TSLA v=79218 vw=274.6887 o=274 c=274.7387 h=275.2387 l=274.2387 ...
```

Mock server environment variables:
- `MOCK_PORT` — default `8443`
- `MOCK_API_KEY` — default `test-key`
- `MOCK_TICK_MS` — default `500` (how often to emit fake events per subscribed channel)

**Remember** to put your real key back in `src/massive_api_key.txt` before building for production.

## Architecture

```
            ┌──────────────────────────────────────────┐
            │  Excel                                   │
            │    │                                     │
            │    ▼                                     │
            │  =RTD("zigxll-connectors-massive",       │
            │        ,"T.AAPL.p")                      │
            │    │                                     │
            │    ▼                                     │
            │  xlfRtd ─────────► COM RTD server        │  (standalone.xll)
            │                       │                  │
            └───────────────────────┼──────────────────┘
                                    │ onConnect / onRefreshValue
                                    ▼
            ┌──────────────────────────────────────────┐
            │  massive_rtd.zig                         │
            │    Handler (refcount channels,           │
            │     dispatch events, fill cell values)   │
            │                     ▲                    │
            │                     │  worker thread     │
            │                     │                    │
            │  ws_client.zig ─ Massive WebSocket       │
            │    (TLS + RFC 6455 + auto-pong)          │
            │                     │                    │
            └─────────────────────┼────────────────────┘
                                  │
                                  ▼
                        wss://delayed.massive.com/stocks
```

Key source files:

| File | Purpose |
|---|---|
| `src/ws_client.zig` | TLS + WebSocket client. HTTP upgrade handshake, masked frame writes, unmasked frame reads, auto-pong. Pure std.crypto.tls + std.net. |
| `src/massive_protocol.zig` | Massive wire protocol helpers (greet → auth → subscribe) and topic parsing. Shared between the RTD handler and the CLI. |
| `src/massive_rtd.zig` | RTD handler: spawns worker thread, refcounts subscriptions per channel, parses incoming events, updates cell values. |
| `src/massive_cli.zig` | Native CLI smoke-tester. Connects, auths, subscribes, prints every incoming event. |
| `src/functions.zig` | The `=MASSIVE(topic)` convenience wrapper function. |
| `src/main.zig` | Framework entry — registers the function module and RTD server. |
| `src/ca_bundle.pem` | Mozilla CA roots from [curl.se](https://curl.se/ca/cacert.pem). Checked in for reproducible builds. |
| `build.zig` | Build graph: Windows XLL + native CLI + build options. |
| `tools/gen_cert.sh` | One-shot openssl script to generate a self-signed cert for the mock server. |
| `tools/mock_server.js` | Node mock Massive WebSocket server — speaks the real wire protocol with fake data. |

## Known limitations

- **Sub/unsub latency between market hours.** The worker thread blocks in `readMessage` and only flushes the pending sub/unsub queue between incoming frames. Intraday this is sub-second. Off-hours, adding a new cell won't actually subscribe until any frame arrives.
- **64 KiB single-frame cap.** Fragmented or huge frames will error. Safe for the Massive wire format (messages are small).
- **Reconnect.** On drop, the worker reconnects with a fixed 2s backoff forever, re-authenticates, and re-subscribes to all currently-live channels.
- **TLS truncation attacks.** `allow_truncation_attacks` is enabled on the TLS client, which is fine for WebSocket framing (frame headers carry the length). Don't copy this setup for HTTP-with-no-content-length.
