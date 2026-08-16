#!/usr/bin/env bash
set -euo pipefail

# Repeat the translated AMD64 smoke test against an installed Juice.app.  A
# single successful launch is not sufficient for a JIT/ARM64EC runtime: this
# runner keeps an individual log and marker snapshot for every attempt.
APP="${JUICE_INSTALLED_APP:-}"
PREFIX="${JUICE_X64_PREFIX:-/var/mobile/Documents/JuiceData/GrapePrefix-x86_64}"
PROOF_DIR="${JUICE_X64_REPEAT_PROOF_DIR:-/var/mobile/Documents/JuiceData/proofs/x86_64-repeat}"
ITERATIONS="${JUICE_X64_REPEAT_COUNT:-10}"

if test -z "$APP"; then
  newest_mtime=0
  while IFS= read -r candidate; do
    if test -f "$candidate/Grape-X64/tests/x86_64-smoke.exe"; then
      candidate_mtime="$(stat -f '%m' "$candidate" 2>/dev/null || echo 0)"
      if test "$candidate_mtime" -gt "$newest_mtime"; then
        APP="$candidate"
        newest_mtime="$candidate_mtime"
      fi
    fi
  done < <(find /var/containers/Bundle/Application -mindepth 2 -maxdepth 2 \
    -type d -name Juice.app -print 2>/dev/null | sort)
fi

test -n "$APP" || { echo "No installed Juice.app with an x86-64 smoke payload was found." >&2; exit 2; }
GRAPE="$APP/Grape-X64"
LOADER="$GRAPE/build/wine-ios/loader/wine"
SERVER="$GRAPE/build/wine-ios/server/wineserver"
TRACER="$GRAPE/tools/grape-trace-parent"
SMOKE="$GRAPE/tests/x86_64-smoke.exe"
PE="$GRAPE/runtime/lib/wine/aarch64-windows"
NATIVE="$GRAPE/build/wine-ios/dlls"
MARKER="$PROOF_DIR/current.ok"

for path in "$LOADER" "$SERVER" "$TRACER" "$SMOKE" "$PE/libarm64ecfex.dll"; do
  test -e "$path" || { echo "Missing x86-64 runtime input: $path" >&2; exit 2; }
done
case "$ITERATIONS" in
  ''|*[!0-9]*) echo "JUICE_X64_REPEAT_COUNT must be a positive integer." >&2; exit 2 ;;
  0) echo "JUICE_X64_REPEAT_COUNT must be greater than zero." >&2; exit 2 ;;
esac

mkdir -p "$PROOF_DIR" /var/mobile/Documents/JuiceData/tmp
rm -f "$PROOF_DIR"/attempt-*.ok "$PROOF_DIR"/attempt-*.log "$MARKER"

export TMPDIR=/var/mobile/Documents/JuiceData/tmp
export WINEPREFIX="$PREFIX"
export WINELOADER="$GRAPE/tools/grape-nested-wrapper"
export WINELOADERNOEXEC=1
export WINESERVER="$SERVER"
export WINEDLLPATH="$PE:$NATIVE/crypt32:$NATIVE/wineios.drv:$NATIVE/winevulkan:$NATIVE/win32u:$NATIVE/ws2_32"
export DYLD_LIBRARY_PATH="${DYLD_LIBRARY_PATH:-/var/jb/usr/lib}"
export JUICE_SKIP_WINEBOOT=1
export JUICE_WINESERVER_ROOT="${JUICE_WINESERVER_ROOT:-/var/mobile/Documents/JuiceData/wineserver}"
mkdir -p "$JUICE_WINESERVER_ROOT"
chmod 700 "$JUICE_WINESERVER_ROOT"
export JUICE_EXPERIMENTAL_X64=1
export JUICE_X64_SMOKE_HEADLESS=1
export JUICE_X64_MARKER_WINDOWS="Z:${MARKER//\//\\}"
export HODLL64=libarm64ecfex.dll
export WINEARCH=win64
export WINEDEBUG="${WINEDEBUG:--all}"
export PATH=/var/jb/usr/bin:/usr/bin:/bin

cleanup()
{
  "$SERVER" -k >/dev/null 2>&1 || true
}
trap cleanup EXIT

i=1
while test "$i" -le "$ITERATIONS"; do
  log="$PROOF_DIR/attempt-$i.log"
  snapshot="$PROOF_DIR/attempt-$i.ok"
  rm -f "$MARKER"
  "$SERVER" -k >/dev/null 2>&1 || true
  "$SERVER" -f >>"$log" 2>&1 &
  server_pid=$!
  sleep 1

  set +e
  timeout "${JUICE_X64_TIMEOUT_SECONDS:-45}" "$TRACER" "$LOADER" "$SMOKE" >>"$log" 2>&1
  status=$?
  set -e

  "$SERVER" -k >>"$log" 2>&1 || true
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true

  if test "$status" -eq 100 && test -s "$MARKER" && grep -Fq JUICE_X86_64_SMOKE_OK "$MARKER"; then
    cp "$MARKER" "$snapshot"
    printf 'JUICE_X86_64_REPEAT_ATTEMPT_OK attempt=%s status=%s log=%s\n' "$i" "$status" "$log"
  else
    printf 'JUICE_X86_64_REPEAT_ATTEMPT_FAILED attempt=%s status=%s log=%s\n' "$i" "$status" "$log" >&2
    exit 3
  fi
  i=$((i + 1))
done

sha256sum "$SMOKE" "$PE/libarm64ecfex.dll" "$PROOF_DIR"/attempt-*.ok
printf 'JUICE_X86_64_REPEAT_OK attempts=%s proof_dir=%s\n' "$ITERATIONS" "$PROOF_DIR"
