#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="${JUICE_LAUNCHER_BUILD_DIR:-$ROOT/build/launchers}"
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
  echo "Unsafe launcher build path: $OUT" >&2; exit 2;
};; esac
rm -rf "$OUT"
mkdir -p "$OUT"
for source in grape-trace-parent grape-nested-wrapper; do
  "$CC" "${target_flags[@]}" -O2 "$ROOT/launcher/$source.c" -o "$OUT/$source"
done

LDID_BIN="${LDID:-}"
if test -z "$LDID_BIN" && test -x /var/jb/usr/bin/ldid; then LDID_BIN=/var/jb/usr/bin/ldid; fi
if test -z "$LDID_BIN" && test -n "${JUICE_IOS_TOOLCHAIN:-}" && test -x "$JUICE_IOS_TOOLCHAIN/bin/ldid"; then LDID_BIN="$JUICE_IOS_TOOLCHAIN/bin/ldid"; fi
if test -z "$LDID_BIN"; then LDID_BIN="$(command -v ldid 2>/dev/null || true)"; fi
if test -n "$LDID_BIN" && test -x "$LDID_BIN"; then
  for binary in "$OUT/grape-trace-parent" "$OUT/grape-nested-wrapper"; do
    "$LDID_BIN" -S"$ROOT/config/child-entitlements.plist" -Cadhoc "$binary"
  done
fi
echo "JUICE_LAUNCHERS_BUILD_OK path=$OUT"
