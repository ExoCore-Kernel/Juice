#!/var/jb/usr/bin/bash

set -u

export PATH="/var/jb/usr/bin:/usr/bin:/bin:$PATH"

J="/var/jb/var/mobile/Juice"
SRC="$J/src/wine-11.13"
IOS_BUILD="$J/build/wine-ios"
PE_BUILD="$J/build/wine-arm64-pe"
BACKUPS="/var/mobile/Documents/Juice-Success-Backups"
STAMP="$(date +%Y%m%d-%H%M%S)"
WORK="$J/tmp/freetype-audit-$STAMP"
LOG="$J/logs/freetype-audit-$STAMP.log"

mkdir -p "$WORK" "$J/logs"

exec > >(tee "$LOG") 2>&1

echo "============================================================"
echo " Juice FreeType rebuild audit"
echo " Date: $(date)"
echo "============================================================"

echo
echo "=== 1. Existing Juice paths ==="

for ITEM in \
    "$SRC" \
    "$IOS_BUILD" \
    "$PE_BUILD" \
    "$J/runtime" \
    "$J/prefixes/arm64-test" \
    "$J/tools" \
    "$BACKUPS"
do
    if [ -e "$ITEM" ]; then
        echo "FOUND: $ITEM"
    else
        echo "MISSING: $ITEM"
    fi
done

echo
echo "=== 2. Disk space ==="

df -h "$J" "$BACKUPS" 2>/dev/null || true

echo
echo "=== 3. Golden recovery archives ==="

FOUND_CHECKSUM=0

