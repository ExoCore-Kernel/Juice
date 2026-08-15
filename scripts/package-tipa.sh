#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
JBROOT="${JBROOT:-/var/jb}"
export PATH="$JBROOT/usr/bin:$JBROOT/usr/sbin:/usr/bin:/bin:$PATH"
RUNTIME="${JUICE_RUNTIME_STAGE:-$ROOT/build/runtime-stage}/Grape"
X64_RUNTIME=""
if test -n "${JUICE_X64_RUNTIME_STAGE:-}"; then
  X64_RUNTIME="$JUICE_X64_RUNTIME_STAGE/Grape-X64"
fi
ROOTLESS="${JUICE_IOS_ROOTLESS_SYSROOT:-$ROOT/build/deps/rootless-sysroot}"
PACKAGE="$ROOT/build/package"
APP="$PACKAGE/Payload/Juice.app"
OUTPUT="${1:-$ROOT/dist/Juice-$(date +%Y%m%d-%H%M%S).tipa}"

test -d "$RUNTIME" || { echo "Run assemble-runtime.sh first." >&2; exit 2; }
if test -n "$X64_RUNTIME"; then
  test -d "$X64_RUNTIME" || { echo "Experimental runtime not found: $X64_RUNTIME" >&2; exit 2; }
fi
case "$OUTPUT" in
  "$ROOT"/dist/*.tipa) ;;
  *) test "${JUICE_ALLOW_EXTERNAL_OUTPUT:-0}" = 1 || {
       echo "Refusing output outside dist: $OUTPUT" >&2; exit 2
     };;
esac

"${BASH:-bash}" "$ROOT/scripts/build-app.sh"
rm -rf "$PACKAGE"
mkdir -p "$APP" "$(dirname "$OUTPUT")"
rm -f "$OUTPUT" "$OUTPUT.sha256"
cp "$ROOT/build/app/Juice.app/Juice" "$ROOT/config/Info.plist" "$APP/"
shopt -s nullglob
app_icons=("$ROOT/build/app/Juice.app"/AppIcon*.png)
shopt -u nullglob
test "${#app_icons[@]}" -gt 0 || { echo "Built Juice.app has no app icons." >&2; exit 3; }
cp "${app_icons[@]}" "$APP/"
rsync -a "$RUNTIME/" "$APP/Grape/"
runtime_roots=("$APP/Grape")
if test -n "$X64_RUNTIME"; then
  rsync -a "$X64_RUNTIME/" "$APP/Grape-X64/"
  runtime_roots+=("$APP/Grape-X64")

  # Grape-X64 starts from the verified ARM64 Grape runtime and must keep the
  # exact same normal iOS Mach-O loader. Do not rewrite __PAGEZERO in the file:
  # iOS rejects a non-standard pagezero executable before main() with ENOEXEC.
  # The loader now releases the low VA reservation from the live task after
  # launch when JUICE_EXPERIMENTAL_X64=1, preserving a valid signed image.
  x64_loader="$APP/Grape-X64/build/wine-ios/loader/wine"
  arm64_loader="$APP/Grape/build/wine-ios/loader/wine"
  test -f "$x64_loader" || { echo "Missing Grape-X64 Wine loader: $x64_loader" >&2; exit 3; }
  test -f "$arm64_loader" || { echo "Missing ARM64 Wine loader: $arm64_loader" >&2; exit 3; }
  file "$x64_loader" | grep -Eq 'Mach-O 64-bit arm64' || {
    echo "Grape-X64 loader is not a valid arm64 Mach-O before signing." >&2
    file "$x64_loader" >&2 || true
    exit 3
  }
  cmp -s "$arm64_loader" "$x64_loader" || {
    echo "Grape-X64 loader diverged from the verified ARM64 loader before packaging." >&2
    exit 3
  }
  echo "JUICE_X64_LOADER_VALID path=$x64_loader strategy=runtime-low-va-release"
fi

# Wine deliberately loads FreeType at runtime with dlopen(SONAME_LIBFREETYPE).
# Procursus libfreetype6 itself depends on libbrotli1 and libpng16-16. Bundle
# that small runtime closure and rewrite only intra-bundle dylib references to
# @loader_path so rootless /var/jb install names do not leak into the TIPA.
if test "${JUICE_WITHOUT_FREETYPE:-0}" != 1; then
  test -e "$ROOTLESS/usr/lib/libfreetype.dylib" || {
    echo "Missing packaged FreeType input: $ROOTLESS/usr/lib/libfreetype.dylib" >&2
    exit 3
  }
  freetype_soname="$(JUICE_IOS_ROOTLESS_SYSROOT="$ROOTLESS" bash "$ROOT/scripts/detect-freetype-soname-linux.sh")"
  mkdir -p "$APP/Libraries"
  shopt -s nullglob
  freetype_libs=("$ROOTLESS/usr/lib"/libfreetype*.dylib)
  brotli_libs=("$ROOTLESS/usr/lib"/libbrotli*.dylib)
  png_libs=("$ROOTLESS/usr/lib"/libpng*.dylib)
  shopt -u nullglob
  test "${#freetype_libs[@]}" -gt 0 || {
    echo "No FreeType dylibs were found in $ROOTLESS/usr/lib." >&2
    exit 3
  }
  test "${#brotli_libs[@]}" -gt 0 || {
    echo "No Brotli dylibs were found in $ROOTLESS/usr/lib; refresh the FreeType dependency cache." >&2
    exit 3
  }
  test "${#png_libs[@]}" -gt 0 || {
    echo "No libpng dylibs were found in $ROOTLESS/usr/lib; refresh the FreeType dependency cache." >&2
    exit 3
  }
  cp -a "${freetype_libs[@]}" "${brotli_libs[@]}" "${png_libs[@]}" "$APP/Libraries/"
  test -e "$APP/Libraries/$freetype_soname" || {
    echo "Bundled FreeType is missing configured soname $freetype_soname." >&2
    exit 3
  }
  python3 "$ROOT/scripts/patch-bundled-dylib-paths.py" "$APP/Libraries"
  runtime_roots+=("$APP/Libraries")
  bundled_library_count="$(find "$APP/Libraries" -type f -name '*.dylib' | wc -l | tr -d ' ')"
  echo "JUICE_FREETYPE_BUNDLED soname=$freetype_soname path=$APP/Libraries/$freetype_soname libraries=$bundled_library_count closure=libfreetype6,libbrotli1,libpng16-16"
fi

LDID_BIN="${LDID:-}"
IOS_TOOLCHAIN="${JUICE_IOS_TOOLCHAIN:-$ROOT/build/ios-toolchain}"
if test -z "$LDID_BIN" && test -x /var/jb/usr/bin/ldid; then LDID_BIN=/var/jb/usr/bin/ldid; fi
if test -z "$LDID_BIN" && test -x "$IOS_TOOLCHAIN/bin/ldid"; then LDID_BIN="$IOS_TOOLCHAIN/bin/ldid"; fi
if test -z "$LDID_BIN"; then LDID_BIN="$(command -v ldid 2>/dev/null || true)"; fi
if test "${JUICE_REQUIRE_SIGNING:-0}" = 1 && { test -z "$LDID_BIN" || test ! -x "$LDID_BIN"; }; then
  echo "ldid is required for this package because Juice child/JIT entitlements must be embedded." >&2
  exit 3
fi
if test -n "$LDID_BIN" && test -x "$LDID_BIN"; then
  while IFS= read -r -d '' candidate; do
    if file "$candidate" | grep -q 'Mach-O'; then
      "$LDID_BIN" -S"$ROOT/config/child-entitlements.plist" -Cadhoc "$candidate"
    fi
  done < <(find "${runtime_roots[@]}" -type f -print0)
  if test -n "$X64_RUNTIME"; then
    "$LDID_BIN" -S"$ROOT/config/cli-allow-jit-entitlements.plist" -Cadhoc \
      "$APP/Grape-X64/build/wine-ios/loader/wine"
  fi
  for runtime_root in "${runtime_roots[@]}"; do
    lowva_helper="$runtime_root/tools/juice-lowva-helper"
    if test -f "$lowva_helper" && file "$lowva_helper" | grep -q 'Mach-O'; then
      "$LDID_BIN" -S"$ROOT/config/lowva-helper-entitlements.plist" -Cadhoc "$lowva_helper"
      helper_entitlements="$($LDID_BIN -e "$lowva_helper" 2>/dev/null || true)"
      printf '%s' "$helper_entitlements" | grep -q 'IOSurfaceRootUserClient' || {
        echo "Packaged low-VA helper is missing IOSurfaceRootUserClient: $lowva_helper" >&2
        exit 3
      }
      echo "JUICE_LOWVA_HELPER_SIGNED path=$lowva_helper iosurface_entitlement=1"
    fi
  done
  "$LDID_BIN" -S"$ROOT/config/app-entitlements.plist" -Cadhoc "$APP/Juice"
fi

forbidden="$(find "$APP" \( -type d -name .git -o \
  -type f \( -name '*.c' -o -name '*.m' \) \) -print)"
if test -n "$forbidden"; then
  echo "Refusing to package source or Git metadata: $forbidden" >&2
  exit 3
fi

(
  cd "$PACKAGE"
  zip -qry "$OUTPUT" Payload
)
sha256sum "$OUTPUT" > "$OUTPUT.sha256"
echo "JUICE_TIPA_OK path=$OUTPUT icons=${#app_icons[@]}"
