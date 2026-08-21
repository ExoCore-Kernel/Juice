#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/x86_64-build.env"
CACHE="${JUICE_X64_CACHE:-$ROOT/build/x86_64-cache}"
TOOLCHAIN="$CACHE/$JUICE_LLVM_MINGW_DIRNAME"
OUTPUT="${JUICE_NETWORK_SMOKE_BUILD:-$ROOT/build/network-smokes}"
SOURCE="$ROOT/tests/network/smoke.c"

case "$OUTPUT" in
  "$ROOT"/build/*) ;;
  *) test "${JUICE_ALLOW_EXTERNAL_BUILD:-0}" = 1 || {
       echo "Refusing network smoke output outside build/: $OUTPUT" >&2
       exit 2
     };;
esac

bash "$ROOT/scripts/bootstrap-x86_64-toolchain-linux.sh"
mkdir -p "$OUTPUT"

build_one()
{
  local arch="$1" triple="$2" expected="$3"
  local output="$OUTPUT/network-smoke-$arch.exe" compiler="$TOOLCHAIN/bin/$triple-clang"
  "$compiler" -Os -fno-builtin -fno-stack-protector -nostdlib \
    -Wl,--entry,mainCRTStartup -Wl,--subsystem,console \
    "$SOURCE" -lwininet -lws2_32 -lkernel32 -o "$output"
  machine="$("$TOOLCHAIN/bin/llvm-readobj" --file-headers "$output" |
    sed -n 's/^  Machine: //p')"
  case "$machine" in "$expected"*) ;; *)
    echo "Unexpected $arch network smoke machine: $machine" >&2; exit 3;;
  esac
  echo "JUICE_NETWORK_SMOKE_BINARY_OK arch=$arch machine=$machine path=$output"
}

build_one arm64 aarch64-w64-mingw32 IMAGE_FILE_MACHINE_ARM64
build_one i386 i686-w64-mingw32 IMAGE_FILE_MACHINE_I386
build_one x86_64 x86_64-w64-mingw32 IMAGE_FILE_MACHINE_AMD64
sha256sum "$OUTPUT"/*.exe > "$OUTPUT/SHA256SUMS"
echo "JUICE_NETWORK_SMOKES_BUILD_OK path=$OUTPUT architectures=arm64,i386,x86_64"
