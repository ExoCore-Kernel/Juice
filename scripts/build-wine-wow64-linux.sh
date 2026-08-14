#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/x86_64-build.env"
CACHE="${JUICE_X64_CACHE:-$ROOT/build/x86_64-cache}"
TOOLCHAIN="$CACHE/$JUICE_LLVM_MINGW_DIRNAME"
BUILD="${JUICE_WOW64_PE_BUILD:-$ROOT/build/wine-wow64-pe}"
MODULES="${JUICE_X64_RUNTIME_MODULES:-$ROOT/config/runtime-modules.txt}"
JOBS="${JUICE_JOBS:-$(getconf _NPROCESSORS_ONLN)}"

if test "${JUICE_WOW64_RECONFIGURE:-${JUICE_RECONFIGURE:-0}}" = 1 || test ! -f "$BUILD/Makefile"; then
  bash "$ROOT/scripts/configure-wine-wow64-linux.sh"
else
  echo "JUICE_WOW64_CONFIGURE_REUSE path=$BUILD"
fi
export PATH="$TOOLCHAIN/bin:/usr/local/bin:/usr/bin:/bin"

mapfile -t base_targets < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$MODULES")
targets=()
for target in "${base_targets[@]}"; do
  case "$target" in
    programs/juicegui/*|programs/juicetextsmoke/*) continue ;;
  esac
  targets+=("${target/aarch64-windows/i386-windows}")
done

test "${#targets[@]}" -gt 0 || { echo "WoW64 runtime target list is empty." >&2; exit 2; }
make -C "$BUILD" -j "$JOBS" "${targets[@]}"

bad=0
for target in "${targets[@]}"; do
  module="$BUILD/$target"
  test -s "$module" || { echo "Missing i386 module: $target" >&2; bad=$((bad + 1)); continue; }
  machine="$("$TOOLCHAIN/bin/llvm-readobj" --file-headers "$module" 2>/dev/null |
    sed -n 's/^  Machine: //p')"
  case "$machine" in
    IMAGE_FILE_MACHINE_I386*) ;;
    *) echo "Unexpected WoW64 module machine $machine: $target" >&2; bad=$((bad + 1));;
  esac
done

test "$bad" -eq 0
echo "JUICE_WOW64_BUILD_OK path=$BUILD modules=${#targets[@]}"
