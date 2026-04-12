#!/usr/bin/env node
// Fetch a Massive flat file (historical tick data) for mock replay.
//
// Massive flat files are served from an S3-compatible endpoint:
//   Endpoint:    https://files.massive.com
//   Bucket:      flatfiles
//   Key layout:  <prefix>/YYYY/MM/YYYY-MM-DD.csv.gz
//
// Use `aws s3 ls s3://flatfiles/ --endpoint-url https://files.massive.com`
// to discover available prefixes. Known examples:
//   us_stocks_sip/trades_v1       — per-trade ticks   (requires Stocks Advanced+)
//   us_stocks_sip/quotes_v1       — per-quote NBBO    (requires Stocks Advanced+)
//   us_stocks_sip/minute_aggs_v1  — minute aggregates (works with Stocks Basic)
//   crypto_trades                 — crypto trades     (requires Crypto plan)
//
// The prefix you can access depends on your Massive plan entitlements.
// "Stocks Basic" plans are limited to minute_aggs_v1; trades and quotes
// require an Advanced (or above) plan. A 403 usually means your plan
// doesn't cover the requested prefix.
//
// Credentials come from your Massive dashboard (S3 Access Key / Secret Key).
//
// Usage:
//   node tools/fetch_flatfile.js <prefix> <date> [outfile]
//
// Examples:
//   node tools/fetch_flatfile.js us_stocks_sip/minute_aggs_v1 2026-04-10
//   node tools/fetch_flatfile.js us_stocks_sip/trades_v1 2026-04-10
//   node tools/fetch_flatfile.js crypto_trades 2026-04-10 data/crypto.csv.gz
//
// Environment variables:
//   MASSIVE_S3_ACCESS_KEY  — S3 access key from your Massive dashboard
//   MASSIVE_S3_SECRET_KEY  — S3 secret key from your Massive dashboard
//   MASSIVE_S3_ENDPOINT    — override endpoint (default: https://files.massive.com)
//   MASSIVE_S3_BUCKET      — override bucket  (default: flatfiles)
//
// Output defaults to data/<prefix-with-slashes-replaced>_<date>.csv.gz.
// The file is gzipped CSV. Feed it to mock_server.js via MOCK_REPLAY_FILE —
// the loader auto-detects CSV vs NDJSON and normalises field names to the wire format.

const https = require('https');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const ACCESS_KEY = process.env.MASSIVE_S3_ACCESS_KEY;
const SECRET_KEY = process.env.MASSIVE_S3_SECRET_KEY;
const ENDPOINT = process.env.MASSIVE_S3_ENDPOINT || 'https://files.massive.com';
const BUCKET = process.env.MASSIVE_S3_BUCKET || 'flatfiles';

if (!ACCESS_KEY || !SECRET_KEY) {
    console.error('ERROR: set MASSIVE_S3_ACCESS_KEY and MASSIVE_S3_SECRET_KEY (env vars)');
    console.error('       Get these from your Massive dashboard.');
    process.exit(1);
}

const prefix = process.argv[2];
const date = process.argv[3];

if (!prefix || !date) {
    console.error('Usage: fetch_flatfile.js <prefix> <date> [outfile]');
    console.error('  prefix: S3 key prefix, e.g. us_stocks_sip/trades_v1, crypto_trades');
    console.error('  date:   YYYY-MM-DD');
    console.error('');
    console.error('Discover prefixes with:');
    console.error('  aws s3 ls s3://flatfiles/ --endpoint-url https://files.massive.com');
    process.exit(1);
}

// Parse date components for the year/month path hierarchy.
const dateParts = date.match(/^(\d{4})-(\d{2})-(\d{2})$/);
if (!dateParts) {
    console.error('ERROR: date must be YYYY-MM-DD');
    process.exit(1);
}
const [, year, month] = dateParts;

const defaultOut = path.join('data', `${prefix.replace(/\//g, '_')}_${date}.csv.gz`);
const outfile = process.argv[4] || defaultOut;

// Ensure output directory exists.
const outdir = path.dirname(outfile);
if (!fs.existsSync(outdir)) {
    fs.mkdirSync(outdir, { recursive: true });
}

