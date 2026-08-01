#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
JBROOT="${JBROOT:-/var/jb}"
BASH_BIN="$JBROOT/usr/bin/bash"
OUTPUT="${1:-$ROOT/dist/Juice-$(date +%Y%m%d-%H%M%S).tipa}"
TRUST_CARRIER="${JUICE_TRUST_CARRIER:-$ROOT/build/trust-carrier}"
export PATH="$JBROOT/usr/bin:$JBROOT/usr/sbin:/usr/bin:/bin:$PATH"

"$BASH_BIN" "$ROOT/scripts/preflight-device.sh"
"$BASH_BIN" "$ROOT/scripts/verify-source.sh"

if test ! -d "$TRUST_CARRIER/Payload/JuiceTrust.app" ||
   test "${JUICE_REBUILD_TRUST_CARRIER:-0}" = 1; then
  "$BASH_BIN" "$ROOT/scripts/bootstrap-trust-carrier-device.sh"
fi

"$BASH_BIN" "$ROOT/scripts/build-pe-compiler-wrapper-device.sh"

if test ! -f "${JUICE_WINE_BUILD:-$ROOT/build/wine-ios}/Makefile" ||
   test "${JUICE_RECONFIGURE:-0}" = 1; then
  "$BASH_BIN" "$ROOT/scripts/configure-wine-device.sh"
fi
if test ! -f "${JUICE_PE_BUILD:-$ROOT/build/wine-arm64-pe}/Makefile" ||
   test "${JUICE_RECONFIGURE:-0}" = 1; then
  "$BASH_BIN" "$ROOT/scripts/configure-wine-pe-device.sh"
fi

"$BASH_BIN" "$ROOT/scripts/build-wine-device.sh"
"$BASH_BIN" "$ROOT/scripts/assemble-runtime.sh"
"$BASH_BIN" "$ROOT/scripts/package-tipa.sh" "$OUTPUT"

echo "JUICE_DEVICE_BUILD_OK path=$OUTPUT"
