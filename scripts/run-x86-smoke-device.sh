#!/usr/bin/env bash
set -euo pipefail

# Verify the optional PE32 path against an installed Juice.app. The workload
# is real i386 Windows code; Wine's modern WoW64 layer delegates guest CPU
# execution to FEX's libwow64fex.dll while the host remains 64-bit ARM64.
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
APP="${JUICE_INSTALLED_APP:-}"
PREFIX="${JUICE_X64_PREFIX:-/var/mobile/Documents/JuiceData/GrapePrefix-x86_64}"
PROOF_DIR="${JUICE_X86_PROOF_DIR:-/var/mobile/Documents/JuiceData/proofs/x86}"
RUNNER="${JUICE_GRAPE_CLI_RUNNER:-$SCRIPT_DIR/run-grape-cli-device.sh}"
MARKER="$PROOF_DIR/marker.txt"
LOG="$PROOF_DIR/device.log"

if test -z "$APP"; then
  newest_mtime=0
  while IFS= read -r candidate; do
    test -f "$candidate/Grape-X64/tests/x86-smoke.exe" || continue
    candidate_mtime="$(stat -c '%Y' "$candidate" 2>/dev/null || \
      stat -f '%m' "$candidate" 2>/dev/null || echo 0)"
    if test "$candidate_mtime" -gt "$newest_mtime"; then
      APP="$candidate"
      newest_mtime="$candidate_mtime"
    fi
  done < <(find /var/containers/Bundle/Application -mindepth 2 -maxdepth 2 \
    -type d -name Juice.app -print 2>/dev/null | sort)
fi

test -n "$APP" || { echo "No installed Juice.app with Legacy Win32 was found." >&2; exit 2; }
GRAPE="$APP/Grape-X64"
SMOKE="$GRAPE/tests/x86-smoke.exe"
PE="$GRAPE/runtime/lib/wine/aarch64-windows"
PE_I386="$GRAPE/runtime/lib/wine/i386-windows"
for path in "$RUNNER" "$SMOKE" "$PE/libwow64fex.dll" "$PE/wow64.dll" \
  "$PE/wow64win.dll" "$PE_I386/ntdll.dll"; do
  test -s "$path" || { echo "Missing Legacy Win32 runtime input: $path" >&2; exit 2; }
done

mkdir -p "$PROOF_DIR"
rm -f "$MARKER" "$LOG" "$PROOF_DIR/result.env" "$PROOF_DIR/SHA256SUMS"
export JUICE_GRAPE_ROOT="$GRAPE"
export JUICE_TEST_PREFIX="$PREFIX"
export JUICE_EXPERIMENTAL_WIN32=1
export JUICE_X86_SMOKE_HEADLESS=1
export JUICE_X86_MARKER_WINDOWS="Z:${MARKER//\//\\}"
export JUICE_SKIP_WINEBOOT=1
export WINEDEBUG="${WINEDEBUG:--all}"

set +e
timeout "${JUICE_X86_TIMEOUT_SECONDS:-90}" bash "$RUNNER" "$SMOKE" >"$LOG" 2>&1
status=$?
set -e

printf 'mode=x86\nstatus=%s\napp=%s\ngrape=%s\nprefix=%s\n' \
  "$status" "$APP" "$GRAPE" "$PREFIX" >"$PROOF_DIR/result.env"
sha256sum "$SMOKE" "$PE/libwow64fex.dll" "$PE/wow64.dll" \
  "$PE/wow64win.dll" "$PE_I386/ntdll.dll" \
  >"$PROOF_DIR/SHA256SUMS"

if test "$status" -eq 100 && test -s "$MARKER" &&
   grep -Fq JUICE_X86_SMOKE_OK "$MARKER"; then
  echo "JUICE_X86_DEVICE_SMOKE_OK status=$status proof_dir=$PROOF_DIR"
  exit 0
fi

echo "JUICE_X86_DEVICE_SMOKE_FAILED status=$status proof_dir=$PROOF_DIR" >&2
tail -n 120 "$LOG" >&2 || true
exit 3
