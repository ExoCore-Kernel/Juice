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
PE_CLANG="${JUICE_PE_CLANG:-$TOOLCHAIN/bin/aarch64-w64-mingw32-clang}"

case "$(uname -m)" in x86_64|amd64) ;; *) echo "build-wine-linux.sh currently targets an x86_64 Linux host." >&2; exit 2;; esac

test -f "$NATIVE/Makefile" || "$ROOT/scripts/configure-wine-linux.sh"
test -f "$PEBUILD/Makefile" || "$ROOT/scripts/configure-wine-pe-linux.sh"
test -f "$MODULES" || { echo "Missing runtime module manifest: $MODULES" >&2; exit 3; }

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

"$MAKE" -C "$NATIVE" -j"$JOBS" SHELL="$SHELL_BIN" PWD="$NATIVE" \
  "${native_targets[@]}" "${native_data_targets[@]}"

# These macOS frameworks are intentionally absent from iPhoneOS.  The patched
# mountmgr contains iOS stubs and only needs CoreFoundation.
native_ios_targets=(dlls/mountmgr.sys/mountmgr.so)
"$MAKE" -C "$NATIVE" -j"$JOBS" SHELL="$SHELL_BIN" PWD="$NATIVE" \
  DISKARBITRATION_LIBS= SYSTEMCONFIGURATION_LIBS= CORESERVICES_LIBS= SECURITY_LIBS= \
  "${native_ios_targets[@]}"

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

echo "JUICE_PE_TARGETS count=${#pe_targets[@]} all=${JUICE_BUILD_ALL_PE:-0} host=x86_64-linux"
"$MAKE" -C "$PEBUILD" -j"$JOBS" SHELL="$SHELL_BIN" PWD="$PEBUILD" "${pe_targets[@]}"

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
