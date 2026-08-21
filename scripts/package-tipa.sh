#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/graphics-build.env"
source "$ROOT/config/network-build.env"
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
MOLTENVK_ROOT="${JUICE_GRAPHICS_DEPS:-$ROOT/build/deps}/moltenvk-$JUICE_MOLTENVK_VERSION"
MOLTENVK_FRAMEWORK="${JUICE_MOLTENVK_FRAMEWORK:-$MOLTENVK_ROOT/MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework/ios-arm64/MoltenVK.framework}"
OUTPUT="${1:-$ROOT/dist/Juice-$(date +%Y%m%d-%H%M%S).tipa}"
APP_ENTITLEMENTS="${JUICE_APP_ENTITLEMENTS:-$ROOT/config/app-entitlements.plist}"
CHILD_ENTITLEMENTS="${JUICE_CHILD_ENTITLEMENTS:-$ROOT/config/child-entitlements.plist}"
X64_LOADER_ENTITLEMENTS="${JUICE_X64_LOADER_ENTITLEMENTS:-$ROOT/config/cli-allow-jit-entitlements.plist}"
LOWVA_ENTITLEMENTS="${JUICE_LOWVA_ENTITLEMENTS:-$ROOT/config/lowva-helper-entitlements.plist}"

test -d "$RUNTIME" || { echo "Run assemble-runtime.sh first." >&2; exit 2; }
for entitlements in "$APP_ENTITLEMENTS" "$CHILD_ENTITLEMENTS" "$X64_LOADER_ENTITLEMENTS" "$LOWVA_ENTITLEMENTS"; do
  test -f "$entitlements" || { echo "Missing package entitlements: $entitlements" >&2; exit 2; }
done
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
if test ! -s "$MOLTENVK_FRAMEWORK/MoltenVK"; then
  bash "$ROOT/scripts/fetch-moltenvk-linux.sh"
fi
test -s "$MOLTENVK_FRAMEWORK/MoltenVK" || {
  echo "Missing pinned MoltenVK iOS framework: $MOLTENVK_FRAMEWORK" >&2
  exit 3
}
mkdir -p "$APP/Frameworks"
cp -a "$MOLTENVK_FRAMEWORK" "$APP/Frameworks/"
rsync -a "$RUNTIME/" "$APP/Grape/"
runtime_roots=("$APP/Grape" "$APP/Frameworks")
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

# Bundle the target dylib closure used by Wine's runtime dlopen paths. The
# helper rewrites all intra-bundle references to @loader_path and converts
# Procursus symlinks to signed regular files so TIPA extraction is reliable.
if test "${JUICE_WITHOUT_GNUTLS:-0}" != 1 || \
   { test "${JUICE_WITHOUT_FREETYPE:-0}" != 1 && test "${JUICE_STATIC_FREETYPE:-1}" = 0; }; then
  mkdir -p "$APP/Libraries"
  JUICE_IOS_ROOTLESS_SYSROOT="$ROOTLESS" \
    bash "$ROOT/scripts/bundle-ios-libraries.sh" "$APP/Libraries"
  runtime_roots+=("$APP/Libraries")
  bundled_library_count="$(find "$APP/Libraries" -maxdepth 1 -type f | wc -l | tr -d ' ')"
  echo "JUICE_RUNTIME_LIBRARIES_READY path=$APP/Libraries libraries=$bundled_library_count gnutls=$([ "${JUICE_WITHOUT_GNUTLS:-0}" = 1 ] && echo 0 || echo 1)"
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
      "$LDID_BIN" -S"$CHILD_ENTITLEMENTS" -Cadhoc "$candidate"
    fi
  done < <(find "${runtime_roots[@]}" -type f -print0)
  if test -n "$X64_RUNTIME"; then
    "$LDID_BIN" -S"$X64_LOADER_ENTITLEMENTS" -Cadhoc \
      "$APP/Grape-X64/build/wine-ios/loader/wine"
  fi
  for runtime_root in "${runtime_roots[@]}"; do
    lowva_helper="$runtime_root/tools/juice-lowva-helper"
    if test -f "$lowva_helper" && file "$lowva_helper" | grep -q 'Mach-O'; then
      "$LDID_BIN" -S"$LOWVA_ENTITLEMENTS" -Cadhoc "$lowva_helper"
      helper_entitlements="$($LDID_BIN -e "$lowva_helper" 2>/dev/null || true)"
      if grep -q 'IOSurfaceRootUserClient' "$LOWVA_ENTITLEMENTS"; then
        printf '%s' "$helper_entitlements" | grep -q 'IOSurfaceRootUserClient' || {
          echo "Packaged low-VA helper is missing IOSurfaceRootUserClient: $lowva_helper" >&2
          exit 3
        }
        echo "JUICE_LOWVA_HELPER_SIGNED path=$lowva_helper iosurface_entitlement=1"
      else
        echo "JUICE_LOWVA_HELPER_SIGNED path=$lowva_helper iosurface_entitlement=0"
      fi
    fi
  done
  "$LDID_BIN" -S"$APP_ENTITLEMENTS" -Cadhoc "$APP/Juice"
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
