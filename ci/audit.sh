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

# --- soname closure, simulated the way the musl loader actually searches ---
# Globally findable providers are ONLY the ELFs living in the launcher
# LD_LIBRARY_PATH dirs (keep in sync with smoke.sh / install.sh); an ELF in any
# other prefix dir is reachable solely through its consumer's own $ORIGIN
# rpath, i.e. from the same directory. This catches libs whose private RUNPATH
# (e.g. libpulse -> /usr/lib/pulseaudio) got overwritten by the rpath pass.
while IFS= read -r f; do
  rel="${f#$P/}"; dir="${rel%/*}"
  { basename "$f"
    readelf -d "$f" 2>/dev/null | sed -n 's/.*(SONAME).*\[\(.*\)\].*/\1/p'
  } | awk -v d="$dir" 'NF{print "P\t" d "\t" $0}'
  readelf -d "$f" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p' \
    | awk -v d="$dir" 'NF{print "N\t" d "\t" $0}'
done < elfs.txt > graph.tsv

awk -F'\t' '$1 == "N" {print $3}' graph.tsv | sort -u > needed.txt

awk -F'\t' '
BEGIN {
  nsd = split("usr/lib lib usr/lib/chromium usr/lib/pulseaudio", a, " ");
  for (i = 1; i <= nsd; i++) sd[a[i]] = 1;
  glob["libc.so"] = glob["libc.musl-aarch64.so.1"] = glob["ld-musl-aarch64.so.1"] = 1;
}
$1 == "P" { bydir[$2 "\t" $3] = 1; if ($2 in sd) glob[$3] = 1; next }
$1 == "N" { nn++; ndir[nn] = $2; nso[nn] = $3 }
END {
  for (i = 1; i <= nn; i++) {
    if (nso[i] in glob) continue;
    if ((ndir[i] "\t" nso[i]) in bydir) continue;
    print ndir[i] "\t" nso[i];
  }
}' graph.tsv | sort -u > missing-sonames.txt
echo "== sonames: $(wc -l < needed.txt) distinct needed, $(wc -l < missing-sonames.txt) unresolved from runtime search paths =="
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
