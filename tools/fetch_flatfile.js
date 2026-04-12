#!/usr/bin/env node
// Fetch a Massive flat file (historical tick data) for mock replay.
//
// Usage:
//   node tools/fetch_flatfile.js <endpoint> <date> [outfile]
//
// Examples:
//   node tools/fetch_flatfile.js stocks/trades 2026-04-10
//   node tools/fetch_flatfile.js crypto/trades 2026-04-10 data/crypto.json.gz
//   node tools/fetch_flatfile.js stocks/quotes 2026-04-10
//
// The API key is read from $MASSIVE_API_KEY, or pass MASSIVE_API_KEY=... before
// the command.  Output defaults to data/<endpoint-with-slashes-replaced>_<date>.json.gz.
//
// The file is gzipped NDJSON — one JSON event object per line — and can be fed
// directly to mock_server.js via MOCK_REPLAY_FILE.

const https = require('https');
const fs = require('fs');
const path = require('path');

const API_KEY = process.env.MASSIVE_API_KEY;
const BASE = process.env.MASSIVE_FLAT_HOST || 'api.polygon.io';

if (!API_KEY) {
    console.error('ERROR: set MASSIVE_API_KEY (env var)');
    process.exit(1);
}

const endpoint = process.argv[2];
const date = process.argv[3];

if (!endpoint || !date) {
    console.error('Usage: fetch_flatfile.js <endpoint> <date> [outfile]');
    console.error('  endpoint: stocks/trades, stocks/quotes, crypto/trades, etc.');
    console.error('  date:     YYYY-MM-DD');
    process.exit(1);
}

const defaultOut = path.join('data', `${endpoint.replace(/\//g, '_')}_${date}.json.gz`);
const outfile = process.argv[4] || defaultOut;

// Ensure output directory exists.
const outdir = path.dirname(outfile);
if (!fs.existsSync(outdir)) {
    fs.mkdirSync(outdir, { recursive: true });
}

const url = `https://${BASE}/v2/flatfiles/${endpoint}/${date}?apiKey=${API_KEY}`;
console.log(`Fetching: ${url.replace(API_KEY, '***')}`);
console.log(`Output:   ${outfile}`);

function download(url, redirects) {
    if (redirects > 5) {
        console.error('ERROR: too many redirects');
        process.exit(1);
    }
    https.get(url, (res) => {
        if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
            console.log(`  redirect → ${res.headers.location.slice(0, 80)}...`);
            download(res.headers.location, redirects + 1);
            return;
        }
        if (res.statusCode !== 200) {
            let body = '';
            res.on('data', (d) => body += d);
            res.on('end', () => {
                console.error(`ERROR: HTTP ${res.statusCode}`);
                console.error(body.slice(0, 500));
                process.exit(1);
            });
            return;
        }

        const out = fs.createWriteStream(outfile);
        let bytes = 0;
        res.on('data', (chunk) => {
            bytes += chunk.length;
            process.stdout.write(`\r  ${(bytes / 1024 / 1024).toFixed(1)} MB`);
        });
        res.pipe(out);
        out.on('finish', () => {
            console.log(`\n  done — ${(bytes / 1024 / 1024).toFixed(1)} MB written`);
        });
    }).on('error', (err) => {
        console.error(`ERROR: ${err.message}`);
        process.exit(1);
    });
}

download(url, 0);
