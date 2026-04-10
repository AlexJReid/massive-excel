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

    // 2. Per-connection tick driver.
    const tick = setInterval(() => {
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
        clearInterval(tick);
        log(`CLOSE    ${peer}`);
    });

    ws.on('error', (err) => {
        log(`ERROR    ${peer} ${err.message}`);
    });
});

server.listen(PORT, '0.0.0.0', () => {
    log(`mock_server listening on wss://0.0.0.0:${PORT}/`);
    log(`expected API key: "${API_KEY}"`);
    log(`tick interval: ${TICK_MS}ms`);
    log('try: zig build run-cli -Dmassive_host=localhost -Dmassive_port=' + PORT + ' -Dmassive_insecure=true -- T.AAPL T.MSFT');
});
