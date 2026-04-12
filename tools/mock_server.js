#!/usr/bin/env node
// Mock Massive WebSocket server for local smoke-testing.
//
// Speaks the real Massive wire protocol (greet, auth, subscribe, array-of-events
// messages) so the Zig client is exercised end-to-end without touching prod.
//
// Usage:
//   ./tools/gen_cert.sh               # one-time: create tools/cert.pem + key.pem
//   npm install ws                    # one-time: install dependency
//   node tools/mock_server.js         # starts wss://0.0.0.0:8443/stocks
//
// The expected API key is "test-key" — or set env MOCK_API_KEY to override.

const fs = require('fs');
const path = require('path');
const https = require('https');
const zlib = require('zlib');
const readline = require('readline');

let WebSocketServer;
try {
    WebSocketServer = require('ws').WebSocketServer;
} catch (e) {
    console.error("ERROR: the 'ws' package is not installed. Run: npm install ws");
    process.exit(1);
}

const PORT = parseInt(process.env.MOCK_PORT || '8443', 10);
const API_KEY = process.env.MOCK_API_KEY || 'test-key';
const TICK_MS = parseInt(process.env.MOCK_TICK_MS || '500', 10);

// Replay mode — set MOCK_REPLAY_FILE to a flat file (.json.gz or .json).
const REPLAY_FILE = process.env.MOCK_REPLAY_FILE || '';
const REPLAY_SPEED = parseFloat(process.env.MOCK_REPLAY_SPEED || '1');
const REPLAY_LOOP = (process.env.MOCK_REPLAY_LOOP || 'true') !== 'false';

const certPath = path.join(__dirname, 'cert.pem');
const keyPath = path.join(__dirname, 'key.pem');
if (!fs.existsSync(certPath) || !fs.existsSync(keyPath)) {
    console.error(`ERROR: missing ${certPath} / ${keyPath}`);
    console.error('Run ./tools/gen_cert.sh first.');
    process.exit(1);
}

const server = https.createServer({
    cert: fs.readFileSync(certPath),
    key: fs.readFileSync(keyPath),
});

const wss = new WebSocketServer({ server });

function log(...args) {
    const ts = new Date().toISOString().slice(11, 23);
    console.log(`[${ts}]`, ...args);
}

// ---------------------------------------------------------------------------
// Fake data generator — produces plausible Massive events per channel prefix.
// ---------------------------------------------------------------------------

function baseFor(sym) {
    // Seed a price by hashing the symbol so the same symbol always starts
    // near the same number.
    let h = 0;
    for (const ch of sym) h = (h * 31 + ch.charCodeAt(0)) & 0xffff;
    return 50 + (h % 950); // 50..999
}

function makeEvent(channel) {
    const dot = channel.indexOf('.');
    if (dot < 0) return null;
    const ev = channel.slice(0, dot);
    const sym = channel.slice(dot + 1);
    const base = baseFor(sym);
    const jitter = (Math.random() - 0.5) * base * 0.02; // +/- 1%
    const price = +(base + jitter).toFixed(4);
    const now = Date.now();

    switch (ev) {
        case 'T': // Trades
            return {
                ev, sym,
                x: 4, // exchange id
                i: String(Math.floor(Math.random() * 1e9)),
                z: 3, // tape: Nasdaq
                p: price,
                s: Math.floor(Math.random() * 1000) + 1,
                c: [0],
                t: now,
                q: Math.floor(Math.random() * 1e9),
            };
        case 'Q': // Quotes
            return {
                ev, sym,
                bp: +(price - 0.01).toFixed(4),
                bs: Math.floor(Math.random() * 500) + 1,
                ap: +(price + 0.01).toFixed(4),
                as: Math.floor(Math.random() * 500) + 1,
                t: now,
            };
        case 'AM': // Per-minute aggregates
        case 'A':  // Per-second aggregates
            return {
                ev, sym,
                v: Math.floor(Math.random() * 100000),
                av: Math.floor(Math.random() * 1000000),
                op: +(base - 0.5).toFixed(4),
                vw: +(price - 0.05).toFixed(4),
                o: +(base).toFixed(4),
                c: price,
                h: +(price + 0.5).toFixed(4),
                l: +(price - 0.5).toFixed(4),
                s: now - 60000,
                e: now,
            };
        case 'FMV': // Fair Market Value
            return { ev, sym, fmv: price, t: now };
        default:
            return { ev, sym, t: now };
    }
}

