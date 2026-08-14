#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

# POSIX/FUSE overlays do not always preserve executable mode bits reliably.
# These are shell scripts, so invoke them explicitly through bash instead of
# requiring every helper to remain +x on the backing filesystem.
bash "$ROOT/scripts/build-fex-arm64ec-linux.sh"
bash "$ROOT/scripts/build-wine-arm64ec-linux.sh"
bash "$ROOT/scripts/build-x86_64-smoke-linux.sh"

if test "${JUICE_REQUIRE_WIN32:-0}" = 1; then
  bash "$ROOT/scripts/build-experimental-win32-linux.sh"
fi

if test -x "${JUICE_GRAPE_ROOT:-$ROOT/build/runtime-stage/Grape}/build/wine-ios/loader/wine"; then
  bash "$ROOT/scripts/assemble-x86_64-runtime.sh"
else
  echo "JUICE_X64_COMPONENTS_OK runtime_pending=working_ARM64_Grape"
fi
