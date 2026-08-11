#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

bash "$ROOT/scripts/build-fex-wow64-linux.sh"
bash "$ROOT/scripts/build-wine-wow64-linux.sh"
bash "$ROOT/scripts/build-x86-smoke-linux.sh"

echo "JUICE_WIN32_COMPONENTS_OK fex=$ROOT/build/fex-wow64 wine=$ROOT/build/wine-wow64-pe smoke=$ROOT/build/x86-smoke.exe"
