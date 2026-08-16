#!/usr/bin/env bash
set -euo pipefail

# Run one real graphics workload against an installed Juice.app and retain the
# complete device log, marker, and binary checksums as reproducible evidence.
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
MODE="${1:-}"
APP="${JUICE_INSTALLED_APP:-}"
SMOKE_ROOT="${JUICE_GRAPHICS_SMOKE_ROOT:-/var/mobile/Documents/JuiceData/SmokeTests}"
PROOF_ROOT="${JUICE_GRAPHICS_PROOF_ROOT:-/var/mobile/Documents/JuiceData/proofs/graphics}"
RUNNER="${JUICE_GRAPE_CLI_RUNNER:-$SCRIPT_DIR/run-grape-cli-device.sh}"

case "$MODE" in
  arm64-vulkan)
    GRAPE_NAME=Grape
    PREFIX="${JUICE_ARM64_PREFIX:-/var/mobile/Documents/JuiceData/GrapePrefix}"
    EXE="$SMOKE_ROOT/graphics-arm64/juice-vulkan-smoke.exe"
    MARKER="$SMOKE_ROOT/graphics-arm64/juice-vulkan-smoke.txt"
    EXPECTED=JUICE_VULKAN_SMOKE_OK
    ;;
  arm64-d3d12)
    GRAPE_NAME=Grape
    PREFIX="${JUICE_ARM64_PREFIX:-/var/mobile/Documents/JuiceData/GrapePrefix}"
    EXE="$SMOKE_ROOT/graphics-arm64/juice-d3d12-smoke.exe"
    MARKER="$SMOKE_ROOT/graphics-arm64/juice-d3d12-smoke.txt"
    EXPECTED=JUICE_D3D12_SMOKE_OK
    ;;
  arm64-d3d11)
    GRAPE_NAME=Grape
    PREFIX="${JUICE_ARM64_PREFIX:-/var/mobile/Documents/JuiceData/GrapePrefix}"
    EXE="$SMOKE_ROOT/graphics-arm64/juice-d3d11-smoke.exe"
    MARKER="$SMOKE_ROOT/graphics-arm64/juice-d3d11-smoke.txt"
    EXPECTED=JUICE_D3D11_SMOKE_OK
    ;;
  x86_64-vulkan)
    GRAPE_NAME=Grape-X64
    PREFIX="${JUICE_X64_PREFIX:-/var/mobile/Documents/JuiceData/GrapePrefix-x86_64}"
    EXE="$SMOKE_ROOT/graphics-x86_64/juice-vulkan-smoke.exe"
    MARKER="$SMOKE_ROOT/graphics-x86_64/juice-vulkan-smoke.txt"
    EXPECTED=JUICE_VULKAN_SMOKE_OK
    ;;
  x86_64-d3d12)
    GRAPE_NAME=Grape-X64
    PREFIX="${JUICE_X64_PREFIX:-/var/mobile/Documents/JuiceData/GrapePrefix-x86_64}"
    EXE="$SMOKE_ROOT/graphics-x86_64/juice-d3d12-smoke.exe"
    MARKER="$SMOKE_ROOT/graphics-x86_64/juice-d3d12-smoke.txt"
    EXPECTED=JUICE_D3D12_SMOKE_OK
    ;;
  x86_64-d3d11)
    GRAPE_NAME=Grape-X64
    PREFIX="${JUICE_X64_PREFIX:-/var/mobile/Documents/JuiceData/GrapePrefix-x86_64}"
    EXE="$SMOKE_ROOT/graphics-x86_64/juice-d3d11-smoke.exe"
    MARKER="$SMOKE_ROOT/graphics-x86_64/juice-d3d11-smoke.txt"
    EXPECTED=JUICE_D3D11_SMOKE_OK
    ;;
  *)
    echo "Usage: $0 {arm64-vulkan|arm64-d3d11|arm64-d3d12|x86_64-vulkan|x86_64-d3d11|x86_64-d3d12}" >&2
    exit 2
    ;;
