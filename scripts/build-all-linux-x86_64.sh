#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUTPUT="${JUICE_TIPA_OUTPUT:-}"

"$ROOT/scripts/preflight-linux-x86_64.sh"
"$ROOT/scripts/build-wine-tools-linux.sh"

if test "${JUICE_RECONFIGURE:-0}" = 1 || test ! -f "${JUICE_WINE_BUILD:-$ROOT/build/wine-ios}/Makefile"; then
  "$ROOT/scripts/configure-wine-linux.sh"
fi
if test "${JUICE_RECONFIGURE:-0}" = 1 || test ! -f "${JUICE_PE_BUILD:-$ROOT/build/wine-arm64-pe}/Makefile"; then
  "$ROOT/scripts/configure-wine-pe-linux.sh"
fi

"$ROOT/scripts/build-wine-linux.sh"

# Reuse the upstream app/runtime assembly paths; they inherit these cross-build inputs.
export CC="${JUICE_IOS_CC:-$ROOT/toolchain/juice-ios-cc}"
export IOS_SDK="${IOS_SDK:?Set IOS_SDK to an iPhoneOS device SDK directory}"
export JUICE_IOS_TOOLCHAIN="${JUICE_IOS_TOOLCHAIN:-$ROOT/build/ios-toolchain}"
"$ROOT/scripts/assemble-runtime.sh"

x64_stage=""
if test "${JUICE_BUILD_X64:-0}" = 1; then
  "$ROOT/scripts/build-experimental-x86_64-linux.sh"
  x64_stage="${JUICE_X64_RUNTIME_STAGE:-$ROOT/build/x86_64-runtime-stage}"
fi

export JUICE_REQUIRE_SIGNING=1
if test -n "$x64_stage"; then
  export JUICE_X64_RUNTIME_STAGE="$x64_stage"
fi
if test -n "$OUTPUT"; then
  "$ROOT/scripts/package-tipa.sh" "$OUTPUT"
else
  "$ROOT/scripts/package-tipa.sh"
fi

echo "JUICE_LINUX_X86_64_BUILD_OK x64=${JUICE_BUILD_X64:-0}"
