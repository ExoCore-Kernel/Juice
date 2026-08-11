#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
GRAPE="${JUICE_GRAPE_ROOT:-$ROOT/build/runtime-stage/Grape}"
PREFIX="${JUICE_TEST_PREFIX:-$ROOT/build/test-prefix}"
LOADER="$GRAPE/build/wine-ios/loader/wine"
SERVER="$GRAPE/build/wine-ios/server/wineserver"
TRACER="$GRAPE/tools/grape-trace-parent"
NATIVE="$GRAPE/build/wine-ios/dlls"
PE="$GRAPE/runtime/lib/wine/aarch64-windows"

test -x "$LOADER" || { echo "Missing Grape loader: $LOADER" >&2; exit 2; }
test -x "$SERVER" || { echo "Missing Grape wineserver: $SERVER" >&2; exit 2; }
test -x "$TRACER" || { echo "Missing Grape trace parent: $TRACER" >&2; exit 2; }
prefix_needs_initialization=0
if test ! -f "$PREFIX/.juice-prefix-ready"; then
  prefix_needs_initialization=1
fi
if test ! -f "$PREFIX/system.reg"; then
  mkdir -p "$(dirname "$PREFIX")"
  rsync -a "$GRAPE/prefix-template/" "$PREFIX/"
fi
mkdir -p "$PREFIX/dosdevices"
if test ! -e "$PREFIX/dosdevices/z:" && test ! -L "$PREFIX/dosdevices/z:"; then
  ln -s / "$PREFIX/dosdevices/z:"
fi
mkdir -p "$PREFIX/drive_c/windows/system32"
skip_wineboot="${JUICE_SKIP_WINEBOOT:-0}"
effective_skip_wineboot="$skip_wineboot"
# A completed prefix must not pay the full wineboot cost for every CLI
# process.  JUICE_FORCE_WINEBOOT=1 remains available for an intentional
# repair/update pass on an already initialized prefix.
if test "$prefix_needs_initialization" -eq 0 &&
   test "${JUICE_FORCE_WINEBOOT:-0}" != 1; then
  effective_skip_wineboot=1
fi
if test "$prefix_needs_initialization" -eq 0 ||
   { test -n "$skip_wineboot" && test "$skip_wineboot" != 0; }; then
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
else
  echo "JUICE_PREFIX_BOOTSTRAP mode=wineboot runtime_links=deferred prefix=$PREFIX"
fi

export TMPDIR="${TMPDIR:-/tmp}"
export WINEPREFIX="$PREFIX"
export WINELOADER="$GRAPE/tools/grape-nested-wrapper"
export WINESERVER="$SERVER"
export WINEDLLPATH="$PE:$NATIVE/crypt32:$NATIVE/wineios.drv:$NATIVE/win32u:$NATIVE/ws2_32"
export DYLD_LIBRARY_PATH="${DYLD_LIBRARY_PATH:-/var/jb/usr/lib}"
export WINEARCH=win64
export WINEDEBUG="${WINEDEBUG:--all}"
export JUICE_SKIP_WINEBOOT="$effective_skip_wineboot"
export PATH="/usr/bin:/bin:${PATH:-}"

"$SERVER" -f &
server_pid=$!
cleanup()
{
  # Ask the prefix's server to terminate every registered Wine client before
  # reaping the foreground server.  Service processes daemonize during
  # wineboot and otherwise survive short CLI smoke-test invocations on iOS.
  "$SERVER" -k 2>/dev/null || true
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT
sleep 1
"$TRACER" "$LOADER" "$@"
