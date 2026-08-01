#!/var/jb/usr/bin/bash

set -u
umask 022

# Survive SSH disconnection.
trap '' HUP

BUILD="$HOME/Juice/build/wine-arm64-pe"
RUNTIME="$HOME/Juice/Runtime/windows-arm64"
SYSTEM32="$RUNTIME/system32"
LOG_ROOT="$HOME/Juice/logs/wine-dll-builds"
STAMP="$(date '+%Y%m%d-%H%M%S')"
RUN="$LOG_ROOT/$STAMP"

MASTER="$RUN/master.log"
SUMMARY="$RUN/results.tsv"
ALL_TARGETS="$RUN/all-targets.txt"
TARGETS="$RUN/ordered-targets.txt"

export PATH="$HOME/Juice/toolchain/bin:/var/jb/usr/bin:/var/jb/usr/sbin:$PATH"
export LC_ALL=C
export LANG=C
export MAKEFLAGS=

mkdir -p "$RUN" "$SYSTEM32"
printf '%s\n' "$RUN" > "$HOME/Juice/logs/wine-dll-current.txt"

log()
{
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" |
        tee -a "$MASTER"
}

finish_interrupted()
{
    log "Build process interrupted."
    touch "$RUN/INTERRUPTED"
    exit 130
}

trap finish_interrupted INT TERM

cd "$BUILD" || {
    echo "Build directory not found: $BUILD"
    exit 1
}

if [ ! -f Makefile ]; then
    echo "Makefile not found in $BUILD"
    exit 1
fi

# Find every generated ARM64 Windows DLL target.
grep -Eo \
    'dlls/[A-Za-z0-9_.+-]+/aarch64-windows/[A-Za-z0-9_.+-]+\.dll' \
    Makefile |
sort -u > "$ALL_TARGETS"

if [ ! -s "$ALL_TARGETS" ]; then
    log "ERROR: No ARM64 Windows DLL targets were found."
    exit 1
fi

# Build important runtime DLLs first, then everything else.
{
    for target in \
        dlls/ntdll/aarch64-windows/ntdll.dll \
        dlls/kernelbase/aarch64-windows/kernelbase.dll \
        dlls/kernel32/aarch64-windows/kernel32.dll \
        dlls/advapi32/aarch64-windows/advapi32.dll \
        dlls/msvcrt/aarch64-windows/msvcrt.dll \
        dlls/ucrtbase/aarch64-windows/ucrtbase.dll \
        dlls/rpcrt4/aarch64-windows/rpcrt4.dll \
        dlls/combase/aarch64-windows/combase.dll \
        dlls/ole32/aarch64-windows/ole32.dll \
        dlls/gdi32/aarch64-windows/gdi32.dll \
        dlls/user32/aarch64-windows/user32.dll \
        dlls/shell32/aarch64-windows/shell32.dll
    do
        if grep -Fxq "$target" "$ALL_TARGETS"; then
            printf '%s\n' "$target"
        fi
    done

    cat "$ALL_TARGETS"
} |
awk '!seen[$0]++' > "$TARGETS"

TOTAL="$(wc -l < "$TARGETS" | tr -d ' ')"

printf 'STATUS\tTARGET\tBYTES\tSECONDS\tLOG\n' > "$SUMMARY"

log "Wine ARM64 DLL build started."
log "Build directory: $BUILD"
log "Runtime directory: $SYSTEM32"
log "Targets found: $TOTAL"
log "PID: $$"

INDEX=0

while IFS= read -r target
do
    [ -n "$target" ] || continue

    INDEX=$((INDEX + 1))

    # Leave enough space for iOS and package/database operations.
    FREE_KB="$(
        df -Pk "$BUILD" 2>/dev/null |
        awk 'NR == 2 {print $4}'
    )"

    case "$FREE_KB" in
        ''|*[!0-9]*)
            FREE_KB=999999999
            ;;
    esac

    if [ "$FREE_KB" -lt 204800 ]; then
        log "STOPPING: less than 200 MB free space remains."
        printf 'STOP_LOW_SPACE\t%s\t0\t0\t%s\n' \
            "$target" "$MASTER" >> "$SUMMARY"
        touch "$RUN/STOPPED_LOW_SPACE"
        break
    fi

    SAFE_NAME="$(
        printf '%s' "$target" |
        tr '/:' '__'
    )"

    TARGET_LOG="$RUN/$SAFE_NAME.log"
    START_TIME="$(date +%s)"

    log "[$INDEX/$TOTAL] Building $target"
    log "Free space: $((FREE_KB / 1024)) MB"

    if make -j1 \
        SHELL=/var/jb/usr/bin/sh \
        V=1 \
        "$target" \
        >"$TARGET_LOG" 2>&1
    then
        END_TIME="$(date +%s)"
        ELAPSED=$((END_TIME - START_TIME))

        if [ -f "$target" ]; then
            BYTES="$(wc -c < "$target" | tr -d ' ')"
            DEST="$SYSTEM32/$(basename "$target")"

            rm -f "$DEST"

            # Hard link saves space. Copy only when linking is unavailable.
            if ! ln "$target" "$DEST" 2>/dev/null; then
                cp -f "$target" "$DEST"
            fi

            log "SUCCESS: $target"
            log "Saved as: $DEST"
            log "Size: $BYTES bytes; time: ${ELAPSED}s"

            printf 'OK\t%s\t%s\t%s\t%s\n' \
                "$target" "$BYTES" "$ELAPSED" "$TARGET_LOG" \
                >> "$SUMMARY"
        else
            log "FAILED: make returned success but the DLL is missing."

            printf 'MISSING\t%s\t0\t%s\t%s\n' \
                "$target" "$ELAPSED" "$TARGET_LOG" \
                >> "$SUMMARY"
        fi
    else
        END_TIME="$(date +%s)"
        ELAPSED=$((END_TIME - START_TIME))

        log "FAILED: $target"
        log "Continuing to the next DLL."
        log "Failure log: $TARGET_LOG"

        printf 'FAILED\t%s\t0\t%s\t%s\n' \
            "$target" "$ELAPSED" "$TARGET_LOG" \
            >> "$SUMMARY"
    fi

    # Compress individual logs to conserve storage.
    if command -v gzip >/dev/null 2>&1 && [ -f "$TARGET_LOG" ]; then
        gzip -f "$TARGET_LOG"
        sed -i "s|$TARGET_LOG|$TARGET_LOG.gz|" "$SUMMARY"
    fi
done < "$TARGETS"

OK_COUNT="$(
    awk -F '\t' '$1 == "OK" {count++} END {print count + 0}' "$SUMMARY"
)"

FAIL_COUNT="$(
    awk -F '\t' '$1 == "FAILED" || $1 == "MISSING" {count++} END {print count + 0}' "$SUMMARY"
)"

log "Build run finished."
log "Successful DLLs: $OK_COUNT"
log "Failed DLLs: $FAIL_COUNT"
log "Summary: $SUMMARY"
log "Runtime DLLs: $SYSTEM32"

touch "$RUN/DONE"
