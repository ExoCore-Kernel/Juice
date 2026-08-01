#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
JBROOT="${JBROOT:-/var/jb}"
export PATH="$JBROOT/usr/bin:$JBROOT/usr/sbin:/usr/bin:/bin:$PATH"
RUNTIME="${JUICE_RUNTIME_STAGE:-$ROOT/build/runtime-stage}/Grape"
PACKAGE="$ROOT/build/package"
APP="$PACKAGE/Payload/Juice.app"
OUTPUT="${1:-$ROOT/dist/Juice-$(date +%Y%m%d-%H%M%S).tipa}"

test -d "$RUNTIME" || { echo "Run assemble-runtime.sh first." >&2; exit 2; }
case "$OUTPUT" in
  "$ROOT"/dist/*.tipa) ;;
  *) test "${JUICE_ALLOW_EXTERNAL_OUTPUT:-0}" = 1 || {
       echo "Unsafe TIPA output path: $OUTPUT" >&2
       exit 2
     };;
esac
"${BASH:-bash}" "$ROOT/scripts/build-app.sh"
case "$PACKAGE" in "$ROOT"/build/*) ;; *) echo "Unsafe package path." >&2; exit 2;; esac
rm -rf "$PACKAGE"
mkdir -p "$APP" "$(dirname "$OUTPUT")"
rm -f "$OUTPUT" "$OUTPUT.sha256"
cp "$ROOT/build/app/Juice.app/Juice" "$ROOT/config/Info.plist" "$APP/"
rsync -a "$RUNTIME/" "$APP/Grape/"

if test -x /var/jb/usr/bin/ldid; then
  while IFS= read -r -d '' candidate; do
    if file "$candidate" | grep -q 'Mach-O'; then
      /var/jb/usr/bin/ldid -S"$ROOT/config/child-entitlements.plist" -Cadhoc "$candidate"
    fi
  done < <(find "$APP/Grape" -type f -print0)
  /var/jb/usr/bin/ldid -S"$ROOT/config/app-entitlements.plist" -Cadhoc "$APP/Juice"
fi

forbidden="$(find "$APP/Grape" \( -type d -name .git -o \
  -type f \( -name '*.c' -o -name '*.m' \) \) -print)"
if test -n "$forbidden"; then
  echo "Refusing to package source or Git metadata: $forbidden" >&2
  exit 3
fi
(cd "$PACKAGE" && zip -qry "$OUTPUT" Payload)
unzip -tq "$OUTPUT"
if command -v sha256sum >/dev/null 2>&1; then
  digest="$(sha256sum "$OUTPUT" | awk '{print $1}')"
else
  digest="$(shasum -a 256 "$OUTPUT" | awk '{print $1}')"
fi
printf '%s  %s\n' "$digest" "$(basename "$OUTPUT")" > "$OUTPUT.sha256"
echo "JUICE_TIPA_OK path=$OUTPUT sha256=$digest"
