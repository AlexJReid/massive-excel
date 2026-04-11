#!/usr/bin/env bash
# Cross-compile a Windows XLL and emit a mock-pointing config.json next to it.
# One binary serves both mock and prod now — the config file decides.

set -euo pipefail

ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
if [[ -z "${ip}" ]]; then
    echo "error: could not detect a LAN IP on en0 or en1" >&2
    echo "hint: check 'ifconfig' and hard-code the host in config.json" >&2
    exit 1
fi

echo "building XLL and mock config"
zig build

cat > zig-out/lib/config.json <<EOF
{
  "host": "${ip}",
  "port": 8443,
  "path": "/stocks",
  "insecure": true,
  "api_key": "test-key"
}
EOF

echo "done:"
echo "  zig-out/lib/massive_excel.xll"
echo "  zig-out/lib/config.json  (host=${ip}:8443, insecure, api_key=test-key)"
echo
echo "next:"
echo "  1. start the mock on this machine:  node tools/mock_server.js"
echo "  2. copy BOTH files from zig-out/lib/ to the Windows machine (if different)"
echo "  3. load the XLL in Excel and try =MASSIVE(\"T.AAPL.p\")"
