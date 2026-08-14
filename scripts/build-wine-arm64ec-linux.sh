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
mapfile -t targets < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$MODULES")
test "${#targets[@]}" -gt 0 || { echo "Hybrid runtime manifest is empty." >&2; exit 2; }
make -C "$BUILD" -j "$JOBS" "${targets[@]}"

bad=0
for target in "${targets[@]}"; do
  module="$BUILD/$target"
  test -s "$module" || { echo "Missing hybrid module: $target" >&2; bad=$((bad + 1)); continue; }
  format="$("$TOOLCHAIN/bin/llvm-readobj" --file-headers "$module" 2>/dev/null |
    sed -n 's/^Format: //p')"
  if [[ "$target" == programs/* ]]; then
    valid_formats=" COFF-ARM64 COFF-ARM64X "
  else
    valid_formats=" COFF-ARM64X "
  fi
  if [[ "$valid_formats" != *" $format "* ]]; then
    echo "Unexpected hybrid format $format: $target" >&2
    bad=$((bad + 1))
  fi
done
test "$bad" -eq 0
echo "JUICE_ARM64EC_BUILD_OK path=$BUILD modules=${#targets[@]}"
