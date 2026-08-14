#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUTPUT="${JUICE_TIPA_OUTPUT:-}"
TOOLS="${JUICE_WINE_TOOLS_BUILD:-$ROOT/build/wine-tools-linux}"
WINE_BUILD="${JUICE_WINE_BUILD:-$ROOT/build/wine-ios}"
PE_BUILD="${JUICE_PE_BUILD:-$ROOT/build/wine-arm64-pe}"

"$ROOT/scripts/preflight-linux-x86_64.sh"

if test "${JUICE_REBUILD_HOST_TOOLS:-0}" = 1 || \
   test ! -x "$TOOLS/tools/makedep" || \
   test ! -x "$TOOLS/tools/winebuild/winebuild"; then
  "$ROOT/scripts/build-wine-tools-linux.sh"
else
  echo "JUICE_WINE_TOOLS_REUSE path=$TOOLS"
fi

if test "${JUICE_RECONFIGURE:-0}" = 1 || test ! -f "$WINE_BUILD/Makefile"; then
  "$ROOT/scripts/configure-wine-linux.sh"
else
  echo "JUICE_WINE_CONFIGURE_REUSE path=$WINE_BUILD"
fi
if test "${JUICE_RECONFIGURE:-0}" = 1 || test ! -f "$PE_BUILD/Makefile"; then
  "$ROOT/scripts/configure-wine-pe-linux.sh"
else
  echo "JUICE_PE_CONFIGURE_REUSE path=$PE_BUILD"
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
