#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/network-build.env"
BASE="${JUICE_PROCURSUS_REPOSITORY:-https://apt.procurs.us}"
MANIFEST="${JUICE_NETWORK_PACKAGES:-$ROOT/config/network-packages.txt}"
CACHE="${JUICE_NETWORK_CACHE:-$ROOT/build/deps/procursus-network}"
SYSROOT="${JUICE_IOS_ROOTLESS_SYSROOT:-$ROOT/build/deps/rootless-sysroot}"
MARKER="$SYSROOT/.juice-network-runtime-v$JUICE_NETWORK_DEPS_VERSION"

case "$(uname -s)" in Linux) ;; *) echo "The automatic network dependency fetcher is for Linux hosts." >&2; exit 2;; esac
for tool in curl dpkg-deb python3 sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing network fetch dependency: $tool" >&2; exit 2; }
done
test -f "$MANIFEST" || { echo "Missing network package manifest: $MANIFEST" >&2; exit 2; }

manifest_hash="$(sha256sum "$MANIFEST" "$ROOT/config/network-build.env" "$0" | sha256sum | awk '{print $1}')"
if test -f "$SYSROOT/usr/include/gnutls/gnutls.h" && \
   test -e "$SYSROOT/usr/lib/libgnutls.dylib" && \
   test -e "$SYSROOT/usr/lib/$JUICE_GNUTLS_SONAME" && \
   test -s "$SYSROOT/.juice-network-libraries" && \
   test "$(cat "$MARKER" 2>/dev/null || true)" = "$manifest_hash" && \
   test "${JUICE_REFRESH_DEPS:-0}" != 1; then
  echo "JUICE_NETWORK_SYSROOT_OK path=$SYSROOT source=procursus cached=1 gnutls=$JUICE_GNUTLS_VERSION"
  exit 0
fi

case "$SYSROOT" in
  "$ROOT"/build/*) ;;
  *) test "${JUICE_ALLOW_EXTERNAL_BUILD:-0}" = 1 || {
       echo "Refusing to merge automatic dependencies outside build/: $SYSROOT" >&2
       exit 3
     };;
esac

mkdir -p "$CACHE/downloads" "$ROOT/build/deps" "$SYSROOT"
tmp="$(mktemp -d "$ROOT/build/deps/.network.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

package_count=0
while IFS='|' read -r package version filename expected; do
  case "$package" in ''|'#'*) continue;; esac
  test -n "$version" -a -n "$filename" -a -n "$expected" || {
    echo "Malformed network package manifest row for $package." >&2
    exit 4
  }
  deb="$CACHE/downloads/$(basename "$filename")"
  if ! test -f "$deb" || ! printf '%s  %s\n' "$expected" "$deb" | sha256sum -c - >/dev/null 2>&1; then
    rm -f "$deb.part"
    curl --location --fail --retry 3 --output "$deb.part" "$BASE/$filename"
    printf '%s  %s\n' "$expected" "$deb.part" | sha256sum -c -
    mv "$deb.part" "$deb"
  fi
  actual_package="$(dpkg-deb -f "$deb" Package)"
  actual_version="$(dpkg-deb -f "$deb" Version)"
  test "$actual_package" = "$package" -a "$actual_version" = "$version" || {
    echo "Unexpected package identity in $deb: $actual_package $actual_version (wanted $package $version)" >&2
    exit 4
  }
  dpkg-deb -x "$deb" "$tmp"
  package_count=$((package_count + 1))
done < "$MANIFEST"

source_root="$tmp/var/jb"
test "$package_count" -ge 10 || { echo "Network package manifest is unexpectedly short." >&2; exit 4; }
test -f "$source_root/usr/include/gnutls/gnutls.h" || { echo "GnuTLS headers were missing after extraction." >&2; exit 4; }
test -e "$source_root/usr/lib/libgnutls.dylib" || { echo "libgnutls.dylib was missing after extraction." >&2; exit 4; }
test -e "$source_root/usr/lib/$JUICE_GNUTLS_SONAME" || { echo "Configured GnuTLS soname was missing after extraction: $JUICE_GNUTLS_SONAME" >&2; exit 4; }

# Merge after the FreeType fetcher: it owns sysroot creation, while this script
# adds the HTTPS closure without removing the already-pinned font libraries.
cp -a "$source_root/." "$SYSROOT/"
while IFS= read -r library; do
  # Development packages can contain optional linker symlinks whose C++
  # runtime target is intentionally absent. They are not part of this closure.
  test -e "$library" || continue
  basename "$library"
done < <(find "$source_root/usr/lib" -maxdepth 1 \( -type f -o -type l \) -name '*.dylib' -print) \
  | LC_ALL=C sort -u > "$SYSROOT/.juice-network-libraries"
test -s "$SYSROOT/.juice-network-libraries" || {
  echo "No network runtime dylibs were discovered in the pinned packages." >&2
  exit 4
}
printf '%s\n' "$manifest_hash" > "$MARKER"
cat > "$SYSROOT/.juice-network-source" <<INFO
repository=$BASE
gnutls=$JUICE_GNUTLS_VERSION
packages=$package_count
libraries=$(wc -l < "$SYSROOT/.juice-network-libraries" | tr -d ' ')
manifest_sha256=$manifest_hash
INFO

echo "JUICE_NETWORK_SYSROOT_OK path=$SYSROOT source=procursus cached=0 gnutls=$JUICE_GNUTLS_VERSION packages=$package_count"
