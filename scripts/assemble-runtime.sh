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
NETWORK_SMOKES="${JUICE_NETWORK_SMOKE_BUILD:-$ROOT/build/network-smokes}"

case "$STAGE" in "$ROOT"/build/*) ;; *) echo "Unsafe runtime stage: $STAGE" >&2; exit 2;; esac
test -f "$MODULES" || { echo "Missing runtime module manifest: $MODULES" >&2; exit 2; }
rm -rf "$GRAPE"
mkdir -p "$GRAPE/build/wine-ios/server" "$GRAPE/build/wine-ios/loader" \
  "$GRAPE/build/wine-ios/dlls/ntdll/aarch64-windows" \
  "$GRAPE/build/wine-ios/dlls/crypt32" \
  "$GRAPE/build/wine-ios/dlls/secur32" \
  "$GRAPE/build/wine-ios/dlls/dwrite" \
  "$GRAPE/build/wine-ios/dlls/mountmgr.sys" \
  "$GRAPE/build/wine-ios/dlls/opengl32" \
  "$GRAPE/build/wine-ios/dlls/win32u" \
  "$GRAPE/build/wine-ios/dlls/wineios.drv" "$GRAPE/build/wine-ios/dlls/winevulkan" \
  "$GRAPE/build/wine-ios/dlls/ws2_32" \
  "$GRAPE/build/wine-ios/include" "$GRAPE/build/wine-ios/nls" \
  "$GRAPE/runtime/lib/wine/aarch64-windows" \
  "$GRAPE/runtime/lib/wine/aarch64-unix" \
  "$GRAPE/tools" "$GRAPE/tests"

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
cp "$NATIVE/dlls/secur32/secur32.so" "$GRAPE/build/wine-ios/dlls/secur32/"
dwrite_unixlib=0
if test -s "$NATIVE/dlls/dwrite/dwrite.so"; then
  cp "$NATIVE/dlls/dwrite/dwrite.so" "$GRAPE/build/wine-ios/dlls/dwrite/"
  dwrite_unixlib=1
fi
cp "$NATIVE/dlls/mountmgr.sys/mountmgr.so" "$GRAPE/build/wine-ios/dlls/mountmgr.sys/"
cp "$NATIVE/dlls/opengl32/opengl32.so" "$GRAPE/build/wine-ios/dlls/opengl32/"
cp "$NATIVE/dlls/win32u/win32u.so" "$GRAPE/build/wine-ios/dlls/win32u/"
cp "$NATIVE/dlls/wineios.drv/wineios.so" "$GRAPE/build/wine-ios/dlls/wineios.drv/"
cp "$NATIVE/dlls/winevulkan/winevulkan.so" "$GRAPE/build/wine-ios/dlls/winevulkan/"
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
cp "$NATIVE/dlls/winevulkan/winevulkan.so" "$GRAPE/runtime/lib/wine/aarch64-windows/winevulkan.so"
cp "$NATIVE/dlls/ws2_32/ws2_32.so" "$GRAPE/runtime/lib/wine/aarch64-windows/ws2_32.so"
cp "$NATIVE/dlls/crypt32/crypt32.so" "$GRAPE/runtime/lib/wine/aarch64-windows/crypt32.so"
cp "$NATIVE/dlls/secur32/secur32.so" "$GRAPE/runtime/lib/wine/aarch64-windows/secur32.so"
if test "$dwrite_unixlib" = 1; then
  cp "$NATIVE/dlls/dwrite/dwrite.so" "$GRAPE/runtime/lib/wine/aarch64-windows/dwrite.so"
fi
cp "$NATIVE/dlls/mountmgr.sys/mountmgr.so" "$GRAPE/runtime/lib/wine/aarch64-windows/mountmgr.so"
cp "$NATIVE/dlls/opengl32/opengl32.so" "$GRAPE/runtime/lib/wine/aarch64-windows/opengl32.so"
cp "$NATIVE/dlls/win32u/win32u.so" "$GRAPE/runtime/lib/wine/aarch64-windows/win32u.so"

# Modern Wine resolves a PE module's Unix side in the architecture-specific
# sibling directory (aarch64-windows/../aarch64-unix). Keep the historical
# aarch64-windows mirrors above for older Juice loaders, but always provide the
# canonical layout used by current ntdll. This is required by networking and
# by any other DLL that calls __wine_init_unix_lib.
UNIX_RUNTIME="$GRAPE/runtime/lib/wine/aarch64-unix"
cp "$NATIVE/dlls/ntdll/ntdll.so" "$UNIX_RUNTIME/ntdll.so"
cp "$NATIVE/dlls/crypt32/crypt32.so" "$UNIX_RUNTIME/crypt32.so"
cp "$NATIVE/dlls/secur32/secur32.so" "$UNIX_RUNTIME/secur32.so"
cp "$NATIVE/dlls/mountmgr.sys/mountmgr.so" "$UNIX_RUNTIME/mountmgr.so"
cp "$NATIVE/dlls/opengl32/opengl32.so" "$UNIX_RUNTIME/opengl32.so"
cp "$NATIVE/dlls/win32u/win32u.so" "$UNIX_RUNTIME/win32u.so"
cp "$NATIVE/dlls/wineios.drv/wineios.so" "$UNIX_RUNTIME/wineios.so"
cp "$NATIVE/dlls/winevulkan/winevulkan.so" "$UNIX_RUNTIME/winevulkan.so"
cp "$NATIVE/dlls/ws2_32/ws2_32.so" "$UNIX_RUNTIME/ws2_32.so"
if test "$dwrite_unixlib" = 1; then
  cp "$NATIVE/dlls/dwrite/dwrite.so" "$UNIX_RUNTIME/dwrite.so"
fi
echo "JUICE_UNIXLIB_LAYOUT_READY path=$UNIX_RUNTIME modules=$(find "$UNIX_RUNTIME" -maxdepth 1 -type f | wc -l | tr -d ' ')"

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

WINEVULKAN_JSON="$PEBUILD/dlls/winevulkan/winevulkan.json"
if test ! -s "$WINEVULKAN_JSON"; then
  # winevulkan.json is compiled into winevulkan.dll as a resource, so the PE
  # build does not always leave a loose copy in its object directory.
  WINEVULKAN_JSON="$ROOT/wine/dlls/winevulkan/winevulkan.json"
fi
test -s "$WINEVULKAN_JSON" || {
  echo "Missing Wine Vulkan ICD manifest: $WINEVULKAN_JSON" >&2
  exit 3
}
cp "$WINEVULKAN_JSON" \
  "$GRAPE/runtime/lib/wine/aarch64-windows/winevulkan.json"

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
if test -s "$NETWORK_SMOKES/network-smoke-arm64.exe"; then
  cp "$NETWORK_SMOKES/network-smoke-arm64.exe" "$GRAPE/tests/"
  echo "JUICE_NETWORK_SMOKE_STAGED arch=arm64 path=$GRAPE/tests/network-smoke-arm64.exe"
fi

(
  cd "$STAGE"
  LC_ALL=C find Grape -type f -print0 | sort -z | xargs -0 sha256sum > RUNTIME-MANIFEST.sha256
)
module_count="$(find "$GRAPE/runtime/lib/wine/aarch64-windows" -type f | wc -l | tr -d ' ')"
echo "JUICE_RUNTIME_ASSEMBLED path=$GRAPE modules=$module_count dwrite_unixlib=$dwrite_unixlib lowva_helper=$GRAPE/tools/juice-lowva-helper"
