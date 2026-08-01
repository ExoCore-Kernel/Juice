#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
JBROOT="${JBROOT:-/var/jb}"
WORK="$ROOT/build/zip-test"
TEST="$WORK/JuiceZipTest"
mkdir -p "$WORK"

"$ROOT/toolchain/juice-cc" -target arm64-apple-ios14.0 -arch arm64 \
  -isysroot "$JBROOT/usr/share/SDKs/iPhoneOS.sdk" -miphoneos-version-min=14.0 \
  -fobjc-arc -O2 -I"$ROOT/app" "$ROOT/app/JuiceZip.m" \
  "$ROOT/app/tests/ZipExtractorTests.m" -framework Foundation -lz -o "$TEST"

"$JBROOT/usr/bin/python3" - "$WORK" <<'PY'
import pathlib, sys, zipfile
root = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(root / "portable.zip", "w", zipfile.ZIP_DEFLATED) as z:
    z.writestr("PortableGame.exe", b"MZ-portable-test")
    z.writestr("helper.dll", b"dependency")
    z.writestr("assets/settings.dat", b"settings")
    z.comment = b"comment containing PK\x05\x06 but not an EOCD"
with zipfile.ZipFile(root / "unsafe.zip", "w") as z:
    z.writestr("../escape.txt", b"must not escape")
PY

rm -rf "$WORK/output" "$WORK/unsafe-output" "$WORK/escape.txt"
"$TEST" "$WORK/portable.zip" "$WORK/output"
test "$(cat "$WORK/output/helper.dll")" = dependency
if "$TEST" "$WORK/unsafe.zip" "$WORK/unsafe-output"; then
  echo "Unsafe ZIP unexpectedly succeeded." >&2
  exit 3
fi
test ! -e "$WORK/escape.txt"
echo "JUICE_ZIP_TESTS_OK"
