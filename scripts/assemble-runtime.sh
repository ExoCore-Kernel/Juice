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
  "$GRAPE/build/wine-ios/dlls/ntdll" "$GRAPE/build/wine-ios/dlls/win32u" \
  "$GRAPE/build/wine-ios/dlls/wineios.drv" "$GRAPE/build/wine-ios/dlls/ws2_32" \
  "$GRAPE/build/wine-ios/nls" "$GRAPE/runtime/lib/wine/aarch64-windows" \
  "$GRAPE/tools"

cp "$NATIVE/server/wineserver" "$GRAPE/build/wine-ios/server/"
cp "$NATIVE/loader/wine" "$GRAPE/build/wine-ios/loader/"
cp "$NATIVE/dlls/ntdll/ntdll.so" "$GRAPE/build/wine-ios/dlls/ntdll/"
cp "$NATIVE/dlls/win32u/win32u.so" "$GRAPE/build/wine-ios/dlls/win32u/"
cp "$NATIVE/dlls/wineios.drv/wineios.so" "$GRAPE/build/wine-ios/dlls/wineios.drv/"
cp "$NATIVE/dlls/ws2_32/ws2_32.so" "$GRAPE/build/wine-ios/dlls/ws2_32/"

# Wine may resolve the Unix driver beside either the build tree or PE module.
cp "$NATIVE/dlls/wineios.drv/wineios.so" "$GRAPE/runtime/lib/wine/aarch64-windows/wineios.so"

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
"${BASH:-bash}" "$ROOT/scripts/build-launchers.sh"
cp "$ROOT/build/launchers/grape-trace-parent" "$ROOT/build/launchers/grape-nested-wrapper" "$GRAPE/tools/"
chmod 755 "$GRAPE/build/wine-ios/server/wineserver" "$GRAPE/build/wine-ios/loader/wine" "$GRAPE/tools/"*

(
  cd "$STAGE"
  LC_ALL=C find Grape -type f -print0 | sort -z | xargs -0 sha256sum > RUNTIME-MANIFEST.sha256
)
module_count="$(find "$GRAPE/runtime/lib/wine/aarch64-windows" -type f | wc -l | tr -d ' ')"
echo "JUICE_RUNTIME_ASSEMBLED path=$GRAPE modules=$module_count"