// S3 object key: <prefix>/YYYY/MM/YYYY-MM-DD.csv.gz
const objectKey = `${prefix}/${year}/${month}/${date}.csv.gz`;

// --- AWS Signature V4 (minimal, GET-only, path-style) ---

function hmacSHA256(key, data) {
    return crypto.createHmac('sha256', key).update(data, 'utf8').digest();
}

function sha256Hex(data) {
    return crypto.createHash('sha256').update(data, 'utf8').digest('hex');
}

function signS3Get(host, bucketName, key, accessKey, secretKey) {
    const now = new Date();
    const amzDate = now.toISOString().replace(/[-:.]/g, '').slice(0, 15) + 'Z';
    const dateStamp = amzDate.slice(0, 8);
    const region = 'us-east-1';
    const service = 's3';

    // Path-style: /<bucket>/<key>
    const canonicalUri = '/' + bucketName + '/' + key;
    const canonicalQuerystring = '';
    const payloadHash = 'UNSIGNED-PAYLOAD';
    const canonicalHeaders =
        'host:' + host + '\n' +
        'x-amz-content-sha256:' + payloadHash + '\n' +
        'x-amz-date:' + amzDate + '\n';
    const signedHeaders = 'host;x-amz-content-sha256;x-amz-date';

    const canonicalRequest = [
        'GET', canonicalUri, canonicalQuerystring,
        canonicalHeaders, signedHeaders, payloadHash,
    ].join('\n');

    const credentialScope = `${dateStamp}/${region}/${service}/aws4_request`;
    const stringToSign = [
        'AWS4-HMAC-SHA256', amzDate, credentialScope, sha256Hex(canonicalRequest),
    ].join('\n');

    let signingKey = hmacSHA256('AWS4' + secretKey, dateStamp);
    signingKey = hmacSHA256(signingKey, region);
    signingKey = hmacSHA256(signingKey, service);
    signingKey = hmacSHA256(signingKey, 'aws4_request');
    const signature = hmacSHA256(signingKey, stringToSign).toString('hex');

    const authorization =
        `AWS4-HMAC-SHA256 Credential=${accessKey}/${credentialScope}, ` +
        `SignedHeaders=${signedHeaders}, Signature=${signature}`;

    return {
        path: canonicalUri,
        headers: {
            'x-amz-date': amzDate,
            'x-amz-content-sha256': payloadHash,
            'Authorization': authorization,
        },
    };
}

// --- Download ---

const parsed = new URL(ENDPOINT);
const host = parsed.hostname;

const signed = signS3Get(host, BUCKET, objectKey, ACCESS_KEY, SECRET_KEY);

console.log(`Fetching: s3://${BUCKET}/${objectKey}`);
console.log(`   from:  ${ENDPOINT}`);
console.log(`Output:   ${outfile}`);

function download(reqPath, headers, redirects) {
    if (redirects > 5) {
        console.error('ERROR: too many redirects');
        process.exit(1);
    }
    const options = {
        hostname: host,
        port: 443,
        path: reqPath,
        method: 'GET',
        headers: headers,
    };

    https.get(options, (res) => {
        if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
            console.log(`  redirect → ${res.headers.location.slice(0, 80)}...`);
            https.get(res.headers.location, (res2) => {
                handleResponse(res2);
            }).on('error', (err) => {
                console.error(`ERROR: ${err.message}`);
                process.exit(1);
            });
            return;
        }
        handleResponse(res);
    }).on('error', (err) => {
        console.error(`ERROR: ${err.message}`);
        process.exit(1);
    });
}

function handleResponse(res) {
    if (res.statusCode !== 200) {
        let body = '';
        res.on('data', (d) => body += d);
        res.on('end', () => {
            console.error(`ERROR: HTTP ${res.statusCode}`);
            if (res.statusCode === 403) {
                console.error('Access denied. Check your MASSIVE_S3_ACCESS_KEY and MASSIVE_S3_SECRET_KEY.');
                console.error('Keys are available from your Massive dashboard.');
            }
            if (res.statusCode === 404) {
                console.error('File not found. Data for each trading day is available by ~11:00 AM ET the next day.');
                console.error('Check that the date is a valid trading day and data has been published.');
            }
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
}

download(signed.path, signed.headers, 0);
