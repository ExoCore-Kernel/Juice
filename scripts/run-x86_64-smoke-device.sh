#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
GRAPE="${JUICE_X64_GRAPE_ROOT:-$ROOT/build/x86_64-runtime-stage/Grape-X64}"
PREFIX="${JUICE_X64_PREFIX:-/var/mobile/Documents/JuiceData/GrapePrefix-x86_64}"
MARKER="${JUICE_X64_MARKER:-/var/mobile/Documents/Juice-x86_64-smoke.ok}"
LOG="${JUICE_X64_LOG:-/var/mobile/Documents/Juice-x86_64-smoke.log}"
SOCKET="${JUICE_IOS_SOCKET:-/var/mobile/Documents/JuiceData/juice.sock}"
LOADER="$GRAPE/build/wine-ios/loader/wine"
SERVER="$GRAPE/build/wine-ios/server/wineserver"
TRACER="$GRAPE/tools/grape-trace-parent"
PE="$GRAPE/runtime/lib/wine/aarch64-windows"
NATIVE="$GRAPE/build/wine-ios/dlls"
SMOKE="$GRAPE/tests/x86_64-smoke.exe"

test "$(uname -s)" = Darwin || { echo "This smoke runner must execute on the iPad." >&2; exit 2; }
for path in "$LOADER" "$SERVER" "$TRACER" "$SMOKE"; do
  test -e "$path" || { echo "Missing x86-64 smoke dependency: $path" >&2; exit 2; }
done
if test ! -f "$PREFIX/system.reg"; then
  mkdir -p "$(dirname "$PREFIX")"
  rsync -a "$GRAPE/prefix-template/" "$PREFIX/"
fi
mkdir -p "$PREFIX/dosdevices" /var/mobile/Documents/JuiceData/tmp
if test ! -e "$PREFIX/dosdevices/z:" && test ! -L "$PREFIX/dosdevices/z:"; then
  ln -s / "$PREFIX/dosdevices/z:"
fi
mkdir -p "$PREFIX/drive_c/windows/system32"
for module in "$PE"/*.dll "$PE"/*.exe "$PE"/*.drv; do
  test -f "$module" || continue
  destination="$PREFIX/drive_c/windows/system32/$(basename "$module")"
  case "$(basename "$module")" in
    JuiceGUI.exe|JuiceTextSmoke.exe|winemine.exe|x86_64-smoke.exe)
      if test -e "$destination" || test -L "$destination"; then
        rm -f "$destination"
      fi
      ln -s "$module" "$destination"
      ;;
  *) if test -L "$destination"; then
    ln -sfn "$module" "$destination"
  elif test ! -e "$destination"; then
    ln -s "$module" "$destination"
  fi ;;
  esac
done
rm -f "$MARKER"
case "$MARKER" in
  /*) export JUICE_X64_MARKER_WINDOWS="Z:${MARKER//\//\\}" ;;
  *) echo "JUICE_X64_MARKER must be an absolute Unix path: $MARKER" >&2; exit 2 ;;
esac

export HOME=/var/mobile
export TMPDIR=/var/mobile/Documents/JuiceData/tmp
export WINEPREFIX="$PREFIX"
export WINELOADER="$GRAPE/tools/grape-nested-wrapper"
export WINESERVER="$SERVER"
export WINEDLLPATH="$PE:$NATIVE/crypt32:$NATIVE/wineios.drv:$NATIVE/win32u:$NATIVE/ws2_32"
export DYLD_LIBRARY_PATH="${DYLD_LIBRARY_PATH:-/var/jb/usr/lib}"
export JUICE_IOS_SOCKET="$SOCKET"
# This runner verifies the translator, not prefix initialization.  Keep the
# Wineboot policy overrideable so a caller can exercise initialization with
# JUICE_SKIP_WINEBOOT=0, while the normal smoke reaches the x86-64 payload
# directly against the checked-in prefix template.
export JUICE_SKIP_WINEBOOT="${JUICE_SKIP_WINEBOOT:-1}"
export JUICE_EXPERIMENTAL_X64=1
if test "${JUICE_X64_SMOKE_HEADLESS:-1}" = 1; then
  export JUICE_X64_SMOKE_HEADLESS=1
else
  unset JUICE_X64_SMOKE_HEADLESS
fi
export HODLL64=libarm64ecfex.dll
export WINEARCH=win64
export WINEDEBUG="${WINEDEBUG:--all}"
export PATH="/var/jb/usr/bin:/usr/bin:/bin"

"$SERVER" -f >>"$LOG" 2>&1 &
server_pid=$!
cleanup()
{
  "$SERVER" -k >/dev/null 2>&1 || true
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT
sleep 1
set +e
timeout "${JUICE_X64_TIMEOUT_SECONDS:-45}" "$TRACER" "$LOADER" "$SMOKE" >>"$LOG" 2>&1
status=$?
set -e
test -s "$MARKER" || {
  echo "X86_64_SMOKE_FAILED status=$status marker=$MARKER log=$LOG" >&2
  exit 3
}
grep -Fq "JUICE_X86_64_SMOKE_OK" "$MARKER"
sha256sum "$SMOKE" "$PE/libarm64ecfex.dll" "$MARKER"
echo "JUICE_X86_64_DEVICE_SMOKE_OK status=$status marker=$MARKER log=$LOG"
