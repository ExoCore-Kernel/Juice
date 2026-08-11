#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/x86_64-build.env"
CACHE="${JUICE_X64_CACHE:-$ROOT/build/x86_64-cache}"
TOOLCHAIN="$CACHE/llvm-mingw-$JUICE_LLVM_MINGW_VERSION-ucrt-ubuntu-22.04-aarch64"
DOWNLOADS="$CACHE/downloads"
ARCHIVE_PATH="$DOWNLOADS/$JUICE_LLVM_MINGW_ARCHIVE"

test "$(uname -s)" = Linux || {
  echo "The x86-64 component build requires an ARM64 Linux host." >&2
  exit 2
}
case "$(uname -m)" in
  aarch64|arm64) ;;
  *) echo "The pinned translator toolchain is for an ARM64 Linux host." >&2; exit 2;;
esac
case "$CACHE" in
  "$ROOT"/build/*) ;;
  *) test "${JUICE_ALLOW_EXTERNAL_BUILD:-0}" = 1 || {
       echo "Refusing x86-64 cache outside build/: $CACHE" >&2
       exit 2
     };;
esac

if test -x "$TOOLCHAIN/bin/arm64ec-w64-mingw32-clang"; then
  echo "JUICE_X64_TOOLCHAIN_OK path=$TOOLCHAIN cached=1"
  exit 0
fi

mkdir -p "$DOWNLOADS"
if test -f "$ARCHIVE_PATH"; then
  printf '%s  %s\n' "$JUICE_LLVM_MINGW_SHA256" "$ARCHIVE_PATH" | sha256sum -c -
else
  partial="$ARCHIVE_PATH.part"
  rm -f "$partial"
  curl --location --fail --retry 3 --output "$partial" "$JUICE_LLVM_MINGW_URL"
  printf '%s  %s\n' "$JUICE_LLVM_MINGW_SHA256" "$partial" | sha256sum -c -
  mv "$partial" "$ARCHIVE_PATH"
fi

temporary="$(mktemp -d "$CACHE/.toolchain.XXXXXX")"
cleanup()
{
  case "$temporary" in "$CACHE"/.toolchain.*) rm -rf "$temporary";; esac
}
trap cleanup EXIT
tar -xJf "$ARCHIVE_PATH" -C "$temporary"
extracted="$temporary/$(basename "$TOOLCHAIN")"
test -x "$extracted/bin/arm64ec-w64-mingw32-clang" || {
  echo "ARM64EC compiler was not present in the verified archive." >&2
  exit 3
}
test ! -e "$TOOLCHAIN" || {
  echo "Incomplete toolchain directory already exists: $TOOLCHAIN" >&2
  exit 3
}
mv "$extracted" "$TOOLCHAIN"
echo "JUICE_X64_TOOLCHAIN_OK path=$TOOLCHAIN cached=0"
