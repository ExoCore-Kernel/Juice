#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/x86_64-build.env"
CACHE="${JUICE_X64_CACHE:-$ROOT/build/x86_64-cache}"
TOOLCHAIN="$CACHE/$JUICE_LLVM_MINGW_DIRNAME"
SOURCE="${JUICE_FEX_SOURCE:-$ROOT/build/fex-source}"
BUILD="${JUICE_FEX_BUILD:-$ROOT/build/fex-arm64ec}"
JOBS="${JUICE_JOBS:-$(getconf _NPROCESSORS_ONLN)}"

case "$BUILD" in
  "$ROOT"/build/*) ;;
  *) test "${JUICE_ALLOW_EXTERNAL_BUILD:-0}" = 1 || {
       echo "Refusing FEX build outside build/: $BUILD" >&2
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
  -DMINGW_TRIPLE=arm64ec-w64-mingw32 \
  -DBUILD_TESTS=False \
  -DCMAKE_C_FLAGS=-DFEX_JUICE_IOS=1 \
  -DCMAKE_CXX_FLAGS=-DFEX_JUICE_IOS=1
"$TOOLCHAIN/bin/arm64ec-w64-mingw32-dlltool" \
  -d "$SOURCE/Source/Windows/Defs/ntdll.def" \
  -k \
  -l "$BUILD/Source/Windows/libntdll_ex.a"
cmake --build "$BUILD" --target arm64ecfex --parallel "$JOBS"

DLL="$BUILD/Bin/libarm64ecfex.dll"
test -s "$DLL" || { echo "FEX translator output is missing: $DLL" >&2; exit 3; }
format="$("$TOOLCHAIN/bin/llvm-readobj" --file-headers "$DLL" |
  sed -n 's/^Format: //p')"
test "$format" = COFF-ARM64EC || {
  echo "Unexpected FEX translator format: $format" >&2
  exit 3
}
sha256sum "$DLL" > "$BUILD/libarm64ecfex.dll.sha256"
echo "JUICE_FEX_BUILD_OK path=$DLL format=$format"
