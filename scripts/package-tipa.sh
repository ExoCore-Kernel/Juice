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
       echo "Refusing output outside dist: $OUTPUT" >&2; exit 2;
     };;
esac

"${BASH:-bash}" "$ROOT/scripts/build-app.sh"
rm -rf "$PACKAGE"
mkdir -p "$APP" "$(dirname "$OUTPUT")"
rm -f "$OUTPUT" "$OUTPUT.sha256"
cp "$ROOT/build/app/Juice.app/Juice" "$ROOT/config/Info.plist" "$APP/"
rsync -a "$RUNTIME/" "$APP/Grape/"
runtime_roots=("$APP/Grape")
if test -n "$X64_RUNTIME"; then
  rsync -a "$X64_RUNTIME/" "$APP/Grape-X64/"
  runtime_roots+=("$APP/Grape-X64")
fi

if test -x /var/jb/usr/bin/ldid; then
  while IFS= read -r -d '' candidate; do
    if file "$candidate" | grep -q 'Mach-O'; then
      /var/jb/usr/bin/ldid -S"$ROOT/config/child-entitlements.plist" -Cadhoc "$candidate"
    fi
  done < <(find "${runtime_roots[@]}" -type f -print0)
  if test -n "$X64_RUNTIME"; then
    /var/jb/usr/bin/ldid -S"$ROOT/config/cli-allow-jit-entitlements.plist" -Cadhoc \
      "$APP/Grape-X64/build/wine-ios/loader/wine"
  fi
  /var/jb/usr/bin/ldid -S"$ROOT/config/app-entitlements.plist" -Cadhoc "$APP/Juice"
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
echo "JUICE_TIPA_OK path=$OUTPUT"
