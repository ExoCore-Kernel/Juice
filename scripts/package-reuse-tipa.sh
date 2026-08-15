#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
JBROOT="${JBROOT:-/var/jb}"
export PATH="$JBROOT/usr/bin:$JBROOT/usr/sbin:/usr/bin:/bin:$PATH"

BINARIES="${JUICE_PREBUILT_DIR:-${BINARIES:-}}"
X64_MODE="${JUICE_REUSE_X64:-auto}"
PACKAGE="$ROOT/build/reuse-package"
APP="$PACKAGE/Payload/Juice.app"
OUTPUT="${1:-$ROOT/dist/Juice-Reuse-$(date +%Y%m%d-%H%M%S).tipa}"
KEEP_STAGE="${JUICE_KEEP_REUSE_STAGE:-0}"
ALLOW_COPY="${JUICE_REUSE_ALLOW_COPY:-0}"

usage()
{
  cat >&2 <<'EOF'
Usage:
  BINARIES=/path/to/prebuilt make reuse
  BINARIES=/path/to/prebuilt make reuse-install

The directory may be a previous Juice build tree, a Payload/Juice.app tree,
an installed Juice.app, or a parent directory containing Grape / Grape-X64.

Optional:
  REUSE_X64=auto   include Grape-X64 when found (default)
  REUSE_X64=0      package native Grape only
  REUSE_X64=1      require and include Grape-X64

The low-space packager hard-links the large runtime files into its temporary
stage and detaches only Mach-O files before signing them. This avoids making a
second full copy of the runtime on the same filesystem.
EOF
}

test -n "$BINARIES" || { usage; exit 2; }
test -d "$BINARIES" || { echo "Prebuilt binary directory not found: $BINARIES" >&2; exit 2; }
BINARIES="$(CDPATH= cd -- "$BINARIES" && pwd)"

