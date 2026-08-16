#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/graphics-build.env"

DEPS="${JUICE_GRAPHICS_DEPS:-$ROOT/build/deps}"
DEST="$DEPS/moltenvk-$JUICE_MOLTENVK_VERSION"
ARCHIVE="$DEST/$JUICE_MOLTENVK_ARCHIVE"
FRAMEWORK="$DEST/MoltenVK/MoltenVK/dynamic/MoltenVK.xcframework/ios-arm64/MoltenVK.framework"

case "$DEST" in
  "$ROOT"/build/deps/*) ;;
  *) test "${JUICE_ALLOW_EXTERNAL_BUILD:-0}" = 1 || {
       echo "Unsafe MoltenVK dependency path: $DEST" >&2
       exit 2
     } ;;
esac

mkdir -p "$DEST"
if test -f "$ARCHIVE" && ! printf '%s  %s\n' "$JUICE_MOLTENVK_SHA256" "$ARCHIVE" | sha256sum -c - >/dev/null 2>&1; then
  echo "Cached MoltenVK archive failed its pinned checksum: $ARCHIVE" >&2
  exit 3
fi
if test ! -f "$ARCHIVE"; then
  command -v curl >/dev/null 2>&1 || { echo "curl is required to fetch MoltenVK." >&2; exit 2; }
  curl -fL --retry 3 --output "$ARCHIVE" "$JUICE_MOLTENVK_URL"
fi
printf '%s  %s\n' "$JUICE_MOLTENVK_SHA256" "$ARCHIVE" | sha256sum -c - >/dev/null

if test ! -s "$FRAMEWORK/MoltenVK"; then
  tar -xf "$ARCHIVE" -C "$DEST"
fi
test -s "$FRAMEWORK/MoltenVK" || {
  echo "MoltenVK iOS dynamic framework is missing after extraction: $FRAMEWORK" >&2
  exit 3
}
file "$FRAMEWORK/MoltenVK" | grep -q 'Mach-O 64-bit arm64' || {
  echo "MoltenVK framework does not contain an arm64 iOS Mach-O: $FRAMEWORK/MoltenVK" >&2
  exit 3
}

printf '%s\n' "$FRAMEWORK" > "$DEST/framework.path"
echo "JUICE_MOLTENVK_READY version=$JUICE_MOLTENVK_VERSION framework=$FRAMEWORK sha256=$JUICE_MOLTENVK_SHA256"
