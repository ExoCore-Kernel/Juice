#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TARGET="${1:?usage: coretrust-sign-device.sh MACH_O [ENTITLEMENTS]}"
ENTITLEMENTS="${2:-$ROOT/config/child-entitlements.plist}"
CARRIER="${JUICE_TRUST_CARRIER:-$ROOT/build/trust-carrier}"
CARRIER_APP="$CARRIER/Payload/JuiceTrust.app"
CARRIER_TARGET="$CARRIER_APP/Tools/ct-sign-target"
IPA="$CARRIER/JuiceAutoSign.ipa"
LOG="$CARRIER/autosign.log"
LOCK="$CARRIER/.autosign.lock"
LDID="${LDID:-/var/jb/usr/bin/ldid}"
ZIP="${ZIP:-/var/jb/usr/bin/zip}"
SUDO="${SUDO:-/var/jb/usr/bin/sudo}"

test -f "$TARGET" || { echo "Mach-O target not found: $TARGET" >&2; exit 2; }
test -f "$ENTITLEMENTS" || { echo "Entitlements not found: $ENTITLEMENTS" >&2; exit 2; }
test -d "$CARRIER_APP" || { echo "Run scripts/bootstrap-trust-carrier-device.sh first." >&2; exit 2; }
file "$TARGET" | grep -q 'Mach-O' || { echo "Not a Mach-O target: $TARGET" >&2; exit 2; }

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

mkdir -p "$CARRIER_APP/Tools"
cp -f "$TARGET" "$CARRIER_TARGET"
chmod 755 "$CARRIER_TARGET"
"$LDID" -S"$ENTITLEMENTS" -Cadhoc "$CARRIER_TARGET"

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
PATCHED="$INSTALLED_APP/Tools/ct-sign-target"
test -f "$PATCHED" || { echo "CoreTrust carrier did not return a target." >&2; exit 5; }
cp -f "$PATCHED" "$TARGET"
chmod 755 "$TARGET"

echo "JUICE_CORETRUST_SIGN_OK target=$TARGET entitlements=$ENTITLEMENTS"
