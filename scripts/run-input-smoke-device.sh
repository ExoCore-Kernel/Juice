#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
GRAPE="${JUICE_GRAPE_ROOT:-$ROOT/build/runtime-stage/Grape}"
PREFIX="${JUICE_INPUT_PREFIX:-/var/mobile/Documents/JuiceData/GrapePrefix-input-v1}"
OUTPUT="${JUICE_INPUT_OUTPUT:-$ROOT/build/tests/input-v1}"
SMOKE="${JUICE_INPUT_SMOKE:-$ROOT/build/input-smoke.exe}"
SOCKET="${JUICE_INPUT_SOCKET:-/tmp/juice-input-v1.sock}"
STATE="${JUICE_GAMEPAD_STATE_UNIX:-/var/mobile/Documents/JuiceData/controller-input-smoke-v1.bin}"
PE="$GRAPE/runtime/lib/wine/aarch64-windows"
LOADER="$GRAPE/build/wine-ios/loader/wine"
SERVER="$GRAPE/build/wine-ios/server/wineserver"
TRACER="$GRAPE/tools/grape-trace-parent"
NESTED="$GRAPE/tools/grape-nested-wrapper"
KEY_MARKER="/var/mobile/Documents/Juice-HardwareKeyboard.ok"
PAD_MARKER="/var/mobile/Documents/Juice-GameController-XInput.ok"
DONE_MARKER="/var/mobile/Documents/Juice-ExternalInput.ok"

test "$(uname -s)" = Darwin || { echo "This smoke test must run on the iPad." >&2; exit 2; }
for path in "$LOADER" "$SERVER" "$TRACER" "$NESTED" "$SMOKE" "$PE/xinput1_4.dll" \
  "$GRAPE/build/wine-ios/dlls/wineios.drv/wineios.so"; do
  test -s "$path" || { echo "Missing external-input dependency: $path" >&2; exit 2; }
done
mkdir -p "$OUTPUT" "$(dirname "$PREFIX")"
exec > >(tee "$OUTPUT/execution.log") 2>&1

if test ! -f "$PREFIX/system.reg"; then
  mkdir -p "$PREFIX"
  rsync -a "$GRAPE/prefix-template/" "$PREFIX/"
fi
mkdir -p "$PREFIX/dosdevices" "$PREFIX/drive_c/windows/system32" \
  "$OUTPUT/home" "$OUTPUT/tmp"
if test ! -e "$PREFIX/dosdevices/z:" && test ! -L "$PREFIX/dosdevices/z:"; then
  ln -s / "$PREFIX/dosdevices/z:"
fi
for module in "$PE"/*.dll "$PE"/*.exe "$PE"/*.drv; do
  test -f "$module" || continue
  destination="$PREFIX/drive_c/windows/system32/$(basename "$module")"
  if test -L "$destination"; then
    ln -sfn "$module" "$destination"
  elif test ! -e "$destination"; then
    ln -s "$module" "$destination"
  fi
done
rm -f "$KEY_MARKER" "$PAD_MARKER" "$DONE_MARKER"

export USER=mobile LOGNAME=mobile
export PATH="/var/jb/usr/bin:/usr/bin:/bin"
export TMPDIR="$OUTPUT/tmp"
export WINEPREFIX="$PREFIX" WINEARCH=win64
export WINELOADER="$NESTED" WINESERVER="$SERVER"
export WINEDLLPATH="$PE:$GRAPE/build/wine-ios/dlls/crypt32:$GRAPE/build/wine-ios/dlls/wineios.drv:$GRAPE/build/wine-ios/dlls/win32u:$GRAPE/build/wine-ios/dlls/ws2_32"
export DYLD_LIBRARY_PATH="${DYLD_LIBRARY_PATH:-/var/jb/usr/lib}"
export JUICE_SKIP_WINEBOOT=1
export WINEDEBUG="${WINEDEBUG:-+iosdrv,+xinput}"

"$SERVER" -f >>"$OUTPUT/wineserver.log" 2>&1 &
server_pid=$!
cleanup()
{
  "$SERVER" -k >/dev/null 2>&1 || true
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT
sleep 1

python3 "$ROOT/scripts/run-gui-text-smoke-device.py" \
  --socket "$SOCKET" --marker "$DONE_MARKER" --output-dir "$OUTPUT" \
  --hardware-key --no-text --click 120,120 --gamepad-state "$STATE" \
  --timeout "${JUICE_INPUT_TIMEOUT:-45}" --settle 1.0 -- \
  "$TRACER" "$LOADER" "$SMOKE"

grep -Fq 'JUICE_HARDWARE_KEYBOARD_OK' "$KEY_MARKER"
grep -Fq 'JUICE_GAMECONTROLLER_XINPUT_OK' "$PAD_MARKER"
grep -Fq 'JUICE_EXTERNAL_INPUT_OK' "$DONE_MARKER"
cp "$KEY_MARKER" "$PAD_MARKER" "$DONE_MARKER" "$OUTPUT/"
sha256sum "$OUTPUT"/frame-before-input.png "$OUTPUT"/frame-after-input.png \
  "$OUTPUT/Juice-HardwareKeyboard.ok" "$OUTPUT/Juice-GameController-XInput.ok" \
  "$OUTPUT/Juice-ExternalInput.ok" >"$OUTPUT/SHA256SUMS"
echo "JUICE_EXTERNAL_INPUT_DEVICE_OK output=$OUTPUT"
