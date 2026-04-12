# tools/

Mock server and utilities for local development and testing.

## Prerequisites

```bash
./tools/gen_cert.sh   # generate self-signed TLS cert (one-time)
npm install ws        # WebSocket server dependency (one-time)
```

## mock_server.js

Local WebSocket server that speaks the Massive wire protocol (greet, auth,
subscribe, data). Runs on `wss://0.0.0.0:8443/` by default.

### Synthetic mode (default)

Generates random price data for any subscribed channel:

```bash
node tools/mock_server.js
```

### Replay mode

Replays historical data from a Massive flat file (gzipped or plain NDJSON),
preserving real inter-event timing:

```bash
MOCK_REPLAY_FILE=data/stocks_trades_2026-04-10.json.gz node tools/mock_server.js
```

Events are sent at their original wall-clock rate. Use `MOCK_REPLAY_SPEED`
to control playback speed:

| `MOCK_REPLAY_SPEED` | Effect                              |
|----------------------|-------------------------------------|
| `1` (default)        | Real-time                           |
| `60`                 | 60x fast-forward (~6.5 min per day) |
| `0`                  | Firehose, no delays                 |

Only events matching the client's current subscriptions are sent. When the
file ends, playback loops by default (`MOCK_REPLAY_LOOP=false` to stop).

### Environment variables

| Variable            | Default      | Description                        |
|---------------------|--------------|------------------------------------|
| `MOCK_PORT`         | `8443`       | Listen port                        |
| `MOCK_API_KEY`      | `test-key`   | Expected API key for auth          |
| `MOCK_TICK_MS`      | `500`        | Synthetic tick interval (ms)       |
| `MOCK_REPLAY_FILE`  | *(empty)*    | Path to flat file; enables replay  |
| `MOCK_REPLAY_SPEED` | `1`          | Playback speed multiplier          |
| `MOCK_REPLAY_LOOP`  | `true`       | Loop when file ends                |

### Connecting from the CLI

```bash
zig build run-cli -- T.AAPL T.MSFT
# (with a config.json pointing at localhost:8443, insecure: true)
```

Or with build flags:

```bash
zig build run-cli -Dmassive_host=localhost -Dmassive_port=8443 -Dmassive_insecure=true -- T.AAPL T.MSFT
```

## fetch_flatfile.js

Downloads a Massive flat file (gzipped CSV from their S3-compatible endpoint)
for use with replay mode. Requires S3 credentials from your Massive dashboard.

```bash
export MASSIVE_S3_ACCESS_KEY=your_access_key
export MASSIVE_S3_SECRET_KEY=your_secret_key
```

### Examples

```bash
# Minute aggregates — works with Stocks Basic plan
node tools/fetch_flatfile.js us_stocks_sip/minute_aggs_v1 2026-04-10

# Per-trade ticks — requires Stocks Advanced+
node tools/fetch_flatfile.js us_stocks_sip/trades_v1 2026-04-10

# Per-quote NBBO — requires Stocks Advanced+
node tools/fetch_flatfile.js us_stocks_sip/quotes_v1 2026-04-10

# Crypto trades — requires Crypto plan
node tools/fetch_flatfile.js crypto_trades 2026-04-10 data/crypto.csv.gz
```

### Usage

```
node tools/fetch_flatfile.js <prefix> <date> [outfile]
```

Output defaults to `data/<prefix-with-slashes-replaced>_<date>.csv.gz`.
Override with the third argument.

**Available prefixes** depend on your Massive plan. A 403 typically means
your plan doesn't cover the requested prefix. Discover prefixes with:

```bash
aws s3 ls s3://flatfiles/ --endpoint-url https://files.massive.com
```

### Environment variables

| Variable               | Default                      | Description                    |
|------------------------|------------------------------|--------------------------------|
| `MASSIVE_S3_ACCESS_KEY`| *(required)*                 | S3 access key from dashboard   |
| `MASSIVE_S3_SECRET_KEY`| *(required)*                 | S3 secret key from dashboard   |
| `MASSIVE_S3_ENDPOINT`  | `https://files.massive.com`  | Override S3 endpoint           |
| `MASSIVE_S3_BUCKET`    | `flatfiles`                  | Override bucket name           |

## gen_cert.sh

Generates a self-signed TLS certificate (`cert.pem` + `key.pem`) in this
directory. Required by the mock server. Run once.
