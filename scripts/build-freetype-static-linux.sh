#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION="${JUICE_STATIC_FREETYPE_VERSION:-2.14.3}"
URL="${JUICE_STATIC_FREETYPE_URL:-https://download.savannah.gnu.org/releases/freetype/freetype-${VERSION}.tar.xz}"
CACHE="${JUICE_STATIC_FREETYPE_CACHE:-$ROOT/build/deps/freetype-static}"
SOURCE="$CACHE/freetype-$VERSION"
ARCHIVE="$CACHE/freetype-$VERSION.tar.xz"
BUILD="${JUICE_STATIC_FREETYPE_BUILD:-$ROOT/build/freetype-static-ios}"
PREFIX="$BUILD/install"
OBJDIR="$BUILD/obj"
SHIMDIR="$BUILD/shim"
SHIM_C="$SHIMDIR/juice-static-freetype.c"
SHIM_H="$SHIMDIR/juice-static-freetype.h"
SHIM_O="$SHIMDIR/juice-static-freetype.o"
LIB="$PREFIX/lib/libfreetype.a"
IOS_TOOLCHAIN="${JUICE_IOS_TOOLCHAIN:-$ROOT/build/ios-toolchain}"
IOS_PREFIX="${JUICE_IOS_TRIPLE_PREFIX:-arm-apple-darwin11}"
IOS_CC="${JUICE_IOS_CC:-$ROOT/toolchain/juice-ios-cc}"
AR_BIN="${JUICE_IOS_AR:-$IOS_TOOLCHAIN/bin/$IOS_PREFIX-ar}"
RANLIB_BIN="${JUICE_IOS_RANLIB:-$IOS_TOOLCHAIN/bin/$IOS_PREFIX-ranlib}"
CONFIG_GUESS="${JUICE_CONFIG_GUESS:-$ROOT/wine/tools/config.guess}"
BUILD_TRIPLET="${JUICE_BUILD_TRIPLET:-$($CONFIG_GUESS)}"
HOST_TRIPLET="${JUICE_HOST_TRIPLET:-aarch64-apple-darwin}"
JOBS="${JOBS:-${JUICE_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}}"
STAMP="$BUILD/.juice-static-freetype-v2"

case "$(uname -s)" in Linux) ;; *) echo "Static iOS FreeType builder requires Linux." >&2; exit 2;; esac
for tool in curl make python3 tar xz file sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing static FreeType build dependency: $tool" >&2; exit 2; }
done
for tool in "$IOS_CC" "$AR_BIN" "$RANLIB_BIN" "$CONFIG_GUESS"; do
  test -x "$tool" || { echo "Missing static FreeType iOS tool: $tool" >&2; exit 2; }
done
: "${IOS_SDK:?Set IOS_SDK to an iPhoneOS device SDK directory}"
test -d "$IOS_SDK" || { echo "Missing IOS_SDK directory: $IOS_SDK" >&2; exit 2; }

mkdir -p "$CACHE" "$BUILD" "$SHIMDIR"

if test ! -f "$ARCHIVE"; then
  echo "JUICE_STATIC_FREETYPE_FETCH version=$VERSION url=$URL"
  rm -f "$ARCHIVE.part"
  curl --location --fail --retry 3 --output "$ARCHIVE.part" "$URL"
  mv "$ARCHIVE.part" "$ARCHIVE"
fi

if test ! -x "$SOURCE/configure"; then
  tmp="$(mktemp -d "$CACHE/.extract.XXXXXX")"
  trap 'rm -rf "$tmp"' EXIT
  tar -xJf "$ARCHIVE" -C "$tmp"
  extracted="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d -name 'freetype-*' -print -quit)"
  test -n "$extracted" && test -x "$extracted/configure" || { echo "FreeType archive did not contain configure." >&2; exit 3; }
  rm -rf "$SOURCE"
  mv "$extracted" "$SOURCE"
  rm -rf "$tmp"
  trap - EXIT
fi

source_hash="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
expected_stamp="version=$VERSION source_sha256=$source_hash host=$HOST_TRIPLET"
current_stamp="$(cat "$STAMP" 2>/dev/null || true)"

if test ! -f "$LIB" || test "$current_stamp" != "$expected_stamp"; then
  echo "JUICE_STATIC_FREETYPE_BUILD version=$VERSION host=$HOST_TRIPLET jobs=$JOBS"
  rm -rf "$OBJDIR" "$PREFIX"
  mkdir -p "$OBJDIR" "$PREFIX"
  cd "$OBJDIR"

  mapfile -t help_lines < <("$SOURCE/configure" --help 2>/dev/null || true)
  configure_help="$(printf '%s\n' "${help_lines[@]}")"
  args=(
    "--build=$BUILD_TRIPLET"
    "--host=$HOST_TRIPLET"
    "--prefix=$PREFIX"
    --enable-static
    --disable-shared
  )
  for dep in zlib bzip2 png harfbuzz brotli; do
    if grep -q -- "--with-$dep" <<<"$configure_help"; then
      args+=("--with-$dep=no")
    fi
  done

  env \
    IOS_SDK="$IOS_SDK" \
    JUICE_IOS_TOOLCHAIN="$IOS_TOOLCHAIN" \
    CC="$IOS_CC" AR="$AR_BIN" RANLIB="$RANLIB_BIN" \
    CFLAGS="${JUICE_STATIC_FREETYPE_CFLAGS:--O2 -fPIC}" \
    "$SOURCE/configure" "${args[@]}"
  make -j"$JOBS"
  make install
  printf '%s\n' "$expected_stamp" > "$STAMP"
