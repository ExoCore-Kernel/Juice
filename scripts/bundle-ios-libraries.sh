#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/network-build.env"
ROOTLESS="${JUICE_IOS_ROOTLESS_SYSROOT:-$ROOT/build/deps/rootless-sysroot}"
DESTINATION="${1:-}"
PATTERNS="${JUICE_NETWORK_LIBRARY_PATTERNS:-$ROOT/config/network-library-patterns.txt}"
STATIC_FREETYPE="${JUICE_STATIC_FREETYPE:-1}"

test -n "$DESTINATION" || { echo "usage: $0 DESTINATION" >&2; exit 2; }
test -d "$ROOTLESS/usr/lib" || { echo "Missing iOS dependency sysroot: $ROOTLESS/usr/lib" >&2; exit 2; }
mkdir -p "$DESTINATION"

declare -A selected=()
select_name()
{
  local name="$1" source="$ROOTLESS/usr/lib/$1"
  case "$name" in ''|*/*|.|..) echo "Unsafe bundled library name: $name" >&2; exit 3;; esac
  test -e "$source" || {
    echo "Missing selected iOS runtime library: $source" >&2
    exit 3
  }
  selected["$name"]=1
}

# The default build statically links FreeType into Wine. Preserve the dynamic
# fallback for diagnostic builds without carrying an unused font dylib in the
# normal app.
if test "${JUICE_WITHOUT_FREETYPE:-0}" != 1 && test "$STATIC_FREETYPE" = 0; then
  for pattern in libfreetype\*.dylib libbrotli\*.dylib libpng\*.dylib; do
    while IFS= read -r path; do test -e "$path" && select_name "$(basename "$path")"; done \
      < <(find "$ROOTLESS/usr/lib" -maxdepth 1 \( -type f -o -type l \) -name "$pattern" -print)
  done
  test "${#selected[@]}" -gt 0 || { echo "No dynamic FreeType libraries were found." >&2; exit 3; }
fi

if test "${JUICE_WITHOUT_GNUTLS:-0}" != 1; then
  list="$ROOTLESS/.juice-network-libraries"
  if test -s "$list"; then
    while IFS= read -r name; do
      test -z "$name" || select_name "$name"
    done < "$list"
  else
    test -f "$PATTERNS" || { echo "Missing network library pattern list: $PATTERNS" >&2; exit 3; }
    while IFS= read -r pattern; do
      case "$pattern" in ''|'#'*) continue;; esac
      matched=0
      while IFS= read -r path; do
        test -e "$path" || continue
        select_name "$(basename "$path")"
        matched=1
      done < <(find "$ROOTLESS/usr/lib" -maxdepth 1 \( -type f -o -type l \) -name "$pattern" -print)
      test "$matched" = 1 || {
        echo "No iOS library matched required GnuTLS closure pattern: $pattern" >&2
        exit 3
      }
    done < "$PATTERNS"
  fi
  test -e "$ROOTLESS/usr/lib/$JUICE_GNUTLS_SONAME" || {
    echo "Configured GnuTLS soname is absent: $ROOTLESS/usr/lib/$JUICE_GNUTLS_SONAME" >&2
    exit 3
  }
fi

for name in "${!selected[@]}"; do
  cp -a "$ROOTLESS/usr/lib/$name" "$DESTINATION/"
done

if test "${#selected[@]}" -gt 0; then
  python3 "$ROOT/scripts/patch-bundled-dylib-paths.py" "$DESTINATION"
fi
if test "${JUICE_WITHOUT_GNUTLS:-0}" != 1; then
  test -f "$DESTINATION/$JUICE_GNUTLS_SONAME" || {
    echo "Bundled GnuTLS soname was not materialized: $DESTINATION/$JUICE_GNUTLS_SONAME" >&2
    exit 3
  }
fi

count="$(find "$DESTINATION" -maxdepth 1 -type f | wc -l | tr -d ' ')"
echo "JUICE_IOS_LIBRARIES_BUNDLED path=$DESTINATION files=$count static_freetype=$STATIC_FREETYPE gnutls=$([ "${JUICE_WITHOUT_GNUTLS:-0}" = 1 ] && echo 0 || echo 1)"
