#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
JBROOT="${JBROOT:-/var/jb}"
CC="${CC:-$JBROOT/usr/bin/clang}"
LDID="${LDID:-$JBROOT/usr/bin/ldid}"
ZIP="${ZIP:-$JBROOT/usr/bin/zip}"
SUDO="${SUDO:-$JBROOT/usr/bin/sudo}"
SDK="${IOS_SDK:-$JBROOT/usr/share/SDKs/iPhoneOS.sdk}"
CARRIER="${JUICE_TRUST_CARRIER:-$ROOT/build/trust-carrier}"
APP="$CARRIER/Payload/JuiceTrust.app"
IPA="$CARRIER/JuiceTrust-bootstrap.ipa"

test -x "$CC" || { echo "Missing iOS clang: $CC" >&2; exit 2; }
test -x "$LDID" || { echo "Missing ldid: $LDID" >&2; exit 2; }
test -d "$SDK" || { echo "Missing iPhoneOS SDK: $SDK" >&2; exit 2; }

HELPER="$(find /var/containers/Bundle/Application -type f \
  -path '*/TrollStore.app/trollstorehelper' -print -quit 2>/dev/null)"
test -x "$HELPER" || { echo "TrollStore helper was not found." >&2; exit 3; }

case "$CARRIER" in
  "$ROOT"/build/*) ;;
  *) test "${JUICE_ALLOW_EXTERNAL_BUILD:-0}" = 1 || {
       echo "Unsafe trust carrier path: $CARRIER" >&2; exit 2;
     };;
esac
rm -rf "$CARRIER"
mkdir -p "$APP/Tools"
cp "$ROOT/config/TrustCarrier-Info.plist" "$APP/Info.plist"
"$CC" -target arm64-apple-ios14.0 -arch arm64 -isysroot "$SDK" \
  -miphoneos-version-min=14.0 -O2 "$ROOT/launcher/trust-carrier.c" \
  -o "$APP/JuiceTrust"
cp "$APP/JuiceTrust" "$APP/Tools/ct-sign-target"
"$LDID" -S"$ROOT/config/app-entitlements.plist" -Cadhoc "$APP/JuiceTrust"
"$LDID" -S"$ROOT/config/child-entitlements.plist" -Cadhoc "$APP/Tools/ct-sign-target"

(cd "$CARRIER" && "$ZIP" -qry "$IPA" Payload)
"$SUDO" "$HELPER" install force "$IPA"
echo "JUICE_TRUST_CARRIER_READY path=$CARRIER"
