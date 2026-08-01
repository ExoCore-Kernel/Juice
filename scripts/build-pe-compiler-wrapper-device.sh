#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
JBROOT="${JBROOT:-/var/jb}"
SDK="${IOS_SDK:-$JBROOT/usr/share/SDKs/iPhoneOS.sdk}"
SOURCE="$ROOT/toolchain/juice-pe-clang.c"
OUTPUT="${JUICE_PE_CLANG:-$ROOT/build/toolchain/clang}"

case "$OUTPUT" in
  "$ROOT"/build/*/clang) ;;
  *) test "${JUICE_ALLOW_EXTERNAL_BUILD:-0}" = 1 || {
       echo "Unsafe PE compiler-wrapper path (it must also end in /clang): $OUTPUT" >&2
       exit 2
     };;
esac
test -f "$SOURCE" || { echo "Missing PE wrapper source: $SOURCE" >&2; exit 2; }
test -d "$SDK" || { echo "Missing iPhoneOS SDK: $SDK" >&2; exit 2; }
test -x "$ROOT/toolchain/juice-cc" || { echo "Missing CoreTrust compiler wrapper." >&2; exit 2; }

verify_output()
{
  test -x "$OUTPUT" || { echo "PE compiler wrapper was not built." >&2; exit 3; }
  "$JBROOT/usr/bin/file" "$OUTPUT" | grep -Eq 'Mach-O.*arm64.*executable' || {
    echo "Unexpected PE compiler wrapper output: $OUTPUT" >&2
    exit 3
  }
  JUICE_INCBIN_PACKER="$ROOT/toolchain/juice-pack-incbins.py" \
    "$OUTPUT" --version >/dev/null
}

if test -x "$OUTPUT" && test "$OUTPUT" -nt "$SOURCE"; then
  verify_output
  echo "JUICE_PE_COMPILER_WRAPPER_OK path=$OUTPUT cached=1"
  exit 0
fi

mkdir -p "$(dirname -- "$OUTPUT")"
export PATH="$JBROOT/usr/bin:$JBROOT/usr/sbin:$PATH"
"$ROOT/toolchain/juice-cc" -target arm64-apple-ios14.0 -arch arm64 \
  -isysroot "$SDK" -miphoneos-version-min=14.0 -O2 -Wall -Wextra \
  "$SOURCE" -o "$OUTPUT"

verify_output
echo "JUICE_PE_COMPILER_WRAPPER_OK path=$OUTPUT cached=0"
