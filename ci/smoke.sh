#!/bin/sh
# Runs inside an aarch64 alpine container with the SAME env contract the device
# launcher uses (LD_LIBRARY_PATH / FONTCONFIG_FILE / XDG_CACHE_HOME), then
# exercises the assembled chromium through playwright-core and through the real
# @playwright/mcp stdio server.
set -eu

W=/w
P="$W/out/prefix"
M="$W/out/meta"

apk add --no-cache nodejs npm >/dev/null
echo "container node: $(node -v)"

CHROME="$P/$(cat "$M/CHROME_PATH")"
[ -f "$CHROME" ]

mkdir -p /smoke/out /smoke/cache
cd /smoke
npm init -y >/dev/null 2>&1
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --no-audit --no-fund --ignore-scripts \
  playwright-core@latest @playwright/mcp@latest >/dev/null
node -p "'playwright-core ' + require('playwright-core/package.json').version"
node -p "'@playwright/mcp ' + require('@playwright/mcp/package.json').version"

export LD_LIBRARY_PATH="$P/usr/lib:$P/lib:$P/usr/lib/chromium:$P/usr/lib/pulseaudio"
sed -e "s|@PREFIX@|$P|g" -e "s|@CACHE@|/smoke/cache/fontconfig|g" \
  "$W/config/fonts.conf.in" > /smoke/fonts.conf
export FONTCONFIG_FILE=/smoke/fonts.conf
export XDG_CACHE_HOME=/smoke/cache

# ESM import resolution walks up from the script's own directory, so the smoke
# scripts must live next to /smoke/node_modules, not under /w/ci.
cp "$W/ci/smoke.mjs" "$W/ci/smoke-mcp.mjs" /smoke/
node /smoke/smoke.mjs "$CHROME"
node /smoke/smoke-mcp.mjs "$CHROME"
echo "SMOKE OK"
