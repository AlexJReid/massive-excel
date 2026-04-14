#!/usr/bin/env bash
# Generate a self-signed TLS cert for the mock Massive WebSocket server.
# Requires openssl. Writes tools/cert.pem and tools/key.pem.

set -euo pipefail

cd "$(dirname "$0")"

openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem \
    -days 365 \
    -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"

echo "Wrote: tools/cert.pem tools/key.pem"
echo "Use with: node tools/mock_server.js"
