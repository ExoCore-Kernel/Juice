#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/x86_64-build.env"
SOURCE="$ROOT/toolchain/juice-pe-clang.c"
OUTPUT="${JUICE_PE_WRAPPER:-$ROOT/build/toolchain-linux/clang}"
CACHE="${JUICE_X64_CACHE:-$ROOT/build/x86_64-cache}"
TOOLCHAIN="$CACHE/$JUICE_LLVM_MINGW_DIRNAME"
REAL_CLANG="${JUICE_REAL_PE_CLANG:-${JUICE_PE_CLANG:-$TOOLCHAIN/bin/aarch64-w64-mingw32-clang}}"
HOST_CC="${HOST_CC:-cc}"
PYTHON_BIN="${JUICE_PYTHON:-$(command -v python3 || true)}"
PACKER="${JUICE_INCBIN_PACKER:-$ROOT/toolchain/juice-pack-incbins.py}"

case "$OUTPUT" in
  "$ROOT"/build/*/clang) ;;
  *) test "${JUICE_ALLOW_EXTERNAL_BUILD:-0}" = 1 || {
       echo "Unsafe Linux PE compiler-wrapper path (it must also end in /clang): $OUTPUT" >&2
       exit 2
     };;
esac

case "$(uname -m)" in
  x86_64|amd64) host_file_pattern='ELF 64-bit.*x86-64' ;;
  aarch64|arm64) host_file_pattern='ELF 64-bit.*ARM aarch64' ;;
  *) echo "The Linux PE compiler wrapper requires a 64-bit x86 or ARM host." >&2; exit 2 ;;
esac

test -f "$SOURCE" || { echo "Missing PE wrapper source: $SOURCE" >&2; exit 2; }
test -x "$REAL_CLANG" || { echo "Missing real ARM64 PE compiler: $REAL_CLANG" >&2; exit 2; }
test -n "$PYTHON_BIN" -a -x "$PYTHON_BIN" || { echo "Missing Python 3 for PE resource packing." >&2; exit 2; }
test -r "$PACKER" || { echo "Missing PE incbin packer: $PACKER" >&2; exit 2; }
command -v "$HOST_CC" >/dev/null 2>&1 || { echo "Missing host C compiler: $HOST_CC" >&2; exit 2; }

verify_output()
{
  test -x "$OUTPUT" || { echo "Linux PE compiler wrapper was not built." >&2; exit 3; }
  file "$OUTPUT" | grep -Eq "$host_file_pattern" || {
    echo "Unexpected Linux PE compiler wrapper output: $OUTPUT" >&2
    file "$OUTPUT" >&2 || true
    exit 3
  }
  JUICE_REAL_PE_CLANG="$REAL_CLANG" \
  JUICE_PYTHON="$PYTHON_BIN" \
  JUICE_INCBIN_PACKER="$PACKER" \
    "$OUTPUT" --version >/dev/null
}

if test -x "$OUTPUT" && test "$OUTPUT" -nt "$SOURCE"; then
  verify_output
  echo "JUICE_PE_COMPILER_WRAPPER_LINUX_OK path=$OUTPUT cached=1 real=$REAL_CLANG"
  exit 0
fi

mkdir -p "$(dirname -- "$OUTPUT")"
"$HOST_CC" -O2 -Wall -Wextra "$SOURCE" -o "$OUTPUT"
verify_output
echo "JUICE_PE_COMPILER_WRAPPER_LINUX_OK path=$OUTPUT cached=0 real=$REAL_CLANG"
