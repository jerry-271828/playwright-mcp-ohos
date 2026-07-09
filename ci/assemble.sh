#!/bin/sh
# Runs inside an aarch64 alpine container as root, workspace mounted at /w.
# Assembles a self-contained chromium prefix that runs on HarmonyOS PC:
#  - same ELF interpreter path as OHOS (/lib/ld-musl-aarch64.so.1)
#  - libc.musl-aarch64.so.1 NEEDED entries resolve inside the OHOS loader
#    itself (verified on device: harmonybrew node carries the same NEEDED
#    and runs with no such file present), so no --replace-needed pass.
#  - $ORIGIN rpaths as a backup net; primary resolution is LD_LIBRARY_PATH
#    exported by the MCP launcher env.
set -eu

W=/w
P="$W/out/prefix"
M="$W/out/meta"

rm -rf "$W/out"
mkdir -p "$P" "$M"

apk add --no-cache patchelf >/dev/null

# --- install chromium + runtime deps into the prefix (no maintainer scripts) ---
mkdir -p "$P/etc/apk/keys"
cp -a /etc/apk/keys/. "$P/etc/apk/keys/"
cp /etc/apk/repositories "$P/etc/apk/"

apk add --root "$P" --initdb --no-cache --no-scripts \
  chromium chromium-swiftshader font-dejavu fontconfig ca-certificates-bundle

apk --root "$P" list -I 2>/dev/null | sort > "$M/manifest.txt"
sed -n 's/^chromium-\([0-9][0-9.]*\)-r[0-9]* .*/\1/p' "$M/manifest.txt" | head -1 > "$M/VERSION"
echo "chromium version: $(cat "$M/VERSION")"
[ -s "$M/VERSION" ]

CHROME_REL="$(cd "$P" && find usr/lib/chromium -maxdepth 1 -name chrome -type f | head -1)"
[ -n "$CHROME_REL" ] || { echo "FATAL: chrome binary not found in prefix"; exit 1; }
printf '%s\n' "$CHROME_REL" > "$M/CHROME_PATH"
CHROME="$P/$CHROME_REL"

# --- prune what the browser never needs at runtime ---
rm -rf "$P/etc/apk" "$P/lib/apk" "$P/var" "$P/dev" "$P/proc" "$P/sys" "$P/run" \
       "$P/home" "$P/root" "$P/media" "$P/mnt" "$P/opt" "$P/srv" "$P/tmp"
rm -rf "$P/usr/share/man" "$P/usr/share/doc" "$P/usr/share/apk" \
       "$P/usr/share/applications" "$P/usr/share/icons"
rm -rf "$P/bin" "$P/sbin" "$P/usr/sbin" "$P/usr/bin"

# The prefix must never carry its own musl loader/libc: the device loader
# provides libc, and a second copy in LD_LIBRARY_PATH would be chaos.
rm -f "$P/lib/ld-musl-aarch64.so.1" "$P/usr/lib/ld-musl-aarch64.so.1" \
      "$P/lib/libc.musl-aarch64.so.1" "$P/usr/lib/libc.musl-aarch64.so.1"

# --- ELF pass ---
find "$P" -type f | while IFS= read -r f; do
  if [ "$(head -c4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]; then
    printf '%s\n' "$f"
  fi
done | sort -u > "$M/elfs.txt"
echo "ELF files in prefix: $(wc -l < "$M/elfs.txt")"

RP='$ORIGIN:$ORIGIN/..:$ORIGIN/../..:$ORIGIN/../lib:$ORIGIN/../usr/lib:$ORIGIN/../../usr/lib'
: > "$M/patchelf-warn.log"
while IFS= read -r f; do
  patchelf --set-rpath "$RP" "$f" 2>>"$M/patchelf-warn.log" \
    || echo "WARN: rpath failed: $f" >> "$M/patchelf-warn.log"
done < "$M/elfs.txt"
[ -s "$M/patchelf-warn.log" ] && { echo "--- patchelf warnings ---"; cat "$M/patchelf-warn.log"; }

INTERP="$(patchelf --print-interpreter "$CHROME")"
echo "chrome PT_INTERP: $INTERP"
[ "$INTERP" = "/lib/ld-musl-aarch64.so.1" ] || { echo "FATAL: unexpected interpreter"; exit 1; }

mkdir -p "$P/.meta"
cp "$M/manifest.txt" "$M/VERSION" "$M/CHROME_PATH" "$P/.meta/"

du -sh "$P"
echo "ASSEMBLE OK"
