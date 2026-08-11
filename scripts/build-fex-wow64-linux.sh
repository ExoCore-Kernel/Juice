#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/x86_64-build.env"
CACHE="${JUICE_X64_CACHE:-$ROOT/build/x86_64-cache}"
TOOLCHAIN="$CACHE/llvm-mingw-$JUICE_LLVM_MINGW_VERSION-ucrt-ubuntu-22.04-aarch64"
SOURCE="${JUICE_FEX_SOURCE:-$ROOT/build/fex-source}"
BUILD="${JUICE_FEX_WOW64_BUILD:-$ROOT/build/fex-wow64}"
JOBS="${JUICE_JOBS:-$(getconf _NPROCESSORS_ONLN)}"

case "$BUILD" in
  "$ROOT"/build/*) ;;
  *) test "${JUICE_ALLOW_EXTERNAL_BUILD:-0}" = 1 || {
       echo "Refusing FEX WoW64 build outside build/: $BUILD" >&2
       exit 2
     };;
esac

"$ROOT/scripts/bootstrap-x86_64-toolchain-linux.sh"
"$ROOT/scripts/fetch-fex-linux.sh"
export PATH="$TOOLCHAIN/bin:/usr/local/bin:/usr/bin:/bin"

cmake -S "$SOURCE" -B "$BUILD" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE="$SOURCE/Data/CMake/toolchain_mingw.cmake" \
  -DENABLE_LTO=False \
  -DMINGW_TRIPLE=aarch64-w64-mingw32 \
  -DBUILD_TESTS=False \
  -DCMAKE_C_FLAGS=-DFEX_JUICE_IOS=1 \
  -DCMAKE_CXX_FLAGS=-DFEX_JUICE_IOS=1

cmake --build "$BUILD" --target wow64fex --parallel "$JOBS"

DLL="$BUILD/Bin/libwow64fex.dll"
test -s "$DLL" || { echo "FEX WoW64 translator output is missing: $DLL" >&2; exit 3; }
format="$("$TOOLCHAIN/bin/llvm-readobj" --file-headers "$DLL" |
  sed -n 's/^Format: //p')"
test "$format" = COFF-ARM64 || {
  echo "Unexpected FEX WoW64 translator format: $format" >&2
  exit 3
}
sha256sum "$DLL" > "$BUILD/libwow64fex.dll.sha256"
echo "JUICE_FEX_WOW64_BUILD_OK path=$DLL format=$format"
