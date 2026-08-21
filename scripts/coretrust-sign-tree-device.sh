#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TARGET_DIR="${1:?usage: coretrust-sign-tree-device.sh DIRECTORY [ENTITLEMENTS]}"
ENTITLEMENTS="${2:-$ROOT/config/child-entitlements.plist}"
CARRIER="${JUICE_TRUST_CARRIER:-$ROOT/build/trust-carrier}"
CARRIER_APP="$CARRIER/Payload/JuiceTrust.app"
CARRIER_TREE="$CARRIER_APP/Tools/ct-sign-tree"
IPA="$CARRIER/JuiceAutoSign-tree.ipa"
LOG="$CARRIER/autosign-tree.log"
LOCK="$CARRIER/.autosign.lock"
LDID="${LDID:-/var/jb/usr/bin/ldid}"
ZIP="${ZIP:-/var/jb/usr/bin/zip}"
SUDO="${SUDO:-/var/jb/usr/bin/sudo}"

test -d "$TARGET_DIR" || { echo "Target directory not found: $TARGET_DIR" >&2; exit 2; }
test -f "$ENTITLEMENTS" || { echo "Entitlements not found: $ENTITLEMENTS" >&2; exit 2; }
test -d "$CARRIER_APP" || { echo "Run scripts/bootstrap-trust-carrier-device.sh first." >&2; exit 2; }
TARGET_DIR="$(CDPATH= cd -- "$TARGET_DIR" && pwd)"

attempt=0
until mkdir "$LOCK" 2>/dev/null; do
    attempt=$((attempt + 1))
    test "$attempt" -lt 3000 || { echo "Timed out waiting for $LOCK" >&2; exit 3; }
    sleep 0.1
done
release_lock()
{
    rmdir "$LOCK" 2>/dev/null || true
}
trap release_lock EXIT

case "$CARRIER_TREE" in
  "$ROOT"/build/*) ;;
  *) test "${JUICE_ALLOW_EXTERNAL_BUILD:-0}" = 1 || {
       echo "Unsafe trust carrier tree: $CARRIER_TREE" >&2; exit 2;
     };;
esac
rm -rf "$CARRIER_TREE"
mkdir -p "$CARRIER_TREE"

targets=()
relative_paths=()
while IFS= read -r -d '' target; do
    file "$target" | grep -q 'Mach-O' || continue
    relative="${target#"$TARGET_DIR"/}"
    case "$relative" in
      /*|../*|*/../*) echo "Unsafe relative path: $relative" >&2; exit 2;;
    esac
    carrier_target="$CARRIER_TREE/$relative"
    mkdir -p "$(dirname -- "$carrier_target")"
    cp -f "$target" "$carrier_target"
    chmod 755 "$carrier_target"
    "$LDID" -S"$ENTITLEMENTS" -Cadhoc "$carrier_target"
    targets+=("$target")
    relative_paths+=("$relative")
done < <(find "$TARGET_DIR" -type f -print0)

test "${#targets[@]}" -gt 0 || {
    echo "No Mach-O files found beneath $TARGET_DIR" >&2
    exit 2
}

(
    cd "$CARRIER"
    rm -f "$IPA"
    "$ZIP" -qry "$IPA" Payload
)

TROLLSTORE_HELPER="$(find /var/containers/Bundle/Application -type f \
    -path '*/TrollStore.app/trollstorehelper' -print -quit 2>/dev/null)"
test -x "$TROLLSTORE_HELPER" || { echo "TrollStore helper was not found." >&2; exit 4; }
"$SUDO" "$TROLLSTORE_HELPER" install force "$IPA" >"$LOG" 2>&1

INSTALLED_APP="$(find /var/containers/Bundle/Application -type d \
    -name JuiceTrust.app -print -quit 2>/dev/null)"
test -d "$INSTALLED_APP/Tools/ct-sign-tree" || {
    echo "CoreTrust carrier did not return the signed tree." >&2
    exit 5
}

for index in "${!targets[@]}"; do
    patched="$INSTALLED_APP/Tools/ct-sign-tree/${relative_paths[$index]}"
    test -f "$patched" || { echo "Missing patched target: $patched" >&2; exit 5; }
    cp -f "$patched" "${targets[$index]}"
    chmod 755 "${targets[$index]}"
done

echo "JUICE_CORETRUST_SIGN_TREE_OK directory=$TARGET_DIR files=${#targets[@]} entitlements=$ENTITLEMENTS"
