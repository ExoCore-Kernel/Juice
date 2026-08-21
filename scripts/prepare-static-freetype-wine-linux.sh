#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/network-build.env"
NATIVE="${JUICE_WINE_BUILD:-$ROOT/build/wine-ios}"
ROOTLESS="${JUICE_IOS_ROOTLESS_SYSROOT:-$ROOT/build/deps/rootless-sysroot}"
FT_BUILD="${JUICE_STATIC_FREETYPE_BUILD:-$ROOT/build/freetype-static-ios}"
FT_PREFIX="$FT_BUILD/install"
FT_LIB="$FT_PREFIX/lib/libfreetype.a"
FT_SHIM="$FT_BUILD/shim/juice-static-freetype.o"
FT_HEADER="$FT_BUILD/shim/juice-static-freetype.h"
STATIC_SONAME="juice-static-freetype"
MARKER="$NATIVE/.juice-static-freetype-v3"
JOBS="${JOBS:-${JUICE_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}}"
MAKE="${MAKE:-make}"
SHELL_BIN="${SHELL_BIN:-/bin/bash}"

if test "${JUICE_WITHOUT_FREETYPE:-0}" = 1 || test "${JUICE_STATIC_FREETYPE:-1}" = 0; then
  exit 0
fi

bash "$ROOT/scripts/build-freetype-static-linux.sh"
test -s "$FT_LIB" -a -s "$FT_SHIM" -a -s "$FT_HEADER" || {
  echo "Static FreeType outputs are incomplete." >&2
  exit 3
}

ft_cflags="-I$FT_PREFIX/include/freetype2 -include $FT_HEADER"
ft_libs="$FT_SHIM $FT_LIB"
fingerprint="$(sha256sum "$FT_LIB" "$FT_SHIM" "$FT_HEADER" \
  "$ROOT/wine/dlls/win32u/Makefile.in" "$ROOT/wine/dlls/dwrite/Makefile.in" \
  "$ROOT/config/network-build.env" "$ROOT/config/network-packages.txt" \
  "$ROOT/scripts/build-freetype-static-linux.sh" "$ROOT/scripts/prepare-static-freetype-wine-linux.sh" \
  | sha256sum | awk '{print $1}')"
old_fingerprint="$(cat "$MARKER" 2>/dev/null || true)"
need_configure=0
if test "${JUICE_RECONFIGURE:-0}" = 1 || test ! -f "$NATIVE/Makefile"; then
  need_configure=1
elif ! grep -Fq "#define SONAME_LIBFREETYPE \"$STATIC_SONAME\"" "$NATIVE/include/config.h" 2>/dev/null; then
  need_configure=1
elif ! grep -Fq "$FT_LIB" "$NATIVE/Makefile" 2>/dev/null; then
  need_configure=1
elif ! grep -Fq "$FT_HEADER" "$NATIVE/Makefile" 2>/dev/null; then
  need_configure=1
elif test "${JUICE_WITHOUT_GNUTLS:-0}" != 1 && \
     ! grep -Fq "#define SONAME_LIBGNUTLS \"$JUICE_GNUTLS_RUNTIME_NAME\"" "$NATIVE/include/config.h" 2>/dev/null; then
  need_configure=1
fi

if test "$need_configure" = 1; then
  echo "JUICE_STATIC_FREETYPE_CONFIGURE mode=one-time native=$NATIVE"
  tmp="$(mktemp -d "$ROOT/build/.static-freetype-config.XXXXXX")"
  win32u="$ROOT/wine/dlls/win32u/Makefile.in"
  dwrite="$ROOT/wine/dlls/dwrite/Makefile.in"
  cp -p "$win32u" "$tmp/win32u.Makefile.in"
  cp -p "$dwrite" "$tmp/dwrite.Makefile.in"
  restore()
  {
    # Preserve the original mtimes as well as contents. Otherwise Make could
    # think the restored template is newer than the generated Makefile and
    # silently regenerate away the static link additions on the next command.
    cp -p "$tmp/win32u.Makefile.in" "$win32u" 2>/dev/null || true
    cp -p "$tmp/dwrite.Makefile.in" "$dwrite" 2>/dev/null || true
    rm -rf "$tmp"
  }
  trap restore EXIT INT TERM

  python3 - "$win32u" "$dwrite" <<'PY'
from pathlib import Path
import sys

win32u, dwrite = map(Path, sys.argv[1:])
w = win32u.read_text(encoding="utf-8")
old = "UNIX_LIBS    = $(CORETEXT_LIBS) $(COREFOUNDATION_LIBS) $(PTHREAD_LIBS) -lm"
new = "UNIX_LIBS    = $(CORETEXT_LIBS) $(COREFOUNDATION_LIBS) $(PTHREAD_LIBS) $(FREETYPE_LIBS) -lm"
if new not in w:
    if old not in w:
        raise SystemExit("win32u Makefile.in UNIX_LIBS line changed unexpectedly")
    w = w.replace(old, new, 1)
