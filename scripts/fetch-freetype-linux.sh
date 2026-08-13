#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
BASE="${JUICE_PROCURSUS_REPOSITORY:-https://apt.procurs.us}"
SUITE="${JUICE_PROCURSUS_SUITE:-1800}"
ARCH="${JUICE_PROCURSUS_ARCH:-iphoneos-arm64}"
CACHE="${JUICE_PROCURSUS_CACHE:-$ROOT/build/deps/procursus}"
SYSROOT="${JUICE_IOS_ROOTLESS_SYSROOT:-$ROOT/build/deps/rootless-sysroot}"
INDEX="$CACHE/Packages-${SUITE}-${ARCH}.xz"
INDEX_URL="$BASE/dists/$SUITE/main/binary-$ARCH/Packages.xz"

case "$(uname -s)" in Linux) ;; *) echo "The automatic FreeType fetcher is for Linux hosts." >&2; exit 2;; esac
for tool in curl dpkg-deb python3 sha256sum xz; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing FreeType fetch dependency: $tool" >&2; exit 2; }
done

if test -f "$SYSROOT/usr/include/freetype2/ft2build.h" && test -e "$SYSROOT/usr/lib/libfreetype.dylib" && test "${JUICE_REFRESH_DEPS:-0}" != 1; then
  echo "JUICE_FREETYPE_SYSROOT_OK path=$SYSROOT source=procursus cached=1"
  exit 0
fi

mkdir -p "$CACHE/downloads" "$ROOT/build/deps"
partial="$INDEX.part"
rm -f "$partial"
curl --location --fail --retry 3 --output "$partial" "$INDEX_URL"
mv "$partial" "$INDEX"

plain="$CACHE/Packages-${SUITE}-${ARCH}"
xz -dc "$INDEX" > "$plain"

tmp="$(mktemp -d "$ROOT/build/deps/.freetype.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

find_package()
{
  python3 - "$plain" "$1" <<'PY'
import sys
path, wanted = sys.argv[1:]
records = []
record = {}
with open(path, encoding='utf-8', errors='replace') as f:
    for raw in f:
        line = raw.rstrip('\n')
        if not line:
            if record:
                records.append(record)
                record = {}
            continue
        if line[:1].isspace() or ':' not in line:
            continue
        key, value = line.split(':', 1)
        record[key] = value.strip()
if record:
    records.append(record)

matches = [r for r in records if r.get('Package') == wanted and r.get('Filename') and r.get('SHA256')]
if not matches:
    raise SystemExit(f"Package {wanted!r} not found in {path}")
# Debian repository metadata normally exposes one current candidate per suite.
r = matches[-1]
print(r['Filename'] + '\t' + r['SHA256'])
PY
}

for package in libfreetype-dev libfreetype6; do
  row="$(find_package "$package")"
  filename="${row%%$'\t'*}"
  expected="${row#*$'\t'}"
  deb="$CACHE/downloads/$(basename "$filename")"

  if test -f "$deb" && printf '%s  %s\n' "$expected" "$deb" | sha256sum -c - >/dev/null 2>&1; then
    :
  else
    rm -f "$deb.part"
    curl --location --fail --retry 3 --output "$deb.part" "$BASE/$filename"
    printf '%s  %s\n' "$expected" "$deb.part" | sha256sum -c -
    mv "$deb.part" "$deb"
  fi
  dpkg-deb -x "$deb" "$tmp"
done

source_root="$tmp/var/jb"
test -d "$source_root" || {
  echo "Procursus rootless FreeType packages did not contain /var/jb." >&2
  exit 4
}
test -f "$source_root/usr/include/freetype2/ft2build.h" || { echo "Procursus FreeType headers were missing after extraction." >&2; exit 4; }
test -e "$source_root/usr/lib/libfreetype.dylib" || { echo "Procursus libfreetype.dylib was missing after extraction." >&2; exit 4; }

case "$SYSROOT" in
  "$ROOT"/build/*) ;;
  *) test "${JUICE_ALLOW_EXTERNAL_BUILD:-0}" = 1 || {
       echo "Refusing to replace automatic sysroot outside build/: $SYSROOT" >&2
       echo "Set JUICE_ALLOW_EXTERNAL_BUILD=1 if this path is intentional." >&2
       exit 5
     };;
esac
rm -rf "$SYSROOT"
mkdir -p "$SYSROOT"
cp -a "$source_root/." "$SYSROOT/"

# Keep provenance beside the extracted files for reproducibility/debugging.
cat > "$SYSROOT/.juice-freetype-source" <<INFO
repository=$BASE
suite=$SUITE
architecture=$ARCH
packages=libfreetype-dev,libfreetype6
INFO

echo "JUICE_FREETYPE_SYSROOT_OK path=$SYSROOT source=procursus cached=0 suite=$SUITE arch=$ARCH"
