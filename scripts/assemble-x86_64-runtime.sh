#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/x86_64-build.env"
CACHE="${JUICE_X64_CACHE:-$ROOT/build/x86_64-cache}"
TOOLCHAIN="$CACHE/$JUICE_LLVM_MINGW_DIRNAME"
ARM64_GRAPE="${JUICE_GRAPE_ROOT:-$ROOT/build/runtime-stage/Grape}"
HYBRID="${JUICE_ARM64EC_PE_BUILD:-$ROOT/build/wine-arm64ec-pe}"
FEX_BUILD="${JUICE_FEX_BUILD:-$ROOT/build/fex-arm64ec}"
FEX_DLL="$FEX_BUILD/Bin/libarm64ecfex.dll"
SMOKE="${JUICE_X64_SMOKE_OUTPUT:-$ROOT/build/x86_64-smoke.exe}"
MODULES="${JUICE_X64_RUNTIME_MODULES:-$ROOT/config/runtime-modules.txt}"
STAGE="${JUICE_X64_RUNTIME_STAGE:-$ROOT/build/x86_64-runtime-stage}"
GRAPE="$STAGE/Grape-X64"

WOW64="${JUICE_WOW64_PE_BUILD:-$ROOT/build/wine-wow64-pe}"
FEX_WOW64_BUILD="${JUICE_FEX_WOW64_BUILD:-$ROOT/build/fex-wow64}"
FEX_WOW64_DLL="$FEX_WOW64_BUILD/Bin/libwow64fex.dll"
X86_SMOKE="${JUICE_X86_SMOKE_OUTPUT:-$ROOT/build/x86-smoke.exe}"
REQUIRE_WIN32="${JUICE_REQUIRE_WIN32:-0}"

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

win32_ready=0
if test -s "$FEX_WOW64_DLL" && test -s "$X86_SMOKE" && \
   test -s "$WOW64/dlls/ntdll/i386-windows/ntdll.dll"; then
  win32_ready=1
elif test "$REQUIRE_WIN32" = 1; then
  echo "Legacy Win32 was required, but its WoW64/FEX components are incomplete." >&2
  echo "Run: make win32-components" >&2
  exit 2
fi

rm -rf "$GRAPE"
mkdir -p "$GRAPE"
rsync -a "$ARM64_GRAPE/" "$GRAPE/"
mkdir -p "$GRAPE/runtime/lib/wine/aarch64-windows" "$GRAPE/tests" \
  "$GRAPE/prefix-template/drive_c/windows/system32"

mapfile -t targets < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$MODULES")
arm64_programs=0
hybrid_modules=0
for target in "${targets[@]}"; do
  destination="$GRAPE/runtime/lib/wine/aarch64-windows/$(basename "$target")"
  case "$target" in
    programs/*)
      # Grape-X64 begins as a copy of the verified ARM64 Grape runtime. Keep
      # helper EXEs native ARM64; Wine's ARM64EC multiarch build does not expose
      # a hybrid aarch64-windows rule for every program (notably conhost.exe),
      # and ARM64 programs are valid alongside ARM64X DLLs.
      test -s "$destination" || {
        echo "Missing base ARM64 helper program: $target ($destination)" >&2
        exit 3
      }
      arm64_programs=$((arm64_programs + 1))
      ;;
    *)
      module="$HYBRID/$target"
      test -s "$module" || { echo "Missing hybrid module: $target" >&2; exit 3; }
      cp "$module" "$destination"
      hybrid_modules=$((hybrid_modules + 1))
      ;;
  esac
done
cp "$HYBRID/dlls/ntdll/aarch64-windows/ntdll.dll" \
  "$GRAPE/build/wine-ios/dlls/ntdll/aarch64-windows/ntdll.dll"
cp "$FEX_DLL" "$GRAPE/runtime/lib/wine/aarch64-windows/libarm64ecfex.dll"
cp "$FEX_DLL" "$GRAPE/prefix-template/drive_c/windows/system32/libarm64ecfex.dll"
cp "$GRAPE/runtime/lib/wine/aarch64-windows/JuiceGUI.exe" \
  "$GRAPE/prefix-template/drive_c/windows/system32/JuiceGUI.exe"
cp "$GRAPE/runtime/lib/wine/aarch64-windows/winemine.exe" \
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

echo "JUICE_X64_HYBRID_LAYOUT arm64_programs=$arm64_programs hybrid_modules=$hybrid_modules"

if test "$win32_ready" = 1; then
  mkdir -p "$GRAPE/runtime/lib/wine/i386-windows" \
    "$GRAPE/prefix-template/drive_c/windows/syswow64"
  x86_targets=()
  for target in "${targets[@]}"; do
    case "$target" in
      programs/juicegui/*|programs/juicetextsmoke/*) continue ;;
    esac
    x86_targets+=("${target/aarch64-windows/i386-windows}")
  done

  for target in "${x86_targets[@]}"; do
    module="$WOW64/$target"
    test -s "$module" || { echo "Missing Legacy Win32 module: $target" >&2; exit 3; }
    cp "$module" "$GRAPE/runtime/lib/wine/i386-windows/$(basename "$target")"
  done

  cp "$FEX_WOW64_DLL" "$GRAPE/runtime/lib/wine/aarch64-windows/libwow64fex.dll"
  cp "$FEX_WOW64_DLL" "$GRAPE/prefix-template/drive_c/windows/system32/libwow64fex.dll"
  cp "$X86_SMOKE" "$GRAPE/tests/x86-smoke.exe"
  cp "$X86_SMOKE" "$GRAPE/runtime/lib/wine/i386-windows/x86-smoke.exe"

  for target in "${x86_targets[@]}"; do
    staged="$GRAPE/runtime/lib/wine/i386-windows/$(basename "$target")"
    machine="$("$TOOLCHAIN/bin/llvm-readobj" --file-headers "$staged" 2>/dev/null |
      sed -n 's/^  Machine: //p')"
    case "$machine" in
      IMAGE_FILE_MACHINE_I386*) ;;
      *) echo "Staged Legacy Win32 module has invalid machine: $staged ($machine)" >&2; exit 3;;
    esac
  done

  echo "JUICE_WIN32_RUNTIME_INCLUDED modules=${#x86_targets[@]} fex=$FEX_WOW64_DLL"
else
  echo "JUICE_WIN32_RUNTIME_SKIPPED reason=components_missing hint='make win32-components'"
fi

(
  cd "$STAGE"
  LC_ALL=C find Grape-X64 -type f -print0 | sort -z |
    xargs -0 sha256sum > X86_64-RUNTIME-MANIFEST.sha256
)
echo "JUICE_X64_RUNTIME_ASSEMBLED path=$GRAPE modules=${#targets[@]} legacy_win32=$win32_ready"
