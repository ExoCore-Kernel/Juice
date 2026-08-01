#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="${JUICE_LAUNCHER_BUILD_DIR:-$ROOT/build/launchers}"
MIN_IOS="${JUICE_MIN_IOS:-14.0}"

if command -v xcrun >/dev/null 2>&1; then
  SDK="${IOS_SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}"
  CC="${CC:-$(xcrun --sdk iphoneos --find clang)}"
else
  JBROOT="${JBROOT:-/var/jb}"
  SDK="${IOS_SDK:-$JBROOT/usr/share/SDKs/iPhoneOS.sdk}"
  CC="${CC:-$JBROOT/usr/bin/clang}"
fi

test -x "$CC" || { echo "Missing clang: $CC" >&2; exit 2; }
test -d "$SDK" || { echo "Missing iPhoneOS SDK: $SDK" >&2; exit 2; }
case "$OUT" in "$ROOT"/build/*) ;; *) test "${JUICE_ALLOW_EXTERNAL_BUILD:-0}" = 1 || {
  echo "Unsafe launcher build path: $OUT" >&2; exit 2;
};; esac
rm -rf "$OUT"
mkdir -p "$OUT"
for source in grape-trace-parent grape-nested-wrapper; do
  "$CC" -target "arm64-apple-ios$MIN_IOS" -arch arm64 -isysroot "$SDK" \
    "-miphoneos-version-min=$MIN_IOS" -O2 "$ROOT/launcher/$source.c" -o "$OUT/$source"
done

if test -x /var/jb/usr/bin/ldid; then
  for binary in "$OUT/grape-trace-parent" "$OUT/grape-nested-wrapper"; do
    /var/jb/usr/bin/ldid -S"$ROOT/config/child-entitlements.plist" -Cadhoc "$binary"
  done
fi
echo "JUICE_LAUNCHERS_BUILD_OK path=$OUT"
