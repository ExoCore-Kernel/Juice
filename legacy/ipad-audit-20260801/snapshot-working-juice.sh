#!/var/jb/usr/bin/bash
set -u
set -o pipefail

J=/var/jb/var/mobile/Juice
S="$J/src/wine-11.13"
B="$J/build/wine-ios"
OUTROOT=/var/mobile/Documents/Juice-Success-Backups
STAMP=$(date +%Y%m%d-%H%M%S)
META="$J/success-snapshot-$STAMP"
BASE="Juice-WORKING-$STAMP"

mkdir -p "$OUTROOT" "$META"

echo "=== Stopping Wine for a consistent snapshot ==="
export WINEPREFIX="$J/prefixes/arm64-test"
"$B/server/wineserver" -k >/dev/null 2>&1 || true
sleep 1

echo "=== Recording the confirmed working state ==="
{
    echo "SNAPSHOT_TIME=$(date)"
    echo "JUICE_ROOT=$J"
    echo "HOST=$(uname -a 2>/dev/null || true)"
    echo "WORKING_TEST=CMD_STATUS_0_AND_JUICE_REAL_OK"
    echo "MATCHED_MODULES_INSTALLED=373"
    echo "KNOWN_GOOD_BACKUP=$J/backups/matched-core-20260715-163808"
} >"$META/README-WORKING-STATE.txt"

df -h "$OUTROOT" >"$META/disk-free-before.txt" 2>&1 || true
du -sh "$J" >"$META/juice-size.txt" 2>&1 || true
find "$J" -xdev -print >"$META/full-file-list.txt" 2>/dev/null || true

if command -v git >/dev/null 2>&1 && [ -d "$S/.git" ]; then
    git -C "$S" rev-parse HEAD \
        >"$META/wine-source-commit.txt" 2>&1 || true
    git -C "$S" status --short \
        >"$META/wine-source-status.txt" 2>&1 || true
    git -C "$S" diff --binary \
        >"$META/wine-source-working-tree.patch" 2>&1 || true
    git -C "$S" diff --binary --cached \
        >"$META/wine-source-index.patch" 2>&1 || true
fi

if command -v dpkg >/dev/null 2>&1; then
    dpkg -l >"$META/installed-packages.txt" 2>&1 || true
fi

if command -v clang >/dev/null 2>&1; then
    clang --version >"$META/clang-version.txt" 2>&1 || true
fi

hash_file()
{
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$@"
    else
        shasum -a 256 "$@"
    fi
}

CRITICAL="$META/critical-files.txt"

for F in \
    "$B/loader/wine" \
    "$B/server/wineserver" \
    "$B/dlls/ntdll/ntdll.so" \
    "$J/tools/juice-wine-trace-parent" \
    "$J/runtime/lib/wine/aarch64-windows/ntdll.dll" \
    "$J/runtime/lib/wine/aarch64-windows/kernelbase.dll" \
    "$J/runtime/lib/wine/aarch64-windows/kernel32.dll" \
    "$J/runtime/lib/wine/aarch64-windows/ucrtbase.dll" \
    "$J/runtime/lib/wine/aarch64-windows/cmd.exe" \
    "$B/nls/locale.nls" \
    "$B/nls/l_intl.nls"
do
    if [ -e "$F" ]; then
        file "$F" >>"$CRITICAL" 2>&1 || true
        ls -l "$F" >>"$CRITICAL" 2>&1 || true
        [ -f "$F" ] && \
            hash_file "$F" >>"$META/critical-files.sha256"
    else
        echo "MISSING=$F" >>"$CRITICAL"
    fi
done

if command -v ldid >/dev/null 2>&1; then
    for F in \
        "$B/loader/wine" \
        "$B/server/wineserver" \
        "$J/tools/juice-wine-trace-parent"
    do
        [ -f "$F" ] || continue
        NAME=${F##*/}
        ldid -e "$F" \
            >"$META/$NAME.entitlements.plist" 2>/dev/null || true
    done
fi

echo "=== Storage information ==="
du -sh "$J" || true
df -h "$OUTROOT" || true

cd /var/jb/var/mobile || exit 20

if command -v zstd >/dev/null 2>&1; then
    ARCHIVE="$OUTROOT/$BASE.tar.zst"
    PART="$ARCHIVE.partial"

    echo "=== Creating complete Zstandard archive ==="
    tar -cpf - Juice | zstd -T0 -10 -o "$PART"
    RC=$?

    [ "$RC" -eq 0 ] || {
        echo "ERROR: archive creation failed: $RC"
        exit 21
    }

    mv "$PART" "$ARCHIVE"

    echo "=== Verifying compressed archive ==="
    zstd -t "$ARCHIVE" || exit 22
    zstd -dc "$ARCHIVE" | tar -tf - >/dev/null || exit 23

elif command -v gzip >/dev/null 2>&1; then
    ARCHIVE="$OUTROOT/$BASE.tar.gz"
    PART="$ARCHIVE.partial"

    echo "=== Creating complete gzip archive ==="
    tar -cpf - Juice | gzip -6 >"$PART"
    RC=$?

    [ "$RC" -eq 0 ] || {
        echo "ERROR: archive creation failed: $RC"
        exit 24
    }

    mv "$PART" "$ARCHIVE"

    echo "=== Verifying compressed archive ==="
    gzip -t "$ARCHIVE" || exit 25
    gzip -dc "$ARCHIVE" | tar -tf - >/dev/null || exit 26

else
    ARCHIVE="$OUTROOT/$BASE.tar"
    PART="$ARCHIVE.partial"

    echo "=== Creating complete uncompressed archive ==="
    tar -cpf "$PART" Juice || exit 27
    mv "$PART" "$ARCHIVE"
    tar -tf "$ARCHIVE" >/dev/null || exit 28
fi

echo "=== Writing SHA-256 checksum ==="
hash_file "$ARCHIVE" >"$ARCHIVE.sha256" || exit 29
sync

echo "=== SUCCESS SNAPSHOT COMPLETE ==="
ls -lh "$ARCHIVE" "$ARCHIVE.sha256"
cat "$ARCHIVE.sha256"

echo "RESULT=FULL_WORKING_JUICE_SNAPSHOT_VERIFIED"
echo "ARCHIVE=$ARCHIVE"
echo "CHECKSUM=$ARCHIVE.sha256"
echo "COPY BOTH FILES OFF THE IPAD AS SOON AS POSSIBLE"
