#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/x86_64-build.env"
CACHE="${JUICE_X64_CACHE:-$ROOT/build/x86_64-cache}"
TOOLCHAIN="$CACHE/$JUICE_LLVM_MINGW_DIRNAME"
MOLTENVK_ROOT="${JUICE_GRAPHICS_DEPS:-$ROOT/build/deps}/moltenvk-${JUICE_MOLTENVK_VERSION:-v1.4.2}"
VULKAN_INCLUDE="${JUICE_VULKAN_INCLUDE:-$MOLTENVK_ROOT/MoltenVK/MoltenVK/include}"
OUTPUT="${JUICE_GRAPHICS_SMOKE_BUILD:-$ROOT/build/graphics-smokes}"

source "$ROOT/config/graphics-build.env"
VULKAN_INCLUDE="${JUICE_VULKAN_INCLUDE:-${JUICE_GRAPHICS_DEPS:-$ROOT/build/deps}/moltenvk-$JUICE_MOLTENVK_VERSION/MoltenVK/MoltenVK/include}"
case "$OUTPUT" in "$ROOT"/build/*) ;; *) echo "Unsafe graphics smoke output: $OUTPUT" >&2; exit 2;; esac
test -f "$VULKAN_INCLUDE/vulkan/vulkan.h" || bash "$ROOT/scripts/fetch-moltenvk-linux.sh"
test -f "$VULKAN_INCLUDE/vulkan/vulkan.h" || { echo "Missing Vulkan headers: $VULKAN_INCLUDE" >&2; exit 2; }
bash "$ROOT/scripts/bootstrap-x86_64-toolchain-linux.sh"
mkdir -p "$OUTPUT/arm64" "$OUTPUT/x86_64"

for architecture in arm64 x86_64; do
  case "$architecture" in
    arm64) compiler="$TOOLCHAIN/bin/aarch64-w64-mingw32-clang" ;;
    x86_64) compiler="$TOOLCHAIN/bin/x86_64-w64-mingw32-clang" ;;
  esac
  test -x "$compiler" || { echo "Missing compiler: $compiler" >&2; exit 2; }
  common_flags=( -Os -Wall -Wextra -fno-builtin -fno-stack-protector -nostdlib
                 -Wl,--entry,mainCRTStartup -Wl,--subsystem,windows )
  "$compiler" "${common_flags[@]}" -I"$VULKAN_INCLUDE" \
    "$ROOT/tests/graphics/vulkan-smoke.c" -lkernel32 -luser32 -lmsvcrt \
    -o "$OUTPUT/$architecture/juice-vulkan-smoke.exe"
  "$compiler" "${common_flags[@]}" \
    "$ROOT/tests/graphics/d3d11-smoke.c" -lkernel32 \
    -o "$OUTPUT/$architecture/juice-d3d11-smoke.exe"
  "$compiler" "${common_flags[@]}" \
    "$ROOT/tests/graphics/d3d12-smoke.c" -lkernel32 \
    -o "$OUTPUT/$architecture/juice-d3d12-smoke.exe"
done

for executable in "$OUTPUT"/*/*.exe; do
  file "$executable"
done
(
  cd "$OUTPUT"
  LC_ALL=C find arm64 x86_64 -type f -name '*.exe' -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)
echo "JUICE_GRAPHICS_SMOKES_BUILD_OK path=$OUTPUT"
