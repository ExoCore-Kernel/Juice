#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/x86_64-build.env"
CACHE="${JUICE_X64_CACHE:-$ROOT/build/x86_64-cache}"
TOOLCHAIN="$CACHE/llvm-mingw-$JUICE_LLVM_MINGW_VERSION-ucrt-ubuntu-22.04-aarch64"
ARM64_GRAPE="${JUICE_GRAPE_ROOT:-$ROOT/build/runtime-stage/Grape}"
HYBRID="${JUICE_ARM64EC_PE_BUILD:-$ROOT/build/wine-arm64ec-pe}"
FEX_BUILD="${JUICE_FEX_BUILD:-$ROOT/build/fex-arm64ec}"
FEX_DLL="$FEX_BUILD/Bin/libarm64ecfex.dll"
SMOKE="${JUICE_X64_SMOKE_OUTPUT:-$ROOT/build/x86_64-smoke.exe}"
MODULES="${JUICE_X64_RUNTIME_MODULES:-$ROOT/config/runtime-modules.txt}"
STAGE="${JUICE_X64_RUNTIME_STAGE:-$ROOT/build/x86_64-runtime-stage}"
GRAPE="$STAGE/Grape-X64"

case "$STAGE" in
  "$ROOT"/build/*) ;;
  *) test "${JUICE_ALLOW_EXTERNAL_BUILD:-0}" = 1 || {
       echo "Refusing x86-64 runtime stage outside build/: $STAGE" >&2
       exit 2
     };;
esac
test -x "$ARM64_GRAPE/build/wine-ios/loader/wine" || {
  echo "Build or import the working ARM64 Grape runtime first: $ARM64_GRAPE" >&2
  exit 2
}
test -s "$FEX_DLL" || { echo "Build FEX first: $FEX_DLL" >&2; exit 2; }
test -s "$SMOKE" || { echo "Build the x86-64 smoke test first: $SMOKE" >&2; exit 2; }

rm -rf "$GRAPE"
mkdir -p "$GRAPE"
rsync -a "$ARM64_GRAPE/" "$GRAPE/"
mkdir -p "$GRAPE/runtime/lib/wine/aarch64-windows" "$GRAPE/tests" \
  "$GRAPE/prefix-template/drive_c/windows/system32"

mapfile -t targets < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$MODULES")
for target in "${targets[@]}"; do
  module="$HYBRID/$target"
  test -s "$module" || { echo "Missing hybrid module: $target" >&2; exit 3; }
  cp "$module" "$GRAPE/runtime/lib/wine/aarch64-windows/$(basename "$target")"
done
cp "$HYBRID/dlls/ntdll/aarch64-windows/ntdll.dll" \
  "$GRAPE/build/wine-ios/dlls/ntdll/aarch64-windows/ntdll.dll"
cp "$FEX_DLL" "$GRAPE/runtime/lib/wine/aarch64-windows/libarm64ecfex.dll"
cp "$FEX_DLL" "$GRAPE/prefix-template/drive_c/windows/system32/libarm64ecfex.dll"
cp "$HYBRID/programs/juicegui/aarch64-windows/JuiceGUI.exe" \
  "$GRAPE/prefix-template/drive_c/windows/system32/JuiceGUI.exe"
cp "$HYBRID/programs/winemine/aarch64-windows/winemine.exe" \
  "$GRAPE/prefix-template/drive_c/windows/system32/winemine.exe"
cp "$SMOKE" "$GRAPE/tests/x86_64-smoke.exe"
cp "$SMOKE" "$GRAPE/runtime/lib/wine/aarch64-windows/x86_64-smoke.exe"

for target in "${targets[@]}"; do
  staged="$GRAPE/runtime/lib/wine/aarch64-windows/$(basename "$target")"
  format="$("$TOOLCHAIN/bin/llvm-readobj" --file-headers "$staged" 2>/dev/null |
    sed -n 's/^Format: //p')"
  if [[ "$target" == programs/* ]]; then
    valid_formats=" COFF-ARM64 COFF-ARM64X "
  else
    valid_formats=" COFF-ARM64X "
  fi
  [[ "$valid_formats" == *" $format "* ]] || {
    echo "Staged module has an invalid hybrid format: $staged ($format)" >&2
    exit 3
  }
done
(
  cd "$STAGE"
  LC_ALL=C find Grape-X64 -type f -print0 | sort -z |
    xargs -0 sha256sum > X86_64-RUNTIME-MANIFEST.sha256
)
echo "JUICE_X64_RUNTIME_ASSEMBLED path=$GRAPE modules=${#targets[@]}"
