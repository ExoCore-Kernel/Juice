#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

"$ROOT/scripts/build-fex-arm64ec-linux.sh"
"$ROOT/scripts/build-wine-arm64ec-linux.sh"
"$ROOT/scripts/build-x86_64-smoke-linux.sh"
if test -x "${JUICE_GRAPE_ROOT:-$ROOT/build/runtime-stage/Grape}/build/wine-ios/loader/wine"; then
  "$ROOT/scripts/assemble-x86_64-runtime.sh"
else
  echo "JUICE_X64_COMPONENTS_OK runtime_pending=working_ARM64_Grape"
fi
