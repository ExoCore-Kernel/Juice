#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/x86_64-build.env"
NATIVE="${JUICE_WINE_BUILD:-$ROOT/build/wine-ios}"
PEBUILD="${JUICE_PE_BUILD:-$ROOT/build/wine-arm64-pe}"
MODULES="${JUICE_RUNTIME_MODULES:-$ROOT/config/runtime-modules.txt}"
CACHE="${JUICE_X64_CACHE:-$ROOT/build/x86_64-cache}"
TOOLCHAIN="$CACHE/$JUICE_LLVM_MINGW_DIRNAME"
JOBS="${JOBS:-${JUICE_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}}"
MAKE="${MAKE:-make}"
SHELL_BIN="${SHELL_BIN:-/bin/bash}"
PE_CLANG="${JUICE_REAL_PE_CLANG:-${JUICE_PE_CLANG:-$TOOLCHAIN/bin/aarch64-w64-mingw32-clang}}"
PE_WRAPPER="${JUICE_PE_WRAPPER:-$ROOT/build/toolchain-linux/clang}"
PE_PACKER="${JUICE_INCBIN_PACKER:-$ROOT/toolchain/juice-pack-incbins.py}"
PE_PYTHON="${JUICE_PYTHON:-$(command -v python3 || true)}"
LOGDIR="${JUICE_BUILD_LOG_DIR:-$ROOT/build/logs}"
IOS_CC="${JUICE_IOS_CC:-$ROOT/toolchain/juice-ios-cc}"
CACHE_SHIM_SOURCE="$ROOT/scripts/ios-clear-cache-shim.c"
CACHE_SHIM_DIR="$ROOT/build/ios-shims"
CACHE_SHIM_OBJ="$CACHE_SHIM_DIR/clear-cache.o"

case "$(uname -m)" in x86_64|amd64) ;; *) echo "build-wine-linux.sh currently targets an x86_64 Linux host." >&2; exit 2;; esac

test -f "$NATIVE/Makefile" || "$ROOT/scripts/configure-wine-linux.sh"
test -f "$PEBUILD/Makefile" || "$ROOT/scripts/configure-wine-pe-linux.sh"
test -f "$MODULES" || { echo "Missing runtime module manifest: $MODULES" >&2; exit 3; }
test -f "$CACHE_SHIM_SOURCE" || { echo "Missing iOS clear-cache shim: $CACHE_SHIM_SOURCE" >&2; exit 3; }
test -x "$PE_CLANG" || { echo "Missing real ARM64 PE compiler: $PE_CLANG" >&2; exit 3; }
test -n "$PE_PYTHON" -a -x "$PE_PYTHON" || { echo "Missing Python 3 for PE resource packing." >&2; exit 3; }
test -r "$PE_PACKER" || { echo "Missing PE incbin packer: $PE_PACKER" >&2; exit 3; }
mkdir -p "$LOGDIR" "$CACHE_SHIM_DIR"

JUICE_PE_WRAPPER="$PE_WRAPPER" \
JUICE_REAL_PE_CLANG="$PE_CLANG" \
JUICE_PYTHON="$PE_PYTHON" \
JUICE_INCBIN_PACKER="$PE_PACKER" \
  /bin/bash "$ROOT/scripts/build-pe-compiler-wrapper-linux.sh"

# Keep these exported while Wine's generated rules invoke the wrapper. This is
# also enough to retrofit a previously configured PE Makefile: overriding
# aarch64_CC below replaces the plain clang selected by older Linux configures.
export JUICE_REAL_PE_CLANG="$PE_CLANG"
export JUICE_PYTHON="$PE_PYTHON"
export JUICE_INCBIN_PACKER="$PE_PACKER"
export JUICE_PE_BUILD_DIR="$PEBUILD"

# cctools-port's Clang can lower __builtin___clear_cache to an external
# ___clear_cache symbol that iOS does not export. Build a tiny compatibility
# object once; it forwards that compiler-runtime ABI to sys_icache_invalidate().
if test ! -f "$CACHE_SHIM_OBJ" || test "$CACHE_SHIM_SOURCE" -nt "$CACHE_SHIM_OBJ"; then
  echo "JUICE_IOS_CACHE_SHIM_BUILD output=$CACHE_SHIM_OBJ"
  "$IOS_CC" -c "$CACHE_SHIM_SOURCE" -o "$CACHE_SHIM_OBJ"
else
  echo "JUICE_IOS_CACHE_SHIM_REUSE output=$CACHE_SHIM_OBJ"
fi

# Keep the normal path fast and parallel. If a bulk make fails, retry only the
# requested targets one at a time. This preserves everything already compiled,
# avoids throwing away configured build trees, and produces a readable failing
# target/log instead of interleaved -j output. It also recovers harmless
# parallel/filesystem races on FUSE/POSIX overlay build directories.
make_targets()
{
  local label="$1" build="$2"; shift 2
  local -a common=( -C "$build" SHELL="$SHELL_BIN" PWD="$build" )
  local -a vars=() targets=()
  local arg

  while test "$#" -gt 0; do
    arg="$1"; shift
    if test "$arg" = "--"; then
      targets=("$@")
      break
    fi
    vars+=("$arg")
  done

  local log="$LOGDIR/$label.log"
  echo "JUICE_BUILD_STAGE stage=$label jobs=$JOBS log=$log"
  set +e
  "$MAKE" --output-sync=target "${common[@]}" -j"$JOBS" "${vars[@]}" "${targets[@]}" 2>&1 | tee "$log"
  local status=${PIPESTATUS[0]}
  set -e
  if test "$status" -eq 0; then
    return 0
  fi

  echo "JUICE_BUILD_PARALLEL_RETRY stage=$label status=$status"
  local retry_log="$LOGDIR/$label-retry.log"
  : > "$retry_log"
  for target in "${targets[@]}"; do
    echo "===== $target =====" | tee -a "$retry_log"
    set +e
    "$MAKE" --output-sync=target "${common[@]}" -j1 "${vars[@]}" "$target" 2>&1 | tee -a "$retry_log"
    status=${PIPESTATUS[0]}
    set -e
    if test "$status" -ne 0; then
      echo "JUICE_BUILD_FAILED stage=$label target=$target status=$status log=$retry_log" >&2
      echo "---- likely error lines ----" >&2
      grep -Ei -C 3 '(^|: )(fatal error|error:|undefined reference|ld:|clang: error|make(\[[0-9]+\])?: \*\*\*)' "$retry_log" | tail -n 120 >&2 || true
      return "$status"
    fi
  done
  echo "JUICE_BUILD_SERIAL_RECOVERY_OK stage=$label"
}

