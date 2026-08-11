#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
JBROOT="${JBROOT:-/var/jb}"
PEBUILD="${JUICE_PE_BUILD:-$ROOT/build/wine-arm64-pe}"
OUT="${JUICE_INSTALLER_TEST_OUT:-$ROOT/build/tests/installers}"
IDT="$ROOT/tests/installers/msi/idt"
MAKE="${MAKE:-$JBROOT/usr/bin/make}"
SHELL_BIN="${SHELL_BIN:-$JBROOT/usr/bin/sh}"

case "$OUT" in
  "$ROOT"/build/*) ;;
  *) test "${JUICE_ALLOW_EXTERNAL_BUILD:-0}" = 1 || {
       echo "Unsafe installer test output: $OUT" >&2; exit 2;
     };;
esac
test -f "$PEBUILD/Makefile" || { echo "Build Grape first." >&2; exit 2; }
mkdir -p "$OUT"
"$MAKE" -C "$PEBUILD" SHELL="$SHELL_BIN" PWD="$PEBUILD" \
  programs/juicesetupsmoke/aarch64-windows/JuiceSetupSmoke.exe
cp "$PEBUILD/programs/juicesetupsmoke/aarch64-windows/JuiceSetupSmoke.exe" \
  "$OUT/JuiceSetupSmoke.exe"

windows_out="Z:${OUT//\//\\}"
windows_idt="Z:${IDT//\//\\}"
rm -f "$OUT/JuiceMSISmoke.msi"
"$ROOT/scripts/run-grape-cli-device.sh" msidb.exe -c \
  -d "$windows_out\\JuiceMSISmoke.msi" -f "$windows_idt" -i "*.idt"

test -s "$OUT/JuiceMSISmoke.msi" || { echo "MSI creation failed." >&2; exit 3; }
(
  cd "$OUT"
  sha256sum JuiceMSISmoke.msi JuiceSetupSmoke.exe > SHA256SUMS
)
echo "JUICE_INSTALLER_SMOKES_OK path=$OUT"
