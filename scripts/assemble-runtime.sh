#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
JBROOT="${JBROOT:-/var/jb}"
export PATH="$JBROOT/usr/bin:$JBROOT/usr/sbin:/usr/bin:/bin:$PATH"
NATIVE="${JUICE_WINE_BUILD:-$ROOT/build/wine-ios}"
PEBUILD="${JUICE_PE_BUILD:-$ROOT/build/wine-arm64-pe}"
MODULES="${JUICE_RUNTIME_MODULES:-$ROOT/config/runtime-modules.txt}"
STAGE="${JUICE_RUNTIME_STAGE:-$ROOT/build/runtime-stage}"
GRAPE="$STAGE/Grape"

case "$STAGE" in "$ROOT"/build/*) ;; *) echo "Unsafe runtime stage: $STAGE" >&2; exit 2;; esac
test -f "$MODULES" || { echo "Missing runtime module manifest: $MODULES" >&2; exit 2; }
rm -rf "$GRAPE"
mkdir -p "$GRAPE/build/wine-ios/server" "$GRAPE/build/wine-ios/loader" \
  "$GRAPE/build/wine-ios/dlls/ntdll/aarch64-windows" \
  "$GRAPE/build/wine-ios/dlls/crypt32" \
  "$GRAPE/build/wine-ios/dlls/dwrite" \
  "$GRAPE/build/wine-ios/dlls/mountmgr.sys" \
  "$GRAPE/build/wine-ios/dlls/win32u" \
  "$GRAPE/build/wine-ios/dlls/wineios.drv" "$GRAPE/build/wine-ios/dlls/ws2_32" \
  "$GRAPE/build/wine-ios/include" "$GRAPE/build/wine-ios/nls" \
  "$GRAPE/runtime/lib/wine/aarch64-windows" \
  "$GRAPE/tools"

cp "$NATIVE/server/wineserver" "$GRAPE/build/wine-ios/server/"
cp "$NATIVE/loader/wine" "$GRAPE/build/wine-ios/loader/"
test -s "$NATIVE/loader/wine.inf" || {
  echo "Missing generated Wine prefix initializer: $NATIVE/loader/wine.inf" >&2
  exit 3
}
cp "$NATIVE/loader/wine.inf" "$GRAPE/build/wine-ios/loader/"
cp "$NATIVE/dlls/ntdll/ntdll.so" "$GRAPE/build/wine-ios/dlls/ntdll/"
cp "$PEBUILD/dlls/ntdll/aarch64-windows/ntdll.dll" \
  "$GRAPE/build/wine-ios/dlls/ntdll/aarch64-windows/"
cp "$NATIVE/dlls/crypt32/crypt32.so" "$GRAPE/build/wine-ios/dlls/crypt32/"
dwrite_unixlib=0
if test -s "$NATIVE/dlls/dwrite/dwrite.so"; then
  cp "$NATIVE/dlls/dwrite/dwrite.so" "$GRAPE/build/wine-ios/dlls/dwrite/"
  dwrite_unixlib=1
fi
cp "$NATIVE/dlls/mountmgr.sys/mountmgr.so" "$GRAPE/build/wine-ios/dlls/mountmgr.sys/"
cp "$NATIVE/dlls/win32u/win32u.so" "$GRAPE/build/wine-ios/dlls/win32u/"
cp "$NATIVE/dlls/wineios.drv/wineios.so" "$GRAPE/build/wine-ios/dlls/wineios.drv/"
cp "$NATIVE/dlls/ws2_32/ws2_32.so" "$GRAPE/build/wine-ios/dlls/ws2_32/"
for winmd in windows.applicationmodel windows.globalization windows.graphics \
  windows.media windows.networking windows.perception windows.storage \
  windows.system windows.ui windows.ui.xaml; do
  test -s "$NATIVE/include/$winmd.winmd" || {
    echo "Missing required Wine metadata: $NATIVE/include/$winmd.winmd" >&2
    exit 3
  }
  cp "$NATIVE/include/$winmd.winmd" "$GRAPE/build/wine-ios/include/"
done

# Wine may resolve a Unix side beside either the build tree or its PE module.
cp "$NATIVE/dlls/wineios.drv/wineios.so" "$GRAPE/runtime/lib/wine/aarch64-windows/wineios.so"
cp "$NATIVE/dlls/ws2_32/ws2_32.so" "$GRAPE/runtime/lib/wine/aarch64-windows/ws2_32.so"
cp "$NATIVE/dlls/crypt32/crypt32.so" "$GRAPE/runtime/lib/wine/aarch64-windows/crypt32.so"
if test "$dwrite_unixlib" = 1; then
  cp "$NATIVE/dlls/dwrite/dwrite.so" "$GRAPE/runtime/lib/wine/aarch64-windows/dwrite.so"
fi
cp "$NATIVE/dlls/mountmgr.sys/mountmgr.so" "$GRAPE/runtime/lib/wine/aarch64-windows/mountmgr.so"
cp "$NATIVE/dlls/win32u/win32u.so" "$GRAPE/runtime/lib/wine/aarch64-windows/win32u.so"

mapfile -t pe_targets < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$MODULES")
for target in "${pe_targets[@]}"; do
  module="$PEBUILD/$target"
  destination="$GRAPE/runtime/lib/wine/aarch64-windows/$(basename "$target")"
  test -s "$module" || { echo "Missing required PE module: $target" >&2; exit 3; }
  if test -f "$destination" && ! cmp -s "$module" "$destination"; then
    echo "Conflicting PE module basename: $target" >&2
    exit 3
  fi
  cp "$module" "$destination"
done

if test "${JUICE_INCLUDE_ALL_BUILT_PE:-0}" = 1; then
  while IFS= read -r -d '' module; do
    destination="$GRAPE/runtime/lib/wine/aarch64-windows/$(basename "$module")"
    if test -f "$destination" && ! cmp -s "$module" "$destination"; then
      echo "Conflicting extra PE module basename: $module" >&2
      exit 3
    fi
    cp "$module" "$destination"
  done < <(find "$PEBUILD/dlls" "$PEBUILD/programs" -type f -path '*/aarch64-windows/*' \
    \( -name '*.dll' -o -name '*.exe' -o -name '*.drv' \) -print0)
fi

cp "$ROOT/wine/nls/"*.nls "$GRAPE/build/wine-ios/nls/"
rsync -a "$ROOT/packaging/prefix-template/" "$GRAPE/prefix-template/"
mkdir -p "$GRAPE/prefix-template/drive_c/windows/system32"
cp "$PEBUILD/programs/juicegui/aarch64-windows/JuiceGUI.exe" \
  "$GRAPE/prefix-template/drive_c/windows/system32/"
cp "$PEBUILD/programs/winemine/aarch64-windows/winemine.exe" \
  "$GRAPE/prefix-template/drive_c/windows/system32/"
"${BASH:-bash}" "$ROOT/scripts/build-launchers.sh"
cp "$ROOT/build/launchers/grape-trace-parent" \
   "$ROOT/build/launchers/grape-nested-wrapper" \
   "$ROOT/build/launchers/juice-lowva-helper" \
   "$GRAPE/tools/"
chmod 755 "$GRAPE/build/wine-ios/server/wineserver" "$GRAPE/build/wine-ios/loader/wine" "$GRAPE/tools/"*

(
  cd "$STAGE"
  LC_ALL=C find Grape -type f -print0 | sort -z | xargs -0 sha256sum > RUNTIME-MANIFEST.sha256
)
module_count="$(find "$GRAPE/runtime/lib/wine/aarch64-windows" -type f | wc -l | tr -d ' ')"
echo "JUICE_RUNTIME_ASSEMBLED path=$GRAPE modules=$module_count dwrite_unixlib=$dwrite_unixlib lowva_helper=$GRAPE/tools/juice-lowva-helper"