native_targets=(
  loader/wine
  loader/wine.inf
  server/wineserver
  dlls/ntdll/ntdll.so
  dlls/crypt32/crypt32.so
  dlls/win32u/win32u.so
  dlls/wineios.drv/wineios.so
  dlls/ws2_32/ws2_32.so
)
native_data_targets=(
  include/windows.applicationmodel.winmd
  include/windows.globalization.winmd
  include/windows.graphics.winmd
  include/windows.media.winmd
  include/windows.networking.winmd
  include/windows.perception.winmd
  include/windows.storage.winmd
  include/windows.system.winmd
  include/windows.ui.winmd
  include/windows.ui.xaml.winmd
)

# Wine expands UNIX_LIBS while generating the configured Makefile, so changing
# RT_LIBS here cannot affect an already-configured tree. The generated Unix
# linker rule reads $(LDFLAGS) at build time, which lets us inject the cache
# shim without reconfiguring or regenerating the Makefile.
make_targets native "$NATIVE" "LDFLAGS+=$CACHE_SHIM_OBJ" -- "${native_targets[@]}" "${native_data_targets[@]}"

# These macOS frameworks are intentionally absent from iPhoneOS. The patched
# mountmgr contains iOS stubs and only needs CoreFoundation.
native_ios_targets=(dlls/mountmgr.sys/mountmgr.so)
make_targets native-ios "$NATIVE" \
  DISKARBITRATION_LIBS= SYSTEMCONFIGURATION_LIBS= CORESERVICES_LIBS= SECURITY_LIBS= \
  -- "${native_ios_targets[@]}"

mapfile -t pe_targets < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$MODULES")
test "${#pe_targets[@]}" -ge 20 || { echo "Runtime module manifest is unexpectedly short." >&2; exit 3; }
for target in "${pe_targets[@]}"; do
  grep -Fq "$target:" "$PEBUILD/Makefile" || {
    echo "Configured Linux PE build has no target: $target" >&2
    echo "Rerun with JUICE_RECONFIGURE=1 if source/configuration changed." >&2
    exit 4
  }
done
if test "${JUICE_BUILD_ALL_PE:-0}" = 1; then
  mapfile -t pe_targets < <(
    grep -Eo '(dlls|programs)/[A-Za-z0-9_.+-]+/aarch64-windows/[A-Za-z0-9_.+-]+\.(dll|exe|drv)' \
      "$PEBUILD/Makefile" | sort -u
  )
fi

echo "JUICE_PE_TARGETS count=${#pe_targets[@]} all=${JUICE_BUILD_ALL_PE:-0} host=x86_64-linux compiler=$PE_WRAPPER"
make_targets pe "$PEBUILD" "aarch64_CC=$PE_WRAPPER" -- "${pe_targets[@]}"

ntdll="$PEBUILD/dlls/ntdll/aarch64-windows/ntdll.dll"
test -s "$ntdll" || { echo "The PE ntdll.dll was not built." >&2; exit 5; }
python3 "$ROOT/scripts/patch-pe-shared-data.py" "$ntdll"

for target in "${pe_targets[@]}"; do
  output="$PEBUILD/$target"
  test -s "$output" || { echo "Missing built PE target: $target" >&2; exit 6; }
  "$TOOLCHAIN/bin/llvm-readobj" --file-headers "$output" 2>/dev/null | \
    grep -Eq 'Machine: IMAGE_FILE_MACHINE_ARM64' || {
      echo "Unexpected ARM64 PE output: $output" >&2
      exit 6
    }
done
for output in \
  "$NATIVE/loader/wine" \
  "$NATIVE/server/wineserver" \
  "$NATIVE/dlls/ntdll/ntdll.so" \
  "$NATIVE/dlls/wineios.drv/wineios.so"; do
  test -s "$output" || { echo "Missing native iOS output: $output" >&2; exit 6; }
  file "$output" | grep -Eq 'Mach-O 64-bit arm64' || {
    echo "Unexpected native iOS output: $output" >&2
    file "$output" >&2 || true
    exit 6
  }
done

mkdir -p "$ROOT/build/manifests"
(
  cd "$PEBUILD"
  sha256sum "${pe_targets[@]}"
) > "$ROOT/build/manifests/pe-runtime.sha256"
(
  cd "$NATIVE"
  sha256sum "${native_targets[@]}" "${native_ios_targets[@]}" \
    "${native_data_targets[@]}"
) > "$ROOT/build/manifests/native-runtime.sha256"

echo "JUICE_WINE_LINUX_BUILD_OK native=$NATIVE pe=$PEBUILD host=x86_64-linux"
