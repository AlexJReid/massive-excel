#!/usr/bin/env bash
# Cross-compile a mock-targeting XLL for Windows.
#
# Detects this machine's LAN IP (en0, falling back to en1) and bakes it into
# the XLL so that a Windows VM or LAN peer running the node mock server can
# reach it. The resulting XLL connects to wss://<lan-ip>:8443 with TLS
# verification disabled.
#
# WARNING: -Dmassive_insecure=true skips cert verification for EVERY connection
# the XLL makes. Keep mock builds in a separate directory from production
# builds. Never load a mock-targeting XLL against the real Massive endpoint.

set -euo pipefail

ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
if [[ -z "${ip}" ]]; then
    echo "error: could not detect a LAN IP on en0 or en1" >&2
    echo "hint: check 'ifconfig' and set -Dmassive_host=<ip> manually" >&2
    exit 1
fi

echo "building XLL pointed at wss://${ip}:8443 (insecure TLS)"
zig build \
    -Dmassive_host="${ip}" \
    -Dmassive_port=8443 \
    -Dmassive_insecure=true

echo "done: zig-out/lib/standalone.xll"
echo
echo "next:"
echo "  1. start the mock on this machine:  node tools/mock_server.js"
echo "  2. copy zig-out/lib/standalone.xll to the Windows box"
echo "  3. drop massive_api_key.txt containing 'test-key' next to the XLL"
echo "  4. load the XLL in Excel and try =MASSIVE(\"T.AAPL.p\")"
