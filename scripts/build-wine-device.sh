#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
JBROOT="${JBROOT:-/var/jb}"
NATIVE="${JUICE_WINE_BUILD:-$ROOT/build/wine-ios}"
PEBUILD="${JUICE_PE_BUILD:-$ROOT/build/wine-arm64-pe}"
MODULES="${JUICE_RUNTIME_MODULES:-$ROOT/config/runtime-modules.txt}"
JOBS="${JOBS:-2}"
MAKE="${MAKE:-$JBROOT/usr/bin/make}"
SHELL_BIN="${SHELL_BIN:-$JBROOT/usr/bin/sh}"
SUDO="${SUDO:-$JBROOT/usr/bin/sudo}"
PE_CLANG="${JUICE_PE_CLANG:-$ROOT/build/toolchain/clang}"

test -f "$NATIVE/Makefile" || "$JBROOT/usr/bin/bash" "$ROOT/scripts/configure-wine-device.sh"
export PATH="$JBROOT/usr/bin:$JBROOT/usr/sbin:$PATH"
export JUICE_TRUST_CARRIER="${JUICE_TRUST_CARRIER:-$ROOT/build/trust-carrier}"
export JUICE_PE_BUILD_DIR="$PEBUILD"
export JUICE_INCBIN_PACKER="$ROOT/toolchain/juice-pack-incbins.py"
export JUICE_PYTHON="$JBROOT/usr/bin/python3"

# CoreTrust wrapping invokes TrollStore once for every linked Mach-O. Keep the
# single interactive sudo authorization alive for long builds.
sudo_keepalive_pid=""
stop_sudo_keepalive()
{
  if test -n "$sudo_keepalive_pid"; then
    kill "$sudo_keepalive_pid" 2>/dev/null || true
    wait "$sudo_keepalive_pid" 2>/dev/null || true
  fi
}
trap stop_sudo_keepalive EXIT
"$SUDO" -v
(
  while sleep 45; do
    "$SUDO" -n -v || exit
  done
) &
sudo_keepalive_pid=$!

native_targets=(
  tools/makedep
  tools/winebuild/winebuild
  loader/wine
  server/wineserver
  dlls/ntdll/ntdll.so
  dlls/win32u/win32u.so
  dlls/wineios.drv/wineios.so
  dlls/ws2_32/ws2_32.so
)
"$MAKE" -C "$NATIVE" -j"$JOBS" SHELL="$SHELL_BIN" PWD="$NATIVE" "${native_targets[@]}"

if test -z "${JUICE_PE_CLANG+x}"; then
  "$JBROOT/usr/bin/bash" "$ROOT/scripts/build-pe-compiler-wrapper-device.sh"
fi
if test ! -f "$PEBUILD/Makefile" ||
   ! grep -Fq "aarch64_CC = $PE_CLANG" "$PEBUILD/Makefile"; then
  "$JBROOT/usr/bin/bash" "$ROOT/scripts/configure-wine-pe-device.sh"
fi
test -f "$MODULES" || { echo "Missing runtime module manifest: $MODULES" >&2; exit 3; }
mapfile -t pe_targets < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$MODULES")
test "${#pe_targets[@]}" -ge 20 || { echo "Runtime module manifest is unexpectedly short." >&2; exit 3; }

for target in "${pe_targets[@]}"; do
  grep -Fq "$target:" "$PEBUILD/Makefile" || {
    echo "Configured PE build has no target: $target" >&2
    echo "Rerun with JUICE_RECONFIGURE=1 if the source or manifest changed." >&2
    exit 4
  }
done

if test "${JUICE_BUILD_ALL_PE:-0}" = 1; then
  mapfile -t pe_targets < <(
    grep -Eo '(dlls|programs)/[A-Za-z0-9_.+-]+/aarch64-windows/[A-Za-z0-9_.+-]+\.(dll|exe|drv)' \
      "$PEBUILD/Makefile" | sort -u
  )
fi

echo "JUICE_PE_TARGETS count=${#pe_targets[@]} all=${JUICE_BUILD_ALL_PE:-0}"
"$MAKE" -C "$PEBUILD" -j"$JOBS" SHELL="$SHELL_BIN" PWD="$PEBUILD" "${pe_targets[@]}"

ntdll="$PEBUILD/dlls/ntdll/aarch64-windows/ntdll.dll"
test -s "$ntdll" || { echo "The PE ntdll.dll was not built." >&2; exit 5; }
"$JBROOT/usr/bin/python3" "$ROOT/scripts/patch-pe-shared-data.py" "$ntdll"

for target in "${pe_targets[@]}"; do
  output="$PEBUILD/$target"
  test -s "$output" || { echo "Missing built PE target: $target" >&2; exit 6; }
  "$JBROOT/usr/bin/file" "$output" | grep -Eq 'PE32\+.*Aarch64' || {
    echo "Unexpected PE output: $output" >&2; exit 6;
  }
done

mkdir -p "$ROOT/build/manifests"
(
  cd "$PEBUILD"
  sha256sum "${pe_targets[@]}"
) > "$ROOT/build/manifests/pe-runtime.sha256"
(
  cd "$NATIVE"
  sha256sum "${native_targets[@]}"
) > "$ROOT/build/manifests/native-runtime.sha256"
echo "JUICE_WINE_BUILD_OK native=$NATIVE pe=$PEBUILD"
