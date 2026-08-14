#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/x86_64-build.env"
CACHE="${JUICE_X64_CACHE:-$ROOT/build/x86_64-cache}"
TOOLCHAIN="$CACHE/$JUICE_LLVM_MINGW_DIRNAME"
SOURCE="${JUICE_FEX_SOURCE:-$ROOT/build/fex-source}"
BUILD="${JUICE_FEX_BUILD:-$ROOT/build/fex-arm64ec}"
JOBS="${JUICE_JOBS:-$(getconf _NPROCESSORS_ONLN)}"
LOGDIR="${JUICE_BUILD_LOG_DIR:-$ROOT/build/logs}"
LOG="$LOGDIR/fex-arm64ec.log"
RETRY_LOG="$LOGDIR/fex-arm64ec-retry.log"

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
mkdir -p "$LOGDIR"

# CMake configure is stable for a pinned FEX source/toolchain pair. Reuse an
# existing cache on normal retries so a compile failure does not make the user
# pay the configure cost again. JUICE_FEX_RECONFIGURE=1 explicitly refreshes it.
if test -f "$BUILD/CMakeCache.txt" && test "${JUICE_FEX_RECONFIGURE:-0}" != 1; then
  echo "JUICE_FEX_CONFIGURE_REUSE path=$BUILD"
else
  echo "JUICE_FEX_CONFIGURE_BUILD path=$BUILD"
  cmake -S "$SOURCE" -B "$BUILD" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$SOURCE/Data/CMake/toolchain_mingw.cmake" \
    -DENABLE_LTO=False \
    -DMINGW_TRIPLE=arm64ec-w64-mingw32 \
    -DBUILD_TESTS=False \
    -DCMAKE_C_FLAGS=-DFEX_JUICE_IOS=1 \
    -DCMAKE_CXX_FLAGS=-DFEX_JUICE_IOS=1
fi

"$TOOLCHAIN/bin/arm64ec-w64-mingw32-dlltool" \
  -d "$SOURCE/Source/Windows/Defs/ntdll.def" \
  -k \
  -l "$BUILD/Source/Windows/libntdll_ex.a"

# FEX is normally fastest as a parallel build. On POSIXovl/exFAT, however,
# generated-file visibility can occasionally race under a wide parallel build.
# Retry the same incremental target serially before giving up. This preserves
# every object that already compiled and also gives a clean first diagnostic
# when the failure is a genuine source/toolchain problem.
echo "JUICE_FEX_BUILD_STAGE target=arm64ecfex jobs=$JOBS log=$LOG"
set +e
cmake --build "$BUILD" --target arm64ecfex --parallel "$JOBS" 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e

if test "$status" -ne 0; then
  echo "JUICE_FEX_PARALLEL_RETRY status=$status log=$RETRY_LOG"
  set +e
  cmake --build "$BUILD" --target arm64ecfex --parallel 1 --verbose 2>&1 | tee "$RETRY_LOG"
  status=${PIPESTATUS[0]}
  set -e
  if test "$status" -ne 0; then
    echo "JUICE_FEX_BUILD_FAILED status=$status log=$RETRY_LOG" >&2
    echo "---- first compiler/linker diagnostics ----" >&2
    grep -Ein -m 40 'fatal error:|error:|undefined reference|unresolved external|ld\.lld:|lld-link:|clang[^:]*: error|gmake(\[[0-9]+\])?: \*\*\*' "$RETRY_LOG" >&2 || true
    echo "---- final FEX build context ----" >&2
    tail -n 120 "$RETRY_LOG" >&2 || true
    exit "$status"
  fi
  echo "JUICE_FEX_SERIAL_RECOVERY_OK target=arm64ecfex"
fi

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