case "$OUTPUT" in
  "$ROOT"/dist/*.tipa) ;;
  *) test "${JUICE_ALLOW_EXTERNAL_OUTPUT:-0}" = 1 || {
       echo "Refusing output outside dist: $OUTPUT" >&2
       exit 2
     };;
esac

valid_runtime()
{
  local path="$1"
  test -d "$path" &&
  test -f "$path/build/wine-ios/loader/wine" &&
  test -d "$path/runtime/lib/wine/aarch64-windows"
}

find_runtime()
{
  local name="$1" candidate

  # Accept the runtime directory itself, then common package/build layouts,
  # then fall back to a recursive search beneath the user-supplied directory.
  if test "$(basename "$BINARIES")" = "$name" && valid_runtime "$BINARIES"; then
    printf '%s\n' "$BINARIES"
    return 0
  fi

  for candidate in \
    "$BINARIES/$name" \
    "$BINARIES/Payload/Juice.app/$name" \
    "$BINARIES/Juice.app/$name" \
    "$BINARIES/build/runtime-stage/$name" \
    "$BINARIES/build/x86_64-runtime-stage/$name" \
    "$BINARIES/build/x86_64-runtime-stage-final/$name"
  do
    if valid_runtime "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  while IFS= read -r candidate; do
    if valid_runtime "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(find "$BINARIES" -type d -name "$name" -print 2>/dev/null)

  return 1
}

RUNTIME="$(find_runtime Grape || true)"
X64_RUNTIME="$(find_runtime Grape-X64 || true)"

test -n "$RUNTIME" || {
  echo "Could not find a usable Grape runtime beneath: $BINARIES" >&2
  echo "Expected build/wine-ios/loader/wine and runtime/lib/wine/aarch64-windows." >&2
  exit 3
}

case "$X64_MODE" in
  auto) ;;
  0|no|false|off) X64_RUNTIME="" ;;
  1|yes|true|on)
    test -n "$X64_RUNTIME" || {
      echo "REUSE_X64=1 was requested but no usable Grape-X64 was found." >&2
      exit 3
    };;
  *) echo "Invalid REUSE_X64 value: $X64_MODE (use auto, 0, or 1)" >&2; exit 2;;
esac

WIN32=0
if test -n "$X64_RUNTIME" &&
   test -f "$X64_RUNTIME/runtime/lib/wine/aarch64-windows/libwow64fex.dll" &&
   test -f "$X64_RUNTIME/runtime/lib/wine/i386-windows/ntdll.dll"; then
  WIN32=1
fi

echo "JUICE_REUSE_DISCOVERY native=$RUNTIME"
if test -n "$X64_RUNTIME"; then
  echo "JUICE_REUSE_DISCOVERY x64=$X64_RUNTIME win32=$WIN32"
else
  echo "JUICE_REUSE_DISCOVERY x64=disabled win32=0"
fi

cleanup()
{
  if test "$KEEP_STAGE" != 1; then
    case "$PACKAGE" in "$ROOT"/build/reuse-package) rm -rf "$PACKAGE";; esac
  fi
}
trap cleanup EXIT INT TERM

rm -rf "$PACKAGE"
mkdir -p "$APP" "$(dirname "$OUTPUT")"
rm -f "$OUTPUT" "$OUTPUT.sha256"

# A hardlink probe is deliberate: rsync --link-dest silently falls back to a
# full copy if the source is on another filesystem. Refuse that surprise unless
# the caller explicitly opts into the old high-space behaviour.
LINK_SAMPLE="$RUNTIME/build/wine-ios/loader/wine"
if ln "$LINK_SAMPLE" "$PACKAGE/.juice-hardlink-test" 2>/dev/null; then
  rm -f "$PACKAGE/.juice-hardlink-test"
  LINK_MODE=1
else
  LINK_MODE=0
  if test "$ALLOW_COPY" != 1; then
    echo "The prebuilt runtime is not on the same hardlink-capable filesystem as this checkout." >&2
    echo "Refusing to make a full runtime copy. Move/clone the repo onto the same iPad data volume," >&2
    echo "or set JUICE_REUSE_ALLOW_COPY=1 if you intentionally want the high-space fallback." >&2
    exit 4
  fi
  echo "WARNING: hardlinks unavailable; falling back to full runtime copies." >&2
fi

"${BASH:-bash}" "$ROOT/scripts/build-app.sh"
cp "$ROOT/build/app/Juice.app/Juice" "$ROOT/config/Info.plist" "$APP/"
shopt -s nullglob
app_icons=("$ROOT/build/app/Juice.app"/AppIcon*.png)
shopt -u nullglob
test "${#app_icons[@]}" -gt 0 || { echo "Built Juice.app has no app icons." >&2; exit 3; }
cp "${app_icons[@]}" "$APP/"

stage_runtime()
{
  local source="$1" destination="$2"
  mkdir -p "$destination"
  if test "$LINK_MODE" = 1; then
    rsync -a --link-dest="$source" "$source/" "$destination/"
  else
    rsync -a "$source/" "$destination/"
  fi
}

stage_runtime "$RUNTIME" "$APP/Grape"
runtime_roots=("$APP/Grape")
if test -n "$X64_RUNTIME"; then
  stage_runtime "$X64_RUNTIME" "$APP/Grape-X64"
  runtime_roots+=("$APP/Grape-X64")
fi

# Never sign a hardlinked file in place: that would mutate the prebuilt source.
# Detach only the Mach-O being signed, so PE DLLs/resources remain shared.
detach_for_signing()
{
  local candidate="$1" temporary="$1.juice-sign-detach.$$"
  cp -p "$candidate" "$temporary"
  mv -f "$temporary" "$candidate"
}

if test -x /var/jb/usr/bin/ldid; then
  while IFS= read -r -d '' candidate; do
    if file "$candidate" | grep -q 'Mach-O'; then
      if test "$LINK_MODE" = 1; then detach_for_signing "$candidate"; fi
      /var/jb/usr/bin/ldid -S"$ROOT/config/child-entitlements.plist" -Cadhoc "$candidate"
    fi
  done < <(find "${runtime_roots[@]}" -type f -print0)

  if test -n "$X64_RUNTIME"; then
    /var/jb/usr/bin/ldid -S"$ROOT/config/cli-allow-jit-entitlements.plist" -Cadhoc \
      "$APP/Grape-X64/build/wine-ios/loader/wine"
  fi

  for runtime_root in "${runtime_roots[@]}"; do
    lowva_helper="$runtime_root/tools/juice-lowva-helper"
    if test -f "$lowva_helper" && file "$lowva_helper" | grep -q 'Mach-O'; then
      /var/jb/usr/bin/ldid -S"$ROOT/config/lowva-helper-entitlements.plist" -Cadhoc "$lowva_helper"
      helper_entitlements="$(/var/jb/usr/bin/ldid -e "$lowva_helper" 2>/dev/null || true)"
      printf '%s' "$helper_entitlements" | grep -q 'IOSurfaceRootUserClient' || {
        echo "Packaged low-VA helper is missing IOSurfaceRootUserClient: $lowva_helper" >&2
        exit 5
      }
      echo "JUICE_LOWVA_HELPER_SIGNED path=$lowva_helper iosurface_entitlement=1"
    fi
  done

  /var/jb/usr/bin/ldid -S"$ROOT/config/app-entitlements.plist" -Cadhoc "$APP/Juice"
fi

forbidden="$(find "$APP" \( -type d -name .git -o \
  -type f \( -name '*.c' -o -name '*.m' \) \) -print)"
if test -n "$forbidden"; then
  echo "Refusing to package source or Git metadata: $forbidden" >&2
  exit 5
fi

(
  cd "$PACKAGE"
  zip -qry "$OUTPUT" Payload
)
sha256sum "$OUTPUT" > "$OUTPUT.sha256"

echo "JUICE_REUSE_TIPA_OK path=$OUTPUT native=1 x64=$([ -n "$X64_RUNTIME" ] && echo 1 || echo 0) win32=$WIN32 link_mode=$LINK_MODE icons=${#app_icons[@]}"
