#!/usr/bin/env bash
# Encrypts a Unity export (Builds/iOS_zip/efg_ios.zip.NNN + build_info.txt) into export/ for this repo.
# usage: ci/pack.sh <dir with efg_ios.zip.NNN> <key file>
set -euo pipefail
SRC="$1"; KEY="$2"; ROOT="$(cd "$(dirname "$0")/.." && pwd)"; T="$(mktemp -d)"
cat "$SRC"/efg_ios.zip.[0-9][0-9][0-9] > "$T/efg_ios.zip"
unzip -tq "$T/efg_ios.zip" >/dev/null
rm -f "$ROOT"/export/efg_ios.zip.enc.* "$ROOT"/export/efg_ios.zip.sha256
sha256sum "$T/efg_ios.zip" | cut -d' ' -f1 > "$ROOT/export/efg_ios.zip.sha256"
openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -md sha256 -salt -in "$T/efg_ios.zip" -out "$T/efg_ios.zip.enc" -pass "file:$KEY"
python3 - "$KEY" "$T/efg_ios.zip.enc" > "$ROOT/export/efg_ios.zip.enc.hmac" <<'PY'
import hmac, hashlib, sys
k = open(sys.argv[1]).read().strip().encode()
mk = hashlib.pbkdf2_hmac("sha256", k, b"efg-export-mac", 200000)
h = hmac.new(mk, digestmod=hashlib.sha256)
with open(sys.argv[2], "rb") as f:
    for b in iter(lambda: f.read(1 << 20), b""): h.update(b)
print(h.hexdigest())
PY
split -b 94371840 -d -a 3 --numeric-suffixes=1 "$T/efg_ios.zip.enc" "$ROOT/export/efg_ios.zip.enc."
cp "$SRC/build_info.txt" "$ROOT/export/build_info.txt"
rm -rf "$T"
ls -l "$ROOT/export"
