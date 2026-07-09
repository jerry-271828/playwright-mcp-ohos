#!/bin/sh
# playwright-mcp-ohos installer for HarmonyOS PC (hishell + harmonybrew).
#
# Usage:
#   sh install.sh                    # download the latest GitHub release
#   sh install.sh /path/to/tarball   # install from a local tarball
#
# Everything lands under $PW_OHOS_HOME (default ~/.playwright-ohos):
#   prefix/          Alpine-musl chromium tree, code-signed on this device
#   mcp/             @playwright/mcp + playwright-core (npm, --ignore-scripts)
#   mcp-config.json  ready-to-register Claude Code MCP server definition
set -eu

REPO="${PW_OHOS_REPO:-jerry-271828/playwright-mcp-ohos}"
ROOT="${PW_OHOS_HOME:-$HOME/.playwright-ohos}"
APP_CACHE_BASE="${PW_OHOS_CACHE:-/data/storage/el2/base/cache}"

say() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mFATAL:\033[0m %s\n' "$*" >&2; exit 1; }

for t in node npm python3 tar zstd sha256sum binary-sign-tool llvm-strip llvm-objcopy llvm-readelf; do
  command -v "$t" >/dev/null 2>&1 \
    || die "缺少 $t（brew install node python3 zstd gnu-tar coreutils devel-base）"
done

mkdir -p "$ROOT"
WORK="$ROOT/prefix.new"
rm -rf "$WORK"
mkdir -p "$WORK"

TARBALL="${1:-}"
if [ -z "$TARBALL" ]; then
  command -v gh >/dev/null 2>&1 || die "缺少 gh（brew install gh），或改用: sh install.sh <tarball>"
  say "从 GitHub release 下载（repo: $REPO）"
  DL="$ROOT/download"
  rm -rf "$DL"
  mkdir -p "$DL"
  gh release download --repo "$REPO" --dir "$DL" \
    --pattern 'pw-chromium-ohos-*.tar.zst' --pattern 'SHA256SUMS' \
    --pattern 'ohos_sign_sweep.py' --pattern 'shim.cjs' \
    --pattern 'fonts.conf.in' --pattern 'test-local.mjs'
  (cd "$DL" && grep 'pw-chromium-ohos-' SHA256SUMS | sha256sum -c -) || die "sha256 校验失败"
  TARBALL="$(ls "$DL"/pw-chromium-ohos-*.tar.zst | head -1)"
  SIGN_SWEEP="$DL/ohos_sign_sweep.py"
  SHIM_SRC="$DL/shim.cjs"
  FONTS_IN="$DL/fonts.conf.in"
  TEST_SRC="$DL/test-local.mjs"
else
  HERE="$(cd "$(dirname "$0")" && pwd)"
  SIGN_SWEEP="$HERE/ohos_sign_sweep.py"
  SHIM_SRC="$HERE/shim.cjs"
  FONTS_IN="$HERE/../config/fonts.conf.in"
  TEST_SRC="$HERE/test-local.mjs"
  [ -f "$FONTS_IN" ] || FONTS_IN="$HERE/fonts.conf.in"
fi

say "解包 $(basename "$TARBALL")"
tar --zstd -xf "$TARBALL" -C "$WORK"

say "签名 sweep（全部 ELF；chrome ~250MB，需要一两分钟）"
python3 "$SIGN_SWEEP" "$WORK"

say "启用新 prefix"
rm -rf "$ROOT/prefix.old"
[ -d "$ROOT/prefix" ] && mv "$ROOT/prefix" "$ROOT/prefix.old"
mv "$WORK" "$ROOT/prefix"
P="$ROOT/prefix"
CHROME="$P/$(cat "$P/.meta/CHROME_PATH")"
[ -f "$CHROME" ] || die "chrome 不存在: $CHROME"

say "安装 @playwright/mcp + playwright-core（--ignore-scripts）"
mkdir -p "$ROOT/mcp"
cd "$ROOT/mcp"
[ -f package.json ] || npm init -y >/dev/null 2>&1
PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm install --no-audit --no-fund --ignore-scripts \
  playwright-core@latest @playwright/mcp@latest

cp "$SHIM_SRC" "$ROOT/shim.cjs"
[ -f "$TEST_SRC" ] && cp "$TEST_SRC" "$ROOT/test-local.mjs"

say "准备可写目录（/tmp 是只读 erofs，浏览器临时文件必须走应用沙箱 ext4）"
CACHE_FC="$APP_CACHE_BASE/pw-cache/fontconfig"
mkdir -p "$APP_CACHE_BASE/pw-tmp" "$APP_CACHE_BASE/pw-profile" "$CACHE_FC" "$ROOT/output"
[ "$(ls -ldn "$APP_CACHE_BASE/pw-tmp" | awk '{print $3}')" = "$(id -u)" ] \
  || die "$APP_CACHE_BASE 属主异常；用 PW_OHOS_CACHE=<可写目录> 重跑"

sed -e "s|@PREFIX@|$P|g" -e "s|@CACHE@|$CACHE_FC|g" "$FONTS_IN" > "$ROOT/fonts.conf"

MUSL_COMPAT="$HOME/.harmonybrew/opt/musl-compat/lib/libmusl_compat.so"
LDP=""
[ -f "$MUSL_COMPAT" ] && LDP="$MUSL_COMPAT"

cat > "$ROOT/mcp-config.json" <<EOF
{
  "command": "node",
  "args": [
    "--require", "$ROOT/shim.cjs",
    "$ROOT/mcp/node_modules/@playwright/mcp/cli.js",
    "--browser", "chromium",
    "--executable-path", "$CHROME",
    "--headless",
    "--no-sandbox",
    "--user-data-dir", "$APP_CACHE_BASE/pw-profile",
    "--output-dir", "$ROOT/output"
  ],
  "env": {
    "LD_LIBRARY_PATH": "$P/usr/lib:$P/lib:$P/usr/lib/chromium:$P/usr/lib/pulseaudio",
    "LD_PRELOAD": "$LDP",
    "FONTCONFIG_FILE": "$ROOT/fonts.conf",
    "TMPDIR": "$APP_CACHE_BASE/pw-tmp",
    "XDG_CACHE_HOME": "$APP_CACHE_BASE/pw-cache",
    "PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD": "1"
  }
}
EOF

say "安装完成"
printf '\n注册到 Claude Code：\n\n  claude mcp add-json playwright-ohos "$(cat %s)"\n\n' "$ROOT/mcp-config.json"
printf '可选本机自测：\n\n  node %s/test-local.mjs\n\n' "$ROOT"
printf '排查失败：hilog -x | grep -iE "xpm|code.?sign|verity"（EACCES=未签名, EPERM=签名坏）\n'