for SUMFILE in "$BACKUPS"/*GOLDEN*.sha256; do
    if [ -f "$SUMFILE" ]; then
        FOUND_CHECKSUM=1
        echo
        echo "Checking: $SUMFILE"
        (
            cd "$BACKUPS" || exit 1
            sha256sum -c "$(basename "$SUMFILE")"
        ) || true
    fi
done

if [ "$FOUND_CHECKSUM" -eq 0 ]; then
    echo "No matching GOLDEN .sha256 file found."
    echo "Existing backup files:"
    ls -lah "$BACKUPS" 2>/dev/null | head -n 100 || true
fi

echo
echo "=== 4. Source version ==="

if [ -f "$SRC/VERSION" ]; then
    cat "$SRC/VERSION"
fi

git -C "$SRC" status --short 2>/dev/null || true
git -C "$SRC" rev-parse HEAD 2>/dev/null || true

echo
echo "=== 5. Original configure arguments ==="

for BUILD in "$IOS_BUILD" "$PE_BUILD"; do
    echo
    echo "--- $BUILD ---"

    if [ -x "$BUILD/config.status" ]; then
        (
            cd "$BUILD" || exit 1
            ./config.status --config
        ) || true
    else
        echo "config.status missing or not executable"
    fi

    echo
    echo "FreeType-related configuration:"
    grep -Ei \
        'freetype|ft2build|FREETYPE_CFLAGS|FREETYPE_LIBS|SONAME_LIBFREETYPE' \
        "$BUILD/config.log" \
        "$BUILD/config.status" \
        "$BUILD/include/config.h" \
        "$BUILD/Makefile" \
        2>/dev/null |
        head -n 160 || true
done

echo
echo "=== 6. pkg-config availability ==="

PKG_CONFIG_BIN="$(command -v pkg-config 2>/dev/null || true)"
echo "pkg-config=${PKG_CONFIG_BIN:-NOT_FOUND}"

export PKG_CONFIG_PATH="/var/jb/usr/lib/pkgconfig:/var/jb/usr/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

if [ -n "$PKG_CONFIG_BIN" ]; then
    echo "PKG_CONFIG_PATH=$PKG_CONFIG_PATH"

    pkg-config --modversion freetype2 2>&1 || true
    pkg-config --cflags freetype2 2>&1 || true
    pkg-config --libs freetype2 2>&1 || true
fi

echo
echo "=== 7. FreeType headers and libraries ==="

find \
    /var/jb/usr \
    /var/jb/var/mobile/theos \
    -type f \
    \( \
        -name 'ft2build.h' \
        -o -name 'freetype.h' \
        -o -name 'libfreetype.a' \
        -o -name 'libfreetype.dylib' \
        -o -name 'libfreetype.*.dylib' \
        -o -name 'freetype2.pc' \
    \) \
    2>/dev/null |
    sort |
    head -n 200

echo
echo "=== 8. Inspecting FreeType libraries ==="

find /var/jb/usr /var/jb/var/mobile/theos \
    -type f \
    \( \
        -name 'libfreetype.a' \
        -o -name 'libfreetype.dylib' \
        -o -name 'libfreetype.*.dylib' \
    \) \
    2>/dev/null |
while IFS= read -r LIB; do
    echo
    echo "--- $LIB ---"
    file "$LIB" 2>/dev/null || true
    otool -L "$LIB" 2>/dev/null || true
done

echo
echo "=== 9. Selecting iPhoneOS SDK ==="

SDK=""

for CANDIDATE in \
    "/var/jb/usr/share/SDKs/iPhoneOS.sdk" \
    "/var/jb/var/mobile/theos/sdks/iPhoneOS16.5.sdk"
do
    if [ -d "$CANDIDATE" ]; then
        SDK="$CANDIDATE"
        break
    fi
done

echo "SDK=${SDK:-NOT_FOUND}"

echo
echo "=== 10. Compiling a native FreeType probe ==="

cat > "$WORK/freetype_probe.c" <<'EOF'
#include <stdio.h>
#include <ft2build.h>
#include FT_FREETYPE_H

int main(void)
{
    FT_Library library;
    FT_Error error;

    error = FT_Init_FreeType(&library);
    if (error)
    {
        fprintf(stderr, "FT_Init_FreeType failed: %d\n", error);
        return 1;
    }

    printf("FreeType runtime version: %d.%d.%d\n",
           FREETYPE_MAJOR,
           FREETYPE_MINOR,
           FREETYPE_PATCH);

    FT_Done_FreeType(library);
    return 0;
}
EOF

CC="/var/jb/usr/bin/clang"
LDID="/var/jb/usr/bin/ldid"

FT_CFLAGS=""
FT_LIBS=""

if [ -n "$PKG_CONFIG_BIN" ]; then
    FT_CFLAGS="$(pkg-config --cflags freetype2 2>/dev/null || true)"
    FT_LIBS="$(pkg-config --libs freetype2 2>/dev/null || true)"
fi

if [ -z "$FT_CFLAGS" ]; then
    FT_CFLAGS="-I/var/jb/usr/include/freetype2"
fi

if [ -z "$FT_LIBS" ]; then
    FT_LIBS="-L/var/jb/usr/lib -lfreetype"
fi

echo "CC=$CC"
echo "FT_CFLAGS=$FT_CFLAGS"
echo "FT_LIBS=$FT_LIBS"

PROBE_COMPILE_STATUS=99
PROBE_RUN_STATUS=99

if [ ! -x "$CC" ]; then
    echo "Clang not found."
elif [ -z "$SDK" ]; then
    echo "No usable iPhoneOS SDK found."
else
    echo
    echo "Compile command:"
    echo "$CC -target arm64-apple-ios16.0 -isysroot $SDK -miphoneos-version-min=16.0 $FT_CFLAGS freetype_probe.c $FT_LIBS"

    "$CC" \
        -target arm64-apple-ios16.0 \
        -isysroot "$SDK" \
        -miphoneos-version-min=16.0 \
        $FT_CFLAGS \
        "$WORK/freetype_probe.c" \
        $FT_LIBS \
        -o "$WORK/freetype_probe"

    PROBE_COMPILE_STATUS=$?
    echo "PROBE_COMPILE_STATUS=$PROBE_COMPILE_STATUS"

    if [ "$PROBE_COMPILE_STATUS" -eq 0 ]; then
        "$LDID" -S "$WORK/freetype_probe" 2>&1 || true

        file "$WORK/freetype_probe" 2>/dev/null || true
        otool -L "$WORK/freetype_probe" 2>/dev/null || true

        echo
        echo "Running probe:"

        DYLD_LIBRARY_PATH="/var/jb/usr/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
            "$WORK/freetype_probe"

        PROBE_RUN_STATUS=$?
        echo "PROBE_RUN_STATUS=$PROBE_RUN_STATUS"
    fi
fi

echo
echo "============================================================"

if [ "$PROBE_COMPILE_STATUS" -eq 0 ] &&
   [ "$PROBE_RUN_STATUS" -eq 0 ]; then
    echo "RESULT=FREETYPE_READY_FOR_WINE_REBUILD"
else
    echo "RESULT=FREETYPE_NOT_READY_OR_PROBE_FAILED"
fi

echo "LOG=$LOG"
echo "WORK=$WORK"
echo "NO_LIVE_WINE_RUNTIME_WAS_MODIFIED"
echo "============================================================"