win32u.write_text(w, encoding="utf-8")

d = dwrite.read_text(encoding="utf-8")
line = "UNIX_LIBS = $(FREETYPE_LIBS)"
if line not in d:
    anchor = "UNIX_CFLAGS = $(FREETYPE_CFLAGS)"
    if anchor not in d:
        raise SystemExit("dwrite Makefile.in UNIX_CFLAGS line changed unexpectedly")
    d = d.replace(anchor, anchor + "\n" + line, 1)
dwrite.write_text(d, encoding="utf-8")
PY

  FREETYPE_CFLAGS="$ft_cflags" FREETYPE_LIBS="$ft_libs" \
    bash "$ROOT/scripts/configure-wine-linux.sh"

  python3 - "$NATIVE/include/config.h" "$STATIC_SONAME" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
soname = sys.argv[2]
text = path.read_text(encoding="utf-8", errors="surrogateescape")
pattern = re.compile(r'(?m)^(?:/\* #undef SONAME_LIBFREETYPE \*/|#define SONAME_LIBFREETYPE ".*")$')
replacement = f'#define SONAME_LIBFREETYPE "{soname}"'
if not pattern.search(text):
    raise SystemExit(f"Wine config.h has no SONAME_LIBFREETYPE slot: {path}")
text = pattern.sub(replacement, text, count=1)
tmp = path.with_name(path.name + ".juice-static-ft-new")
tmp.write_text(text, encoding="utf-8", errors="surrogateescape")
tmp.replace(path)
PY

  restore
  trap - EXIT INT TERM
fi

grep -Fq "#define SONAME_LIBFREETYPE \"$STATIC_SONAME\"" "$NATIVE/include/config.h" || {
  echo "Static FreeType SONAME was not installed in native Wine config." >&2
  exit 4
}
grep -Fq "$FT_LIB" "$NATIVE/Makefile" || {
  echo "Native Wine Makefile does not contain static FreeType archive: $FT_LIB" >&2
  exit 4
}
grep -Fq "$FT_HEADER" "$NATIVE/Makefile" || {
  echo "Native Wine Makefile does not contain the static FreeType shim header." >&2
  exit 4
}
grep -Fq 'dlls/dwrite/dwrite.so:' "$NATIVE/Makefile" || {
  echo "Native Wine Makefile did not generate the dwrite Unixlib target." >&2
  exit 4
}
if test "${JUICE_WITHOUT_GNUTLS:-0}" != 1; then
  grep -Fq "#define SONAME_LIBGNUTLS \"$JUICE_GNUTLS_RUNTIME_NAME\"" "$NATIVE/include/config.h" || {
    echo "Bundled GnuTLS SONAME was not installed in native Wine config." >&2
    exit 4
  }
fi

if test "$old_fingerprint" != "$fingerprint" || test "$need_configure" = 1; then
  rm -f \
    "$NATIVE/dlls/win32u/freetype.o" "$NATIVE/dlls/win32u/win32u.so" \
    "$NATIVE/dlls/dwrite/freetype.o" "$NATIVE/dlls/dwrite/dwrite.so" \
    "$NATIVE/dlls/secur32/gnutls.o" "$NATIVE/dlls/secur32/secur32.so"
  printf '%s\n' "$fingerprint" > "$MARKER"
  echo "JUICE_STATIC_FREETYPE_OBJECT_REFRESH fingerprint=$fingerprint"
else
  echo "JUICE_STATIC_FREETYPE_CONFIG_REUSE fingerprint=$fingerprint"
fi

# DirectWrite's PE half calls into this Unixlib for glyph metrics/rasterisation.
# Build it explicitly because the historical Juice native target list predates
# the DirectWrite path. assemble-runtime.sh stages it beside the other Unixlibs.
"$MAKE" --output-sync=target -C "$NATIVE" -j"$JOBS" SHELL="$SHELL_BIN" PWD="$NATIVE" \
  "FREETYPE_CFLAGS=$ft_cflags" "FREETYPE_LIBS=$ft_libs" \
  dlls/dwrite/dwrite.so

test -s "$NATIVE/dlls/dwrite/dwrite.so" || { echo "dwrite Unixlib was not built." >&2; exit 5; }
file "$NATIVE/dlls/dwrite/dwrite.so" | grep -Eq 'Mach-O 64-bit arm64' || {
  echo "dwrite Unixlib is not arm64 Mach-O." >&2
  file "$NATIVE/dlls/dwrite/dwrite.so" >&2 || true
  exit 5
}

echo "JUICE_STATIC_FREETYPE_PREPARED native=$NATIVE soname=$STATIC_SONAME dwrite=$NATIVE/dlls/dwrite/dwrite.so"
