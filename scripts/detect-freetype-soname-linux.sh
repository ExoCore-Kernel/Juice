#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ROOTLESS="${JUICE_IOS_ROOTLESS_SYSROOT:-$ROOT/build/deps/rootless-sysroot}"
IOS_TOOLCHAIN="${JUICE_IOS_TOOLCHAIN:-$ROOT/build/ios-toolchain}"
IOS_PREFIX="${JUICE_IOS_TRIPLE_PREFIX:-arm-apple-darwin11}"
OTOOL_BIN="${JUICE_IOS_OTOOL:-$IOS_TOOLCHAIN/bin/$IOS_PREFIX-otool}"
LIB="$ROOTLESS/usr/lib/libfreetype.dylib"

# Wine's FreeType renderer is compiled only when SONAME_LIBFREETYPE is defined.
# During an x86_64 -> iOS cross-configure, Wine's normal Darwin soname probe may
# link successfully but fail to extract the target dylib identity. Derive the
# identity from the exact Procursus sysroot that will be used on the device.
test -e "$LIB" || {
  echo "Missing iOS FreeType dylib: $LIB" >&2
  exit 2
}

soname="${JUICE_FREETYPE_SONAME:-}"
if test -z "$soname" && test -L "$LIB"; then
  target="$(readlink "$LIB" 2>/dev/null || true)"
  soname="${target##*/}"
fi

case "$soname" in
  libfreetype*.dylib) ;;
  *) soname="" ;;
esac

if test -z "$soname"; then
  test -x "$OTOOL_BIN" || {
    echo "Missing iOS otool for FreeType soname detection: $OTOOL_BIN" >&2
    exit 2
  }
  identity="$($OTOOL_BIN -L "$LIB" 2>/dev/null | awk 'NR == 2 {print $1; exit}')"
  soname="${identity##*/}"
fi

case "$soname" in
  libfreetype*.dylib) ;;
  *)
    echo "Could not determine the iOS FreeType dylib soname from $LIB" >&2
    exit 3
    ;;
esac

printf '%s\n' "$soname"
