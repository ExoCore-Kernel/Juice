#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="${JUICE_APP_BUILD_DIR:-$ROOT/build/app/Juice.app}"
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
  echo "Unsafe app build path: $OUT" >&2; exit 2;
};; esac
rm -rf "$OUT"
mkdir -p "$OUT"

"$CC" -target "arm64-apple-ios$MIN_IOS" -arch arm64 -isysroot "$SDK" \
  "-miphoneos-version-min=$MIN_IOS" -fobjc-arc -fblocks -O2 \
  "$ROOT/app/main.m" "$ROOT/app/JuiceZip.m" "$ROOT/app/JuiceLegacyWin32.m" \
  -framework UIKit -framework Foundation -framework QuartzCore \
  -framework CoreGraphics -lz -o "$OUT/Juice"
cp "$ROOT/config/Info.plist" "$OUT/Info.plist"

if test -x /var/jb/usr/bin/ldid; then
  /var/jb/usr/bin/ldid -S"$ROOT/config/app-entitlements.plist" -Cadhoc "$OUT/Juice"
elif command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - --entitlements "$ROOT/config/app-entitlements.plist" "$OUT/Juice"
fi

echo "JUICE_APP_BUILD_OK path=$OUT/Juice"
