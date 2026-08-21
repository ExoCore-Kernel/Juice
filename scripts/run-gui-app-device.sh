#!/usr/bin/env bash
set -euo pipefail

# Run an arbitrary Windows GUI executable through Grape while a small
# framebuffer host records proof that wineios.drv produced a visible window.
# This script intentionally contains no application-specific behaviour.

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ARCH="${1:-}"
PROOF_DIR="${2:-}"
EXECUTABLE="${3:-}"
if test "$#" -lt 3; then
  echo "usage: $0 arm64|x86_64|i386 PROOF_DIR EXECUTABLE [ARG ...]" >&2
  exit 2
fi
shift 3

APP="${JUICE_INSTALLED_APP:-}"
DATA_ROOT="${JUICE_DATA_ROOT:-/var/mobile/Documents/JuiceData}"
RUNNER="${JUICE_GRAPE_CLI_RUNNER:-$SCRIPT_DIR/run-grape-cli-device.sh}"
DISPLAY_HOST="${JUICE_GUI_DISPLAY_HOST:-$SCRIPT_DIR/run-gui-text-smoke-device.py}"
SHELL_COMMAND="${JUICE_DEVICE_SHELL:-$(command -v sh 2>/dev/null || command -v zsh 2>/dev/null || true)}"

if test -z "$APP"; then
  newest_mtime=0
  while IFS= read -r candidate; do
    test -x "$candidate/Grape/build/wine-ios/loader/wine" || continue
    candidate_mtime="$(stat -c '%Y' "$candidate" 2>/dev/null || \
      stat -f '%m' "$candidate" 2>/dev/null || echo 0)"
    if test "$candidate_mtime" -gt "$newest_mtime"; then
      APP="$candidate"
      newest_mtime="$candidate_mtime"
    fi
  done < <(find /var/containers/Bundle/Application -mindepth 2 -maxdepth 2 \
    -type d -name Juice.app -print 2>/dev/null | sort)
fi
test -n "$APP" || { echo "No installed Juice.app was found." >&2; exit 2; }
test -s "$EXECUTABLE" || { echo "Missing executable: $EXECUTABLE" >&2; exit 2; }
test -x "$RUNNER" || { echo "Missing Grape runner: $RUNNER" >&2; exit 2; }
test -f "$DISPLAY_HOST" || { echo "Missing display host: $DISPLAY_HOST" >&2; exit 2; }
test -x "$SHELL_COMMAND" || { echo "No executable device shell was found." >&2; exit 2; }

case "$ARCH" in
  arm64)
    GRAPE="$APP/Grape"
    PREFIX="${JUICE_GUI_APP_PREFIX:-$DATA_ROOT/GrapePrefix-apps-arm64}"
    unset JUICE_EXPERIMENTAL_X64 JUICE_EXPERIMENTAL_WIN32
    ;;
  x86_64)
    GRAPE="$APP/Grape-X64"
    PREFIX="${JUICE_GUI_APP_PREFIX:-$DATA_ROOT/GrapePrefix-apps-x86_64}"
    export JUICE_EXPERIMENTAL_X64=1
    unset JUICE_EXPERIMENTAL_WIN32
    ;;
  i386)
    GRAPE="$APP/Grape-X64"
    PREFIX="${JUICE_GUI_APP_PREFIX:-$DATA_ROOT/GrapePrefix-apps-i386}"
    export JUICE_EXPERIMENTAL_WIN32=1
    ;;
  *) echo "Unknown executable architecture: $ARCH" >&2; exit 2 ;;
esac

mkdir -p "$PROOF_DIR"
MARKER="$PROOF_DIR/process-started.marker"
SOCKET="$PROOF_DIR/display.sock"
LOG="$PROOF_DIR/device.log"
rm -f "$MARKER" "$SOCKET" "$LOG" "$PROOF_DIR/result.env" \
  "$PROOF_DIR/frame-before-input.png" "$PROOF_DIR/frame-after-input.png" \
  "$PROOF_DIR/expected-window-frame.png" "$PROOF_DIR/SHA256SUMS"

export JUICE_INSTALLED_APP="$APP"
export JUICE_GRAPE_ROOT="$GRAPE"
export JUICE_TEST_PREFIX="$PREFIX"
export JUICE_SKIP_WINEBOOT="${JUICE_GUI_APP_SKIP_WINEBOOT:-0}"
export WINEDEBUG="${WINEDEBUG:-warn+all,+module,+seh,+wineiosdrv}"

host_args=(
  --socket "$SOCKET"
  --marker "$MARKER"
  --output-dir "$PROOF_DIR"
  --no-input
  --no-text
  --timeout "${JUICE_GUI_APP_TIMEOUT_SECONDS:-90}"
  --settle "${JUICE_GUI_APP_SETTLE_SECONDS:-2}"
  --min-width "${JUICE_GUI_APP_MIN_WIDTH:-300}"
  --max-width "${JUICE_GUI_APP_MAX_WIDTH:-1000}"
  --min-height "${JUICE_GUI_APP_MIN_HEIGHT:-180}"
  --max-height "${JUICE_GUI_APP_MAX_HEIGHT:-749}"
)

set +e
(
  cd "$(dirname "$EXECUTABLE")"
  python3 "$DISPLAY_HOST" "${host_args[@]}" -- \
    "$SHELL_COMMAND" -c 'marker=$1; shift; : > "$marker"; exec "$@"' \
    juice-gui-proof "$MARKER" "$RUNNER" "$EXECUTABLE" "$@"
) >"$LOG" 2>&1
status=$?
set -e

frame="$PROOF_DIR/frame-after-input.png"
printf 'architecture=%s\nstatus=%s\napp=%s\ngrape=%s\nprefix=%s\nexecutable=%s\nframe=%s\n' \
  "$ARCH" "$status" "$APP" "$GRAPE" "$PREFIX" "$EXECUTABLE" "$frame" \
  >"$PROOF_DIR/result.env"
sha256sum "$EXECUTABLE" >"$PROOF_DIR/SHA256SUMS"

if test "$status" -eq 0 && test -s "$frame"; then
  echo "JUICE_GUI_APP_DEVICE_OK arch=$ARCH executable=$EXECUTABLE proof_dir=$PROOF_DIR"
  exit 0
fi
echo "JUICE_GUI_APP_DEVICE_FAILED arch=$ARCH status=$status executable=$EXECUTABLE proof_dir=$PROOF_DIR" >&2
tail -n 160 "$LOG" >&2 || true
exit 3
