#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ARCH="${1:-${JUICE_NETWORK_ARCH:-arm64}}"
APP="${JUICE_INSTALLED_APP:-}"
DATA_ROOT="${JUICE_DATA_ROOT:-/var/mobile/Documents/JuiceData}"
RUNNER="${JUICE_GRAPE_CLI_RUNNER:-$SCRIPT_DIR/run-grape-cli-device.sh}"

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

case "$ARCH" in
  arm64)
    GRAPE="$APP/Grape"
    PREFIX="${JUICE_NETWORK_PREFIX:-$DATA_ROOT/GrapePrefix-network-arm64}"
    ;;
  x86_64)
    GRAPE="$APP/Grape-X64"
    PREFIX="${JUICE_NETWORK_PREFIX:-$DATA_ROOT/GrapePrefix-network-x86}"
    export JUICE_EXPERIMENTAL_X64=1
    ;;
  i386)
    GRAPE="$APP/Grape-X64"
    PREFIX="${JUICE_NETWORK_PREFIX:-$DATA_ROOT/GrapePrefix-network-x86}"
    export JUICE_EXPERIMENTAL_WIN32=1
    ;;
  *) echo "Unknown network smoke architecture: $ARCH" >&2; exit 2;;
esac

SMOKE="${JUICE_NETWORK_SMOKE:-$GRAPE/tests/network-smoke-$ARCH.exe}"
PROOF_DIR="${JUICE_NETWORK_PROOF_DIR:-$DATA_ROOT/proofs/network-$ARCH}"
MARKER="$PROOF_DIR/marker.txt"
LOG="$PROOF_DIR/device.log"
test -s "$SMOKE" || { echo "Missing $ARCH network smoke: $SMOKE" >&2; exit 2; }
test -s "$APP/Libraries/libgnutls.30.dylib" || {
  echo "Installed Juice.app has no bundled GnuTLS runtime." >&2; exit 2;
}

mkdir -p "$PROOF_DIR"
rm -f "$MARKER" "$LOG" "$PROOF_DIR/result.env" "$PROOF_DIR/SHA256SUMS"
export JUICE_GRAPE_ROOT="$GRAPE"
export JUICE_TEST_PREFIX="$PREFIX"
export JUICE_NETWORK_MARKER_WINDOWS="Z:${MARKER//\//\\}"
# Network smokes normally reuse their initialized prefix for speed.  Set
# JUICE_NETWORK_SKIP_WINEBOOT=0 together with JUICE_FORCE_WINEBOOT=1 after the
# curated runtime changes so Wine can register newly bundled providers and
# other WINE_REGISTRY resources in that persistent prefix.
export JUICE_SKIP_WINEBOOT="${JUICE_NETWORK_SKIP_WINEBOOT:-1}"
export WINEDEBUG="${WINEDEBUG:-warn+all,+winsock,+wininet,+secur32,+schannel}"

set +e
timeout "${JUICE_NETWORK_TIMEOUT_SECONDS:-90}" bash "$RUNNER" "$SMOKE" >"$LOG" 2>&1
status=$?
set -e
printf 'architecture=%s\nstatus=%s\napp=%s\ngrape=%s\nprefix=%s\n' \
  "$ARCH" "$status" "$APP" "$GRAPE" "$PREFIX" > "$PROOF_DIR/result.env"
sha256sum "$SMOKE" "$APP/Libraries/libgnutls.30.dylib" \
  "$GRAPE/build/wine-ios/dlls/secur32/secur32.so" > "$PROOF_DIR/SHA256SUMS"

if test "$status" -eq 100 && test -s "$MARKER" && \
   grep -Fq JUICE_NETWORK_SMOKE_OK "$MARKER"; then
  echo "JUICE_NETWORK_DEVICE_SMOKE_OK arch=$ARCH status=$status proof_dir=$PROOF_DIR"
  exit 0
fi
echo "JUICE_NETWORK_DEVICE_SMOKE_FAILED arch=$ARCH status=$status proof_dir=$PROOF_DIR" >&2
tail -n 160 "$LOG" >&2 || true
test -f "$MARKER" && cat "$MARKER" >&2 || true
exit 3
