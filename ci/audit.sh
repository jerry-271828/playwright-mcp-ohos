#!/bin/sh
# Runs inside an aarch64 alpine container. Static gate before any runtime test:
# every NEEDED soname and every strong-undefined dynamic symbol of every ELF in
# the prefix must resolve from (prefix ELFs) + (real OHOS musl exports, dumped
# from the target device) + (harmonybrew musl-compat shim exports).
set -eu

W=/w
P="$W/out/prefix"
M="$W/out/meta"

apk add --no-cache binutils >/dev/null
cd "$M"
[ -s elfs.txt ]

# provided sonames: SONAME + basename of every ELF, plus loader-internal names
: > provided.raw
while IFS= read -r f; do
  basename "$f" >> provided.raw
  readelf -d "$f" 2>/dev/null | sed -n 's/.*(SONAME).*\[\(.*\)\].*/\1/p' >> provided.raw
done < elfs.txt
printf 'libc.so\nlibc.musl-aarch64.so.1\nld-musl-aarch64.so.1\n' >> provided.raw
sort -u provided.raw > provided.txt

while IFS= read -r f; do
  readelf -d "$f" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p'
done < elfs.txt | sort -u > needed.txt

comm -23 needed.txt provided.txt > missing-sonames.txt
echo "== sonames: $(wc -l < needed.txt) needed, $(wc -l < missing-sonames.txt) missing =="
cat missing-sonames.txt

# symbol closure (musl world has no symbol versioning; strip @VER decorations)
while IFS= read -r f; do
  nm -D --defined-only "$f" 2>/dev/null | awk 'NF>=3{print $3}'
done < elfs.txt | sed 's/@.*//' | sort -u > exports.txt

sed 's/@.*//' "$W/baselines/ohos-musl-symbols.txt" | sort -u > base-libc.txt
sed 's/@.*//' "$W/baselines/musl-compat-symbols.txt" | sort -u > base-compat.txt
sort -u exports.txt base-libc.txt base-compat.txt > allprov.txt

while IFS= read -r f; do
  nm -D "$f" 2>/dev/null | awk '$1=="U"{print $2}'
done < elfs.txt | sed 's/@.*//' | sort -u > und.txt

comm -23 und.txt allprov.txt > missing-symbols.txt
echo "== symbols: $(wc -l < und.txt) strong-undef, $(wc -l < missing-symbols.txt) unresolved =="
cat missing-symbols.txt

fail=0
[ -s missing-sonames.txt ] && fail=1
[ -s missing-symbols.txt ] && fail=1
if [ "$fail" = 0 ]; then
  echo "AUDIT OK"
else
  echo "AUDIT FAILED (see lists above; fix = ship the lib, or extend the compat shim)"
  exit 1
fi
