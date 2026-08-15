#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="${JUICE_APP_BUILD_DIR:-$ROOT/build/app/Juice.app}"
MIN_IOS="${JUICE_MIN_IOS:-14.0}"

target_flags=()
if command -v xcrun >/dev/null 2>&1; then
  SDK="${IOS_SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}"
  CC="${CC:-$(xcrun --sdk iphoneos --find clang)}"
  target_flags=(-target "arm64-apple-ios$MIN_IOS" -arch arm64 -isysroot "$SDK" "-miphoneos-version-min=$MIN_IOS")
elif test "$(uname -s)" = Linux; then
  IOS_TOOLCHAIN="${JUICE_IOS_TOOLCHAIN:-$ROOT/build/ios-toolchain}"
  SDK="${IOS_SDK:-}"
  if test -z "$SDK" && test -d "$IOS_TOOLCHAIN/SDK"; then
    SDK="$(find "$IOS_TOOLCHAIN/SDK" -maxdepth 2 -type d -name 'iPhoneOS*.sdk' -print -quit 2>/dev/null || true)"
  fi
  CC="${CC:-$ROOT/toolchain/juice-ios-cc}"
  export JUICE_IOS_TOOLCHAIN="$IOS_TOOLCHAIN" IOS_SDK="$SDK"
else
  JBROOT="${JBROOT:-/var/jb}"
  SDK="${IOS_SDK:-$JBROOT/usr/share/SDKs/iPhoneOS.sdk}"
  CC="${CC:-$JBROOT/usr/bin/clang}"
  target_flags=(-target "arm64-apple-ios$MIN_IOS" -arch arm64 -isysroot "$SDK" "-miphoneos-version-min=$MIN_IOS")
fi

if [[ "$CC" == */* ]]; then
  test -x "$CC" || { echo "Missing clang: $CC" >&2; exit 2; }
else
  command -v "$CC" >/dev/null 2>&1 || { echo "Missing clang: $CC" >&2; exit 2; }
fi
test -d "$SDK" || { echo "Missing iPhoneOS SDK: $SDK" >&2; exit 2; }
case "$OUT" in "$ROOT"/build/*) ;; *) test "${JUICE_ALLOW_EXTERNAL_BUILD:-0}" = 1 || {
  echo "Unsafe app build path: $OUT" >&2; exit 2;
};; esac
rm -rf "$OUT"
mkdir -p "$OUT"

"$CC" "${target_flags[@]}" -fobjc-arc -fblocks -O2 \
  "$ROOT/app/main.m" "$ROOT/app/JuiceZip.m" "$ROOT/app/JuicePrefixRepair.m" \
  "$ROOT/app/JuiceLegacyWin32.m" "$ROOT/app/JuiceLogExport.m" \
  "$ROOT/app/JuiceMultiWindowFix.m" "$ROOT/app/JuiceFramebufferFix.m" \
  "$ROOT/app/JuiceBootProgress.m" \
  -framework UIKit -framework Foundation -framework QuartzCore \
  -framework CoreGraphics -lz -o "$OUT/Juice"
cp "$ROOT/config/Info.plist" "$OUT/Info.plist"

# Keep the repository-side icon payloads text-only so the same GitHub tooling
# can update them, then materialize normal PNG resources into Juice.app here.
python3 - "$ROOT/resources" "$OUT" <<'PY'
import base64
import pathlib
import sys

source = pathlib.Path(sys.argv[1])
destination = pathlib.Path(sys.argv[2])
icons = sorted(source.glob("AppIcon*.png.b64"))
if not icons:
    raise SystemExit("Missing Juice app icon resources.")
for encoded in icons:
    output = destination / encoded.name[:-4]
    output.write_bytes(base64.b64decode(encoded.read_text().strip(), validate=True))
print(f"JUICE_APP_ICONS_DECODED count={len(icons)}")
PY
shopt -s nullglob
app_icons=("$OUT"/AppIcon*.png)
shopt -u nullglob
test "${#app_icons[@]}" -gt 0 || { echo "No Juice app icons were decoded." >&2; exit 3; }

LDID_BIN="${LDID:-}"
if test -z "$LDID_BIN" && test -x /var/jb/usr/bin/ldid; then LDID_BIN=/var/jb/usr/bin/ldid; fi
if test -z "$LDID_BIN" && test -n "${JUICE_IOS_TOOLCHAIN:-}" && test -x "$JUICE_IOS_TOOLCHAIN/bin/ldid"; then LDID_BIN="$JUICE_IOS_TOOLCHAIN/bin/ldid"; fi
if test -z "$LDID_BIN"; then LDID_BIN="$(command -v ldid 2>/dev/null || true)"; fi
if test -n "$LDID_BIN" && test -x "$LDID_BIN"; then
  "$LDID_BIN" -S"$ROOT/config/app-entitlements.plist" -Cadhoc "$OUT/Juice"
elif command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - --entitlements "$ROOT/config/app-entitlements.plist" "$OUT/Juice"
fi

echo "JUICE_APP_BUILD_OK path=$OUT/Juice icons=${#app_icons[@]}"