// ---------------------------------------------------------------------------
// Replay file loader — reads gzipped or plain NDJSON into a sorted array.
// ---------------------------------------------------------------------------

// Each entry: { t: <timestamp ms>, ev: <string>, sym: <string>, ...rest }
// Sorted by t ascending. Events with no `t` field are dropped.
let replayEvents = null; // null = synthetic mode, [] = replay mode

async function loadReplayFile(filepath) {
    log(`loading replay file: ${filepath}`);
    const events = [];
    const raw = fs.createReadStream(filepath);
    const stream = filepath.endsWith('.gz')
        ? raw.pipe(zlib.createGunzip())
        : raw;

    const rl = readline.createInterface({ input: stream, crlfDelay: Infinity });
    let lineNo = 0;
    for await (const line of rl) {
        lineNo++;
        if (!line.trim()) continue;
        try {
            const obj = JSON.parse(line);
            if (obj.t != null && obj.ev && obj.sym) {
                events.push(obj);
            }
        } catch (e) {
            if (lineNo <= 3) log(`  warning: bad JSON on line ${lineNo}`);
        }
    }
    events.sort((a, b) => a.t - b.t);
    log(`  loaded ${events.length} events`);
    if (events.length > 0) {
        const first = new Date(events[0].t).toISOString();
        const last = new Date(events[events.length - 1].t).toISOString();
        log(`  time range: ${first} → ${last}`);
    }
    return events;
}

// Replay cursor per connection — walks through replayEvents respecting timing.
function createReplayCursor(ws, getSubs) {
    let idx = 0;
    let timer = null;
    let wallStart = null;  // wall clock time when replay started
    let dataStart = null;  // timestamp of first event in the file

    function stop() {
        if (timer) { clearTimeout(timer); timer = null; }
    }

    function scheduleNext() {
        if (ws.readyState !== ws.OPEN) { stop(); return; }
        if (replayEvents.length === 0) return;

        // Find the next event that matches a subscribed channel.
        const subs = getSubs();
        while (idx < replayEvents.length) {
            const evt = replayEvents[idx];
            const channel = `${evt.ev}.${evt.sym}`;
            if (subs.has(channel)) break;
            idx++;
        }

        if (idx >= replayEvents.length) {
            if (REPLAY_LOOP) {
                log(`  replay: looping`);
                idx = 0;
                wallStart = Date.now();
                dataStart = replayEvents[0].t;
                scheduleNext();
            } else {
                log(`  replay: end of file`);
            }
            return;
        }

        const evt = replayEvents[idx];
        if (wallStart === null) {
            wallStart = Date.now();
            dataStart = evt.t;
        }

        // How long after the replay start should this event fire?
        const dataElapsed = evt.t - dataStart;
        const wallTarget = REPLAY_SPEED > 0
            ? wallStart + dataElapsed / REPLAY_SPEED
            : Date.now(); // speed=0: firehose
        const delay = Math.max(0, wallTarget - Date.now());

        timer = setTimeout(() => {
            if (ws.readyState !== ws.OPEN) return;
            const subs = getSubs();

            // Batch all events at the same timestamp (within 1ms).
            const batch = [];
            const batchEnd = evt.t + 1;
            while (idx < replayEvents.length && replayEvents[idx].t < batchEnd) {
                const e = replayEvents[idx];
                const ch = `${e.ev}.${e.sym}`;
                if (subs.has(ch)) batch.push(e);
                idx++;
            }
            if (batch.length > 0) {
                ws.send(JSON.stringify(batch));
            }
            scheduleNext();
        }, delay);
    }

    return { start: scheduleNext, stop };
}

// ---------------------------------------------------------------------------
// Connection handling
// ---------------------------------------------------------------------------

