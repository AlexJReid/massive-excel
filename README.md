# zigxll-connectors-massive

An Excel XLL that streams live market data from the [Massive](https://massive.com) WebSocket API into Excel cells as RTD topics.

Built with [ZigXLL](https://github.com/AlexJReid/zigxll) — everything is pure Zig including the TLS client, the WebSocket framing, and the JSON dispatcher. Zero external dependencies at build time.

## What you can do with it

In any cell:

```
=RTD("zigxll.connectors.massive", , "T.AAPL.p")                 last trade price for AAPL (default market)
=RTD("zigxll.connectors.massive", , "T.AAPL.s")                 last trade size
=RTD("zigxll.connectors.massive", , "Q.MSFT.bp")                MSFT bid price
=RTD("zigxll.connectors.massive", , "Q.MSFT.ap")                MSFT ask price
=RTD("zigxll.connectors.massive", , "AM.TSLA.vw")               TSLA minute-bar VWAP
=RTD("zigxll.connectors.massive", , "XT.BTC-USD.p", "crypto")   BTC-USD last trade on the /crypto feed
=RTD("zigxll.connectors.massive", , "C.EUR/USD.a", "forex")     EUR/USD ask on the /forex feed
```

The optional second string picks the **market** — `stocks`, `options`, `forex`, `crypto`, `indices`, or `futures`. Omit it to use the default market baked into the build (see `-Dmassive_path`). The handler lazily opens a dedicated WebSocket for each market the workbook asks for, and keeps it alive for the session.

**Your Massive plan decides which markets you can actually reach.** Subscribing to a market your API key isn't entitled to will fail auth; the RTD handler logs the status message and the affected cells show `#N/A`. See the [Massive pricing page](https://massive.com/pricing) for which plans include which markets. You need a plan that supports websockets.

Or use a convenience wrapper — `=MASSIVE(topic, [market])` takes the full topic string and optional market, and there's one per-event-type wrapper that takes `sym`, optional `field`, and optional `market`:

```
=MASSIVE("T.AAPL.p")                  stocks (default market)
=MASSIVE("XT.BTC-USD.p", "crypto")    crypto feed
=MASSIVE("C.EUR/USD.a", "forex")      forex feed

=MASSIVE.TRADE("AAPL")                T.AAPL         (default field: p)
=MASSIVE.TRADE("AAPL", "s")           T.AAPL.s
=MASSIVE.TRADE("BTC-USD", "p", "crypto")  T.BTC-USD.p on /crypto
=MASSIVE.QUOTE("MSFT", "bp")          Q.MSFT.bp      (default field: ap)
=MASSIVE.AGG_MIN("TSLA", "vw")        AM.TSLA.vw     (default field: c)
=MASSIVE.AGG_SEC("TSLA")              A.TSLA         (default field: c)
=MASSIVE.FMV("AAPL")                  FMV.AAPL       (default field: fmv)
=MASSIVE.INDEX("SPX")                 V.SPX on /indices  (default field: val)
```

All wrappers delegate to the same RTD server, so subscription refcounting is shared — `=MASSIVE.TRADE("AAPL","p")` and `=RTD(..., "T.AAPL.p")` share one wire subscription. Refcounts are **per-market**, so the same `T.AAPL.p` topic routed to `stocks` vs (hypothetically) another market would be two independent subscriptions.

**Topic format:** `<ev>.<sym>[.<field>]`
- `<ev>` — Massive event prefix: `T` (trades), `Q` (quotes), `AM` (per-minute aggs), `A` (per-second aggs), `FMV` (fair market value), `V` (index value)
- `<sym>` — ticker or pair (e.g. `AAPL`, `BTC-USD`)
- `<field>` — any field name from the Massive message (e.g. `p`, `s`, `bp`, `ap`, `vw`, `c`, `h`, `l`, `o`, `v`). Omit for a sensible default per event type.

**One subscription per channel.** If you have cells for both `T.AAPL.p` and `T.AAPL.s`, only **one** `T.AAPL` subscribe is sent to Massive. All cells update from the same event stream via refcounting. Once all `T.AAPL.*` topics are removed, the unsubscribe is sent.

## Prerequisites

### 1. Zig toolchain

Zig 0.15.1 or later. Install via `brew install zig`, your package manager, or from [ziglang.org/download](https://ziglang.org/download).

### 2. Windows SDK (only needed to build the XLL)

The XLL cross-compiles from macOS/linux to Windows using [xwin](https://jake-shadle.github.io/xwin/) to fetch the MSVC headers and libs. Native Windows builds don't need this.

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

Setup your Massive account. Grab an API key. Copy the example file and drop your key in:

```bash
cp src/massive_api_key.txt.example src/massive_api_key.txt
# edit src/massive_api_key.txt and paste your key
```

The key is loaded at **runtime**, not embedded — so you ship one XLL and drop `massive_api_key.txt` next to it (see [Run the XLL in Excel](#run-the-xll-in-excel)). The CLI reads it from `./massive_api_key.txt` or `./src/massive_api_key.txt`. The file is `.gitignore`d.

Alternatively, set the `MASSIVE_API_KEY` environment variable — it takes precedence over the file. Handy for CI or ephemeral shells where you don't want the key on disk.

The key is re-read on every reconnect, so rotating it (on disk or in the env) takes effect without a rebuild.

## Build

```bash
zig build              # XLL (zig-out/lib/standalone.xll) — cross-compiles to Windows
zig build massive-cli  # native CLI smoke-tester (zig-out/bin/massive-cli)
```

By default the XLL and CLI connect to `wss://delayed.massive.com` and use `/stocks` as the **default market** (15-minute delayed, usually free). A single build can talk to any market your API key allows — cells pick the market at runtime via the optional second RTD parameter.

Host / port / default path / TLS behaviour / API key are all configured at **runtime** via a `config.json` file dropped next to the XLL (or in `%APPDATA%\zigxll-massive\`). Same binary serves mock and prod; the config file decides. Example:

```json
{
  "host": "socket.massive.com",
  "port": 443,
  "path": "/stocks",
  "insecure": false,
  "api_key": "pk_live_..."
}
```

See `src/config.json.example` for a template. All fields are optional — missing ones fall back to compile-time defaults. `$MASSIVE_API_KEY` in the environment overrides `api_key` if both are set.

The `-Dmassive_*` build flags still exist and set the **compile-time defaults** used when no config file is present, for reproducible CI builds. Most users should ignore them.

**Access is plan-dependent.** Massive sells market access per asset class; a given API key will only authenticate against markets your plan covers. A connection to a non-entitled market will fail auth — the affected cells show `#N/A`.

## Run the XLL in Excel

1. `zig build`
2. Copy `zig-out/lib/massive_excel.xll` to your Windows box.
3. Drop a `config.json` **in the same directory** as the XLL, containing at least `{"api_key":"pk_live_..."}`. See `src/config.json.example` for the full schema. Alternatively set `MASSIVE_API_KEY` in the environment before launching Excel.
4. Unblock the file: right-click → Properties → check **Unblock** → OK. ([Why Excel blocks XLLs](https://support.microsoft.com/en-gb/topic/excel-is-blocking-untrusted-xll-add-ins-by-default-1e3752e2-1177-4444-a807-7b700266a6fb))
5. Double-click the `.xll` to load it into Excel.
6. In a cell: `=MASSIVE("T.AAPL.p")`.

The RTD server registers itself in `HKCU\Software\Classes` on load — no admin needed.

| ProgID | CLSID |
|---|---|
| `zigxll.connectors.massive` | `{D146815B-1D01-4D0D-904C-292533090438}` |

## Smoke-test without Excel (mac/linux/windows)

Build a native binary that exercises the TLS client, WS framing, auth handshake, and JSON dispatch against a local mock server. Takes ~10 seconds to set up.

**One-time setup:**

```bash
./tools/gen_cert.sh      # generate self-signed TLS cert in tools/cert.pem + tools/key.pem
npm install ws           # install Node WebSocket library
cat > src/config.json <<'EOF'
{ "host": "localhost", "port": 8443, "insecure": true, "api_key": "test-key" }
EOF
```

**Run:**

```bash
# terminal 1: start the mock Massive server
node tools/mock_server.js

# terminal 2: run the native CLI against it (reads src/config.json)
zig build run-cli -- T.AAPL Q.MSFT AM.TSLA

# to exercise a non-default market path:
zig build run-cli -- --market crypto XT.BTC-USD
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

**Remember** to swap `src/config.json` back to your real key / endpoint before running the CLI against production. (The XLL reads its own `config.json` from the directory it's loaded from, so its config file isn't affected by mock-server testing.)

### Pointing the XLL itself at the mock server

Same XLL binary now serves mock and prod — the config file decides. Use `./build-for-mock.sh`: it builds the XLL and writes a `config.json` next to it with `insecure: true`, `api_key: "test-key"`, and your LAN IP as the host.

```bash
./build-for-mock.sh
# outputs: zig-out/lib/massive_excel.xll + zig-out/lib/config.json
```

Then on the Windows side:

1. Copy **both** `massive_excel.xll` and `config.json` from `zig-out/lib/` to the Windows box, into the **same directory**.
2. Start the mock server somewhere reachable from the Windows box: `node tools/mock_server.js`.
3. The mock's self-signed cert doesn't need to match any trust store — `insecure: true` in the config skips verification.
4. Load the XLL in Excel, type `=MASSIVE("T.AAPL.p")`, confirm fake ticks arrive.
5. Multi-market smoke test: `=MASSIVE("XT.BTC-USD.p","crypto")` + `=MASSIVE("T.AAPL.p","stocks")` in two cells should open two separate WebSocket connections (the mock accepts any path) and the debug log (OutputDebugString, visible in DebugView) will show `[stocks]` and `[crypto]` worker lines.

**Critical:** `insecure: true` skips TLS cert verification for **every** connection the XLL makes, including any real endpoint. Keep mock and prod installs in separate directories — the _config file_, not the binary, is the thing that must never sit next to a production endpoint.

## Architecture

```
            ┌──────────────────────────────────────────┐
            │  Excel                                   │
            │    │                                     │
            │    ▼                                     │
            │  =RTD("zigxll.connectors.massive",       │
            │        ,"T.AAPL.p","stocks")             │
            │    │                                     │
            │    ▼                                     │
            │  xlfRtd ─────────► COM RTD server        │  (massive_excel.xll)
            │                       │                  │
            └───────────────────────┼──────────────────┘
                                    │ onConnect / onRefreshValue
                                    ▼
            ┌──────────────────────────────────────────┐
            │  massive_rtd.zig                         │
            │    Handler (flat topics map,             │
            │     routes each topic to a MarketConn    │
            │     by market name)                      │
            │        │                │                │
            │        ▼                ▼                │
            │  MarketConn(stocks) MarketConn(crypto)   │
            │    worker thread     worker thread       │
            │    refcount+queues   refcount+queues     │
            │        │                │                │
            │  ws_client.zig ─ TLS + RFC 6455          │
            │    (one Client per MarketConn)           │
            │        │                │                │
            └────────┼────────────────┼────────────────┘
                     │                │
                     ▼                ▼
             wss://.../stocks    wss://.../crypto
```

Key source files:

| File | Purpose |
|---|---|
| `src/ws_client.zig` | TLS + WebSocket client. HTTP upgrade handshake, masked frame writes, unmasked frame reads, auto-pong. Pure std.crypto.tls + std.net. |
| `src/massive_protocol.zig` | Massive wire protocol helpers (greet → auth → subscribe) and topic parsing. Shared between the RTD handler and the CLI. |
| `src/massive_rtd.zig` | RTD handler: owns a pool of per-market `MarketConn`s, each with its own worker thread, TLS+WS client, and channel refcounts. Routes topics based on the optional second RTD parameter (market name). |
| `src/massive_cli.zig` | Native CLI smoke-tester. Connects, auths, subscribes, prints every incoming event. |
| `src/functions.zig` | The `=MASSIVE(topic)` convenience wrapper function. |
| `src/main.zig` | Framework entry — registers the function module and RTD server. |
| `src/ca_bundle.pem` | Mozilla CA roots from [curl.se](https://curl.se/ca/cacert.pem). Checked in for reproducible builds. |
| `build.zig` | Build graph: Windows XLL + native CLI + build options. |
| `tools/gen_cert.sh` | One-shot openssl script to generate a self-signed cert for the mock server. |
| `tools/mock_server.js` | Node mock Massive WebSocket server — speaks the real wire protocol with fake data. |

## Known limitations

- **Market access depends on your Massive plan.** Each market (`stocks`, `options`, `forex`, `crypto`, `indices`, `futures`) is a separate WebSocket endpoint. You can only connect to markets your API key is entitled to. The handler opens a connection lazily when the first topic for a market appears; if auth fails, the worker logs the status message and retries on the 2s reconnect timer. Cells pointed at unauthorized markets stay `#N/A`.
- **One connection per market.** Massive doesn't offer a multiplexed endpoint — each market is its own `wss://.../<market>` URL. The handler holds one connection per active market and shares it across all cells on that market.
- **Sub/unsub latency between market hours.** Each worker uses a 2s `poll`-gated read (`readMessageTimeout`) so queued sub/unsub actions flush on the next tick even when the server is idle. It also sends a client-initiated WS ping every 20s to keep NAT mappings warm. Intraday latency is sub-second; worst-case off-hours latency is the poll interval.
- **64 KiB single-frame cap.** Fragmented or huge frames will error. Safe for the Massive wire format (messages are small).
- **Reconnect.** On drop, the worker reconnects with a fixed 2s backoff forever, re-authenticates, and re-subscribes to all currently-live channels.