else
  echo "JUICE_STATIC_FREETYPE_REUSE version=$VERSION lib=$LIB"
fi

test -f "$PREFIX/include/freetype2/ft2build.h" || { echo "Static FreeType headers were not installed." >&2; exit 4; }
test -s "$LIB" || { echo "Static FreeType archive was not built: $LIB" >&2; exit 4; }

# Keep Wine's normal FreeType implementation as the source of truth. The shim
# only supplies the dlopen/dlsym boundary with statically linked symbols; the
# resolver list is generated from Wine's own FT_* function-pointer declarations.
python3 - "$ROOT/wine/dlls/win32u/freetype.c" "$ROOT/wine/dlls/dwrite/freetype.c" "$SHIM_C" "$SHIM_H" <<'PY'
from pathlib import Path
import re
import sys

win32u, dwrite, c_path, h_path = map(Path, sys.argv[1:])
pattern = re.compile(r"MAKE_FUNCPTR\((FT_[A-Za-z0-9_]+)\)")
symbols = sorted({m.group(1) for p in (win32u, dwrite) for m in pattern.finditer(p.read_text(encoding="utf-8", errors="replace"))})
if len(symbols) < 25:
    raise SystemExit(f"unexpectedly short FreeType resolver list: {len(symbols)}")

h = r'''#ifndef JUICE_STATIC_FREETYPE_SHIM_H
#define JUICE_STATIC_FREETYPE_SHIM_H
#include <dlfcn.h>
void *juice_static_freetype_dlopen(const char *path, int mode);
void *juice_static_freetype_dlsym(void *handle, const char *name);
int juice_static_freetype_dlclose(void *handle);
#define dlopen(path, mode) juice_static_freetype_dlopen((path), (mode))
#define dlsym(handle, name) juice_static_freetype_dlsym((handle), (name))
#define dlclose(handle) juice_static_freetype_dlclose((handle))
#endif
'''

includes = r'''#include <dlfcn.h>
#include <stdint.h>
#include <string.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_GLYPH_H
#include FT_TYPES_H
#include FT_TRUETYPE_TABLES_H
#include FT_SFNT_NAMES_H
#include FT_OUTLINE_H
#include FT_TRIGONOMETRY_H
#include FT_MODULE_H
#include FT_WINFONTS_H
#include FT_LCD_FILTER_H
#include FT_SIZES_H

static char juice_static_freetype_handle_token;
static const char juice_static_freetype_name[] = "juice-static-freetype";

void *juice_static_freetype_dlopen(const char *path, int mode)
{
    if (path && !strcmp(path, juice_static_freetype_name)) return &juice_static_freetype_handle_token;
    return dlopen(path, mode);
}

void *juice_static_freetype_dlsym(void *handle, const char *name)
{
    if (handle != &juice_static_freetype_handle_token) return dlsym(handle, name);
    if (!name) return NULL;
'''

lines = [includes]
for symbol in symbols:
    if symbol == "FT_MulFix":
        lines.append("#ifndef FT_MULFIX_INLINED\n")
        lines.append(f'    if (!strcmp(name, "{symbol}")) return (void *)(uintptr_t)&{symbol};\n')
        lines.append("#endif\n")
    else:
        lines.append(f'    if (!strcmp(name, "{symbol}")) return (void *)(uintptr_t)&{symbol};\n')
lines.append(r'''    return NULL;
}

int juice_static_freetype_dlclose(void *handle)
{
    if (handle == &juice_static_freetype_handle_token) return 0;
    return dlclose(handle);
}
''')

c_text = "".join(lines)
for path, text in ((h_path, h), (c_path, c_text)):
    old = path.read_text(encoding="utf-8") if path.exists() else None
    if old != text:
        path.write_text(text, encoding="utf-8")
print(f"JUICE_STATIC_FREETYPE_SHIM_GENERATED symbols={len(symbols)} header={h_path} source={c_path}")
PY

if test ! -f "$SHIM_O" || test "$SHIM_C" -nt "$SHIM_O" || test "$LIB" -nt "$SHIM_O"; then
  IOS_SDK="$IOS_SDK" JUICE_IOS_TOOLCHAIN="$IOS_TOOLCHAIN" \
    "$IOS_CC" -O2 -fPIC -I"$PREFIX/include/freetype2" -c "$SHIM_C" -o "$SHIM_O"
fi
file "$SHIM_O" | grep -Eq 'Mach-O 64-bit arm64' || {
  echo "Static FreeType shim is not arm64 Mach-O: $SHIM_O" >&2
  file "$SHIM_O" >&2 || true
  exit 4
}

printf 'JUICE_STATIC_FREETYPE_OK version=%s prefix=%s lib=%s shim=%s header=%s\n' \
  "$VERSION" "$PREFIX" "$LIB" "$SHIM_O" "$SHIM_H"
