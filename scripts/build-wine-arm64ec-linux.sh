#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/x86_64-build.env"
CACHE="${JUICE_X64_CACHE:-$ROOT/build/x86_64-cache}"
TOOLCHAIN="$CACHE/$JUICE_LLVM_MINGW_DIRNAME"
BUILD="${JUICE_ARM64EC_PE_BUILD:-$ROOT/build/wine-arm64ec-pe}"
MODULES="${JUICE_X64_RUNTIME_MODULES:-$ROOT/config/runtime-modules.txt}"
JOBS="${JUICE_JOBS:-$(getconf _NPROCESSORS_ONLN)}"

if test "${JUICE_ARM64EC_RECONFIGURE:-${JUICE_RECONFIGURE:-0}}" = 1 || test ! -f "$BUILD/Makefile"; then
  "$ROOT/scripts/configure-wine-arm64ec-linux.sh"
else
  echo "JUICE_ARM64EC_CONFIGURE_REUSE path=$BUILD"
fi
export PATH="$TOOLCHAIN/bin:/usr/local/bin:/usr/bin:/bin"
mapfile -t manifest_targets < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$MODULES")
test "${#manifest_targets[@]}" -gt 0 || { echo "Hybrid runtime manifest is empty." >&2; exit 2; }

# ARM64X is required for Wine DLLs/drivers. Helper EXEs do not need to be
# hybrid: Grape-X64 starts as a copy of the verified ARM64 Grape runtime and
# can execute ARM64 helper programs natively. Some Wine ARM64EC configurations
# intentionally do not expose an aarch64-windows target for programs (for
# example conhost.exe), so do not request nonexistent hybrid program targets.
hybrid_targets=()
program_count=0
for target in "${manifest_targets[@]}"; do
  case "$target" in
    programs/*) program_count=$((program_count + 1)) ;;
    *) hybrid_targets+=("$target") ;;
  esac
done

test "${#hybrid_targets[@]}" -gt 0 || { echo "Hybrid DLL target list is empty." >&2; exit 2; }
echo "JUICE_ARM64EC_TARGETS hybrid=${#hybrid_targets[@]} arm64_program_fallback=$program_count"
make -C "$BUILD" -j "$JOBS" "${hybrid_targets[@]}"

bad=0
for target in "${hybrid_targets[@]}"; do
  module="$BUILD/$target"
  test -s "$module" || { echo "Missing hybrid module: $target" >&2; bad=$((bad + 1)); continue; }
  format="$("$TOOLCHAIN/bin/llvm-readobj" --file-headers "$module" 2>/dev/null |
    sed -n 's/^Format: //p')"
  if test "$format" != COFF-ARM64X; then
    echo "Unexpected hybrid format $format: $target" >&2
    bad=$((bad + 1))
  fi
done
test "$bad" -eq 0
echo "JUICE_ARM64EC_BUILD_OK path=$BUILD hybrid_modules=${#hybrid_targets[@]} arm64_programs=$program_count"