wss.on('connection', (ws, req) => {
    const peer = `${req.socket.remoteAddress}:${req.socket.remotePort}`;
    log(`CONNECT  ${peer} path=${req.url}`);

    let authed = false;
    const subs = new Set();

    // 1. Greet.
    ws.send(JSON.stringify([{
        ev: 'status',
        status: 'connected',
        message: 'Connected Successfully',
    }]));

    // 2. Per-connection tick driver — synthetic or replay.
    let tick = null;
    let cursor = null;

    if (replayEvents) {
        cursor = createReplayCursor(ws, () => subs);
    } else {
        tick = setInterval(() => {
            if (!authed || subs.size === 0) return;
            const batch = [];
            for (const ch of subs) {
                const evt = makeEvent(ch);
                if (evt) batch.push(evt);
            }
            if (batch.length > 0) {
                ws.send(JSON.stringify(batch));
            }
        }, TICK_MS);
    }

    ws.on('message', (raw) => {
        let msg;
        try {
            msg = JSON.parse(raw.toString());
        } catch (e) {
            log(`  ${peer} BAD-JSON: ${raw}`);
            return;
        }
        log(`  ${peer} RECV`, msg);

        const action = msg.action;
        const params = typeof msg.params === 'string' ? msg.params : '';

        if (action === 'auth') {
            if (params === API_KEY) {
                authed = true;
                ws.send(JSON.stringify([{
                    ev: 'status', status: 'auth_success', message: 'authenticated',
                }]));
                log(`  ${peer} AUTH OK`);
            } else {
                ws.send(JSON.stringify([{
                    ev: 'status', status: 'auth_failed', message: 'bad key',
                }]));
                log(`  ${peer} AUTH FAIL (expected "${API_KEY}", got "${params}")`);
                ws.close();
            }
            return;
        }

        if (!authed) {
            log(`  ${peer} REJECT (not authed)`);
            ws.close();
            return;
        }

        if (action === 'subscribe') {
            const channels = params.split(',').map(s => s.trim()).filter(Boolean);
            for (const ch of channels) subs.add(ch);
            ws.send(JSON.stringify([{
                ev: 'status',
                status: 'success',
                message: `subscribed to: ${channels.join(',')}`,
            }]));
            log(`  ${peer} SUB`, Array.from(subs));
            // Kick off replay cursor if this is the first subscription.
            if (cursor) cursor.start();
            return;
        }

        if (action === 'unsubscribe') {
            const channels = params.split(',').map(s => s.trim()).filter(Boolean);
            for (const ch of channels) subs.delete(ch);
            ws.send(JSON.stringify([{
                ev: 'status',
                status: 'success',
                message: `unsubscribed from: ${channels.join(',')}`,
            }]));
            log(`  ${peer} UNSUB`, Array.from(subs));
            return;
        }

        log(`  ${peer} UNKNOWN action: ${action}`);
    });

    ws.on('close', () => {
        if (tick) clearInterval(tick);
        if (cursor) cursor.stop();
        log(`CLOSE    ${peer}`);
    });

    ws.on('error', (err) => {
        log(`ERROR    ${peer} ${err.message}`);
    });
});

async function main() {
    if (REPLAY_FILE) {
        replayEvents = await loadReplayFile(REPLAY_FILE);
        if (replayEvents.length === 0) {
            console.error('ERROR: replay file is empty or has no valid events');
            process.exit(1);
        }
    }

    server.listen(PORT, '0.0.0.0', () => {
        log(`mock_server listening on wss://0.0.0.0:${PORT}/`);
        log(`expected API key: "${API_KEY}"`);
        if (replayEvents) {
            log(`mode: REPLAY from ${REPLAY_FILE}`);
            log(`  speed: ${REPLAY_SPEED}x, loop: ${REPLAY_LOOP}`);
        } else {
            log(`mode: SYNTHETIC (tick ${TICK_MS}ms)`);
        }
        log('try: zig build run-cli -Dmassive_host=localhost -Dmassive_port=' + PORT + ' -Dmassive_insecure=true -- T.AAPL T.MSFT');
    });
}

main().catch((err) => {
    console.error(`ERROR: ${err.message}`);
    process.exit(1);
});
