#!/bin/bash
# Fetches the tokscale CLI into vendor/ so the app has a pinned binary to spawn.
# npm is only the delivery mechanism — tokscale itself is a self-contained Rust
# executable, and nothing Node ships is loaded at runtime.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p vendor
cat > vendor/package.json <<'JSON'
{ "name": "notchmon-vendor", "private": true, "dependencies": { "tokscale": "^4.15.1" } }
JSON
cd vendor
npm install --no-audit --no-fund --silent
ARCH="$(uname -m)"
case "$ARCH" in
  arm64) PKG="@tokscale/cli-darwin-arm64" ;;
  x86_64) PKG="@tokscale/cli-darwin-x64" ;;
  *) echo "unsupported arch: $ARCH" >&2; exit 1 ;;
esac
BIN="node_modules/$PKG/bin/tokscale"
[ -x "$BIN" ] || { echo "tokscale binary missing at $BIN" >&2; exit 1; }
echo "vendored $("$BIN" --version) at vendor/$BIN"
