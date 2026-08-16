#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUTPUT="${JUICE_METAL_HOST_BUILD:-$ROOT/build/metal-host-smoke}"
APP="$OUTPUT/Payload/JuiceMetalProbe.app"
TIPA="$OUTPUT/JuiceMetalProbe.tipa"
CC="${CC:-$ROOT/toolchain/juice-ios-cc}"
LDID_BIN="${LDID:-$ROOT/build/ios-toolchain/bin/ldid}"
ENTITLEMENTS="${JUICE_METAL_HOST_ENTITLEMENTS:-$ROOT/config/minimal-entitlements.plist}"

case "$OUTPUT" in "$ROOT"/build/*) ;; *) echo "Unsafe Metal probe output: $OUTPUT" >&2; exit 2;; esac
test -x "$CC" || { echo "Missing iOS compiler: $CC" >&2; exit 2; }
test -x "$LDID_BIN" || { echo "Missing ldid: $LDID_BIN" >&2; exit 2; }
test -f "$ENTITLEMENTS" || { echo "Missing Metal probe entitlements: $ENTITLEMENTS" >&2; exit 2; }
rm -rf "$OUTPUT"
mkdir -p "$APP"

"$CC" -fobjc-arc -O2 "$ROOT/tests/graphics/metal-host-smoke.m" \
  -framework UIKit -framework Foundation -framework Metal -framework CoreGraphics \
  -o "$APP/JuiceMetalProbe"
cp "$ROOT/tests/graphics/metal-host-Info.plist" "$APP/Info.plist"
"$LDID_BIN" -S"$ENTITLEMENTS" -Cadhoc "$APP/JuiceMetalProbe"
(
  cd "$OUTPUT"
  zip -qry "$TIPA" Payload
)
sha256sum "$TIPA" >"$TIPA.sha256"
echo "JUICE_METAL_HOST_SMOKE_BUILD_OK path=$TIPA entitlements=$ENTITLEMENTS"
