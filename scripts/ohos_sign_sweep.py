#!/usr/bin/env python3
"""Sign every ELF under a directory for the HarmonyOS PC kernel (XPM/fs-verity).

Adapted from harmonybrew's ohos-pip-autosign hook: llvm-strip -> 64KB section
alignment -> file padding -> binary-sign-tool selfSign. Files that already
carry a .codesign section are skipped, so the sweep is idempotent. Symlinks
and anything resolving outside the target root are never touched.

Signing MUST be the last thing that happens to a binary: any later ELF edit
invalidates the signature (and fs-verity makes signed files unwritable).
"""
import os
import shutil
import subprocess
import sys


def run(cmd):
    subprocess.run(cmd, capture_output=True, check=True)


def has_codesign(path):
    r = subprocess.run(["llvm-readelf", "-S", path], capture_output=True, text=True)
    return ".codesign" in r.stdout


def normalize(path):
    # binary-sign-tool mis-lays-out the PHT on some inputs; strip + forced
    # 64KB alignment of all allocatable sections keeps it on the happy path.
    run(["llvm-strip", "--strip-all", path])
    result = subprocess.run(["llvm-readelf", "-S", path], capture_output=True, text=True, check=True)
    secs = []
    for line in result.stdout.splitlines():
        parts = line.replace("[", " ").replace("]", " ").split()
        if len(parts) > 6:
            name = parts[1]
            flags = line[line.find(name) + len(name):]
            # Never touch TLS sections (.tdata/.tbss, flag "T"): local-exec
            # TP-relative offsets are baked into the code against the original
            # PT_TLS p_align; re-aligning them to 64KB shifts musl's runtime
            # TLS layout and every thread_local reads garbage (SIGSEGV in
            # ThreadIdNameManager::GetName on chromium).
            if name.startswith(".") and "A" in flags and "T" not in flags:
                secs.append(name)
    if not secs:
        secs = [".gnu.hash", ".dynsym", ".dynstr", ".rela.dyn", ".rela.plt",
                ".dynamic", ".text", ".data", ".bss"]
    cmd = ["llvm-objcopy"]
    for s in secs:
        cmd += ["--set-section-alignment", f"{s}=65536"]
    cmd.append(path)
    run(cmd)
    size = os.path.getsize(path)
    aligned = (size + 65535) & ~65535
    if size != aligned:
        with open(path, "ab") as f:
            f.truncate(aligned)


def sign(path):
    subprocess.run(["llvm-strip", "--remove-section=.codesign", path],
                   capture_output=True, check=True)
    normalize(path)
    run(["binary-sign-tool", "sign", "-inFile", path, "-outFile", path, "-selfSign", "1"])


def main(root):
    for t in ("binary-sign-tool", "llvm-strip", "llvm-objcopy", "llvm-readelf"):
        if not shutil.which(t):
            sys.exit(f"missing tool: {t} (brew install devel-base / ohos-sdk)")
    todo, seen = [], set()
    for dirpath, _, files in os.walk(root):
        for fn in files:
            full = os.path.join(dirpath, fn)
            if os.path.islink(full):
                continue
            p = os.path.realpath(full)
            if p in seen or not p.startswith(root + os.sep):
                continue
            seen.add(p)
            try:
                with open(p, "rb") as f:
                    if f.read(4) != b"\x7fELF":
                        continue
            except OSError:
                continue
            if has_codesign(p):
                continue
            todo.append(p)
    todo.sort()
    print(f"{len(todo)} ELF file(s) to sign under {root}")
    fails = 0
    for i, p in enumerate(todo, 1):
        try:
            sign(p)
            print(f"  [{i}/{len(todo)}] signed {os.path.relpath(p, root)}", flush=True)
        except subprocess.CalledProcessError as e:
            fails += 1
            print(f"  [{i}/{len(todo)}] FAILED {os.path.relpath(p, root)} (exit {e.returncode})", flush=True)
    if fails:
        sys.exit(f"{fails} file(s) failed to sign")
    print("sign sweep OK")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: ohos_sign_sweep.py <dir>")
    main(os.path.realpath(sys.argv[1]))
