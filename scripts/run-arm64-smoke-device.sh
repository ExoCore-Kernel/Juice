#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
GRAPE="${JUICE_GRAPE_ROOT:-$ROOT/build/runtime-stage/Grape}"
PREFIX="${JUICE_ARM64_PREFIX:-/var/mobile/Documents/JuiceData/GrapePrefix-arm64-smoke}"
MARKER="${JUICE_ARM64_MARKER:-/var/mobile/Documents/Juice-arm64-smoke.ok}"
LOG="${JUICE_ARM64_LOG:-/var/mobile/Documents/Juice-arm64-smoke.log}"
HOME_DIR="${JUICE_ARM64_HOME:-/var/mobile/Documents/JuiceData/arm64-smoke-home}"
TMP_DIR="${JUICE_ARM64_TMP:-/var/mobile/Documents/JuiceData/arm64-smoke-tmp}"
LOADER="$GRAPE/build/wine-ios/loader/wine"
SERVER="$GRAPE/build/wine-ios/server/wineserver"
TRACER="$GRAPE/tools/grape-trace-parent"
PE="$GRAPE/runtime/lib/wine/aarch64-windows"
CMD="$PE/cmd.exe"
TIMEOUT="${JUICE_TIMEOUT_BIN:-$(command -v timeout)}"
ENV_BIN="${JUICE_ENV_BIN:-$(command -v env)}"

test "$(uname -s)" = Darwin || { echo "This smoke runner must execute on the iPad." >&2; exit 2; }
for path in "$LOADER" "$SERVER" "$TRACER" "$CMD" "$PE/ntdll.dll"; do
  test -e "$path" || { echo "Missing ARM64 smoke dependency: $path" >&2; exit 2; }
done
if test ! -f "$PREFIX/system.reg"; then
  mkdir -p "$(dirname "$PREFIX")"
  rsync -a "$GRAPE/prefix-template/" "$PREFIX/"
fi
mkdir -p "$PREFIX/dosdevices" "$HOME_DIR" "$TMP_DIR"
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
case "$MARKER" in
  /*) MARKER_WINDOWS="Z:${MARKER//\//\\}" ;;
  *) echo "JUICE_ARM64_MARKER must be an absolute Unix path: $MARKER" >&2; exit 2 ;;
esac
rm -f "$MARKER"
: >"$LOG"

RUN_ENV=(
  "$ENV_BIN" -i
  "HOME=$HOME_DIR" "USER=mobile" "LOGNAME=mobile"
  "TMPDIR=$TMP_DIR" "LANG=C" "LC_ALL=C"
  "PATH=/var/jb/usr/bin:/usr/bin:/bin"
  "WINEPREFIX=$PREFIX" "WINEARCH=win64" "WINEDEBUG=${WINEDEBUG:--all}"
  "WINELOADER=$LOADER" "WINESERVER=$SERVER" "WINEDLLPATH=$PE"
  "DYLD_LIBRARY_PATH=${DYLD_LIBRARY_PATH:-/var/jb/usr/lib}"
  "JUICE_SKIP_WINEBOOT=${JUICE_SKIP_WINEBOOT:-1}"
)
if test -n "${JUICE_EXPERIMENTAL_X64:-}"; then
  RUN_ENV+=("JUICE_EXPERIMENTAL_X64=$JUICE_EXPERIMENTAL_X64")
fi

"${RUN_ENV[@]}" "$SERVER" -f >>"$LOG" 2>&1 &
server_pid=$!
cleanup()
{
  "${RUN_ENV[@]}" "$SERVER" -k >/dev/null 2>&1 || true
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT
sleep 1
set +e
(
  cd "$PE"
  "${RUN_ENV[@]}" "$TIMEOUT" "${JUICE_ARM64_TIMEOUT_SECONDS:-60}" \
    "$TRACER" "$LOADER" "$CMD" /d /c \
    "echo JUICE_ARM64_SMOKE_OK> $MARKER_WINDOWS"
) >>"$LOG" 2>&1
status=$?
set -e

test "$status" -eq 0 || {
  echo "ARM64_SMOKE_FAILED status=$status marker=$MARKER log=$LOG" >&2
  exit 3
}
grep -Fq "JUICE_ARM64_SMOKE_OK" "$MARKER"
sha256sum "$CMD" "$GRAPE/build/wine-ios/dlls/ntdll/ntdll.so" "$PE/ntdll.dll" "$MARKER"
echo "JUICE_ARM64_DEVICE_SMOKE_OK status=$status marker=$MARKER log=$LOG"
