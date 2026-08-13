#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/x86_64-build.env"
CACHE="${JUICE_X64_CACHE:-$ROOT/build/x86_64-cache}"
TOOLCHAIN="$CACHE/$JUICE_LLVM_MINGW_DIRNAME"
OUTPUT="${JUICE_X64_SMOKE_OUTPUT:-$ROOT/build/x86_64-smoke.exe}"

case "$OUTPUT" in
  "$ROOT"/build/*) ;;
  *) test "${JUICE_ALLOW_EXTERNAL_BUILD:-0}" = 1 || {
       echo "Refusing smoke output outside build/: $OUTPUT" >&2
       exit 2
     };;
esac
"$ROOT/scripts/bootstrap-x86_64-toolchain-linux.sh"
mkdir -p "$(dirname "$OUTPUT")"
"$TOOLCHAIN/bin/x86_64-w64-mingw32-clang" \
  -Os -fno-builtin -fno-stack-protector -nostdlib \
  -Wl,--entry,mainCRTStartup -Wl,--subsystem,windows \
  "$ROOT/tests/x86_64/smoke.c" -lkernel32 -o "$OUTPUT"
machine="$("$TOOLCHAIN/bin/llvm-readobj" --file-headers "$OUTPUT" |
  sed -n 's/^  Machine: //p')"
case "$machine" in
  IMAGE_FILE_MACHINE_AMD64*) ;;
  *) echo "Unexpected smoke-test machine: $machine" >&2; exit 3;;
esac
sha256sum "$OUTPUT" > "$OUTPUT.sha256"
echo "JUICE_X64_SMOKE_BUILD_OK path=$OUTPUT machine=$machine"
