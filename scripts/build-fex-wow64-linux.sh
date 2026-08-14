#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/x86_64-build.env"
CACHE="${JUICE_X64_CACHE:-$ROOT/build/x86_64-cache}"
TOOLCHAIN="$CACHE/$JUICE_LLVM_MINGW_DIRNAME"
SOURCE="${JUICE_FEX_SOURCE:-$ROOT/build/fex-source}"
BUILD="${JUICE_FEX_WOW64_BUILD:-$ROOT/build/fex-wow64}"
JOBS="${JUICE_JOBS:-$(getconf _NPROCESSORS_ONLN)}"
LOGDIR="${JUICE_BUILD_LOG_DIR:-$ROOT/build/logs}"
LOG="$LOGDIR/fex-wow64.log"
RETRY_LOG="$LOGDIR/fex-wow64-retry.log"

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
mkdir -p "$LOGDIR"

if test -f "$BUILD/CMakeCache.txt" && test "${JUICE_FEX_WOW64_RECONFIGURE:-${JUICE_FEX_RECONFIGURE:-0}}" != 1; then
  echo "JUICE_FEX_WOW64_CONFIGURE_REUSE path=$BUILD"
else
  echo "JUICE_FEX_WOW64_CONFIGURE_BUILD path=$BUILD"
  cmake -S "$SOURCE" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$SOURCE/Data/CMake/toolchain_mingw.cmake" \
    -DENABLE_LTO=False \
    -DMINGW_TRIPLE=aarch64-w64-mingw32 \
    -DBUILD_TESTS=False \
    -DCMAKE_C_FLAGS=-DFEX_JUICE_IOS=1 \
    -DCMAKE_CXX_FLAGS=-DFEX_JUICE_IOS=1
fi

echo "JUICE_FEX_WOW64_BUILD_STAGE target=wow64fex jobs=$JOBS log=$LOG"
set +e
cmake --build "$BUILD" --target wow64fex --parallel "$JOBS" 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e

if test "$status" -ne 0; then
  echo "JUICE_FEX_WOW64_PARALLEL_RETRY status=$status log=$RETRY_LOG"
  set +e
  cmake --build "$BUILD" --target wow64fex --parallel 1 --verbose 2>&1 | tee "$RETRY_LOG"
  status=${PIPESTATUS[0]}
  set -e
  if test "$status" -ne 0; then
    echo "JUICE_FEX_WOW64_BUILD_FAILED status=$status log=$RETRY_LOG" >&2
    echo "---- first compiler/linker diagnostics ----" >&2
    grep -Ein -m 40 'fatal error:|error:|undefined reference|unresolved external|ld\.lld:|lld-link:|clang[^:]*: error|gmake(\[[0-9]+\])?: \*\*\*' "$RETRY_LOG" >&2 || true
    echo "---- final FEX WoW64 build context ----" >&2
    tail -n 120 "$RETRY_LOG" >&2 || true
    exit "$status"
  fi
  echo "JUICE_FEX_WOW64_SERIAL_RECOVERY_OK target=wow64fex"
fi

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
