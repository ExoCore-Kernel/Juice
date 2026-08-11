#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
JBROOT="${JBROOT:-/var/jb}"
SDK="${IOS_SDK:-$JBROOT/usr/share/SDKs/iPhoneOS.sdk}"
MIN_FREE_KB="${JUICE_MIN_FREE_KB:-4194304}"
missing=()

test "$(uname -s)" = Darwin || {
  echo "The complete Grape build must run on the ARM64 iOS/iPadOS device." >&2
  exit 2
}
if test -x "$JBROOT/usr/sbin/sysctl"; then
  test "$("$JBROOT/usr/sbin/sysctl" -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 || {
    echo "Expected an ARM64 device." >&2
    exit 2
  }
else
  missing+=("$JBROOT/usr/sbin/sysctl")
fi
test -d "$SDK" || missing+=("iPhoneOS SDK ($SDK)")

for tool in bash bison clang file git install_name_tool ldid m4 make otool pkg-config python3 rsync sha256sum sudo unzip zip; do
  test -x "$JBROOT/usr/bin/$tool" || missing+=("$JBROOT/usr/bin/$tool")
done

if test "${#missing[@]}" -ne 0; then
  printf 'Missing device build prerequisite: %s\n' "${missing[@]}" >&2
  exit 3
fi

lld_link="$("$JBROOT/usr/bin/clang" --print-prog-name=lld-link)"
test -x "$lld_link" || {
  echo "Clang could not locate lld-link: $lld_link" >&2
  echo "Install the matching linker with: sudo $JBROOT/usr/bin/apt-get install lld-16" >&2
  exit 3
}

export PKG_CONFIG_PATH="$JBROOT/usr/lib/pkgconfig:$JBROOT/usr/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
freetype_header="$JBROOT/usr/include/freetype2/ft2build.h"
freetype_library="$JBROOT/usr/lib/libfreetype.dylib"
if test ! -f "$freetype_header" || test ! -f "$freetype_library"; then
  cat >&2 <<EOF
FreeType development files are required for Windows text rendering.
Install them once on the build device, then rerun this check:
  sudo $JBROOT/usr/bin/apt-get install libfreetype-dev
Set JUICE_WITHOUT_FREETYPE=1 only for a diagnostic graphics-only build.
EOF
  test "${JUICE_WITHOUT_FREETYPE:-0}" = 1 || exit 4
else
  freetype_version="$("$JBROOT/usr/bin/pkg-config" --modversion freetype2 2>/dev/null || echo installed)"
  echo "JUICE_FREETYPE version=$freetype_version header=$freetype_header"
fi

helper="$(find /var/containers/Bundle/Application -type f \
  -path '*/TrollStore.app/trollstorehelper' -print -quit 2>/dev/null)"
test -x "$helper" || { echo "TrollStore helper was not found." >&2; exit 5; }

free_kb="$(df -Pk "$ROOT" | awk 'NR == 2 {print $4}')"
case "$free_kb" in ''|*[!0-9]*) free_kb=0;; esac
if test "$free_kb" -lt "$MIN_FREE_KB"; then
  echo "A clean Wine build needs at least $((MIN_FREE_KB / 1024)) MiB free; found $((free_kb / 1024)) MiB." >&2
  test "${JUICE_ALLOW_LOW_SPACE:-0}" = 1 || exit 6
fi

echo "JUICE_DEVICE_PREFLIGHT_OK sdk=$SDK free_mib=$((free_kb / 1024))"