esac

if test -z "$APP"; then
  newest_mtime=0
  while IFS= read -r candidate; do
    test -x "$candidate/$GRAPE_NAME/build/wine-ios/loader/wine" || continue
    candidate_mtime="$(stat -f '%m' "$candidate" 2>/dev/null || echo 0)"
    if test "$candidate_mtime" -gt "$newest_mtime"; then
      APP="$candidate"
      newest_mtime="$candidate_mtime"
    fi
  done < <(find /var/containers/Bundle/Application -mindepth 2 -maxdepth 2 \
    -type d -name Juice.app -print 2>/dev/null | sort)
fi

test -n "$APP" || { echo "No installed Juice.app was found." >&2; exit 2; }
test -x "$RUNNER" || { echo "Missing device CLI runner: $RUNNER" >&2; exit 2; }
test -s "$EXE" || { echo "Missing graphics smoke executable: $EXE" >&2; exit 2; }
GRAPE="$APP/$GRAPE_NAME"
test -x "$GRAPE/build/wine-ios/loader/wine" || {
  echo "Installed runtime is incomplete: $GRAPE" >&2
  exit 2
}

PROOF_DIR="$PROOF_ROOT/$MODE"
LOG="$PROOF_DIR/device.log"
mkdir -p "$PROOF_DIR" /var/mobile/Documents/JuiceData/tmp
rm -f "$MARKER" "$PROOF_DIR/marker.txt" "$LOG"

export JUICE_GRAPE_ROOT="$GRAPE"
export JUICE_TEST_PREFIX="$PREFIX"
export JUICE_SKIP_WINEBOOT=1
export TMPDIR=/var/mobile/Documents/JuiceData/tmp
export WINEDEBUG="${WINEDEBUG:--all,+vulkan,+d3d12,+wined3d}"
case "$MODE" in
  *-d3d11) export WINE_D3D_CONFIG="${WINE_D3D_CONFIG:-renderer=vulkan}" ;;
esac
if test "$GRAPE_NAME" = Grape-X64; then
  export JUICE_EXPERIMENTAL_X64=1
  export HODLL64=libarm64ecfex.dll
fi

set +e
timeout "${JUICE_GRAPHICS_TIMEOUT_SECONDS:-180}" bash "$RUNNER" "$EXE" >"$LOG" 2>&1
status=$?
set -e

if test -s "$MARKER"; then cp "$MARKER" "$PROOF_DIR/marker.txt"; fi
sha256sum "$EXE" \
  "$GRAPE/runtime/lib/wine/aarch64-windows/winevulkan.dll" \
  "$GRAPE/runtime/lib/wine/aarch64-windows/d3d11.dll" \
  "$GRAPE/runtime/lib/wine/aarch64-windows/wined3d.dll" \
  "$GRAPE/runtime/lib/wine/aarch64-windows/d3d12.dll" \
  "$GRAPE/build/wine-ios/dlls/winevulkan/winevulkan.so" \
  "$APP/Frameworks/MoltenVK.framework/MoltenVK" >"$PROOF_DIR/SHA256SUMS"
printf 'mode=%s\nstatus=%s\napp=%s\ngrape=%s\nprefix=%s\n' \
  "$MODE" "$status" "$APP" "$GRAPE" "$PREFIX" >"$PROOF_DIR/result.env"

if test "$status" -eq 0 && test -s "$PROOF_DIR/marker.txt" && \
   grep -Fq "$EXPECTED" "$PROOF_DIR/marker.txt"; then
  printf 'JUICE_GRAPHICS_SMOKE_OK mode=%s status=%s proof_dir=%s\n' \
    "$MODE" "$status" "$PROOF_DIR"
  exit 0
fi

printf 'JUICE_GRAPHICS_SMOKE_FAILED mode=%s status=%s proof_dir=%s\n' \
  "$MODE" "$status" "$PROOF_DIR" >&2
tail -n 120 "$LOG" >&2 || true
exit 3
