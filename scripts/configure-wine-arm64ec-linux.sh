#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/x86_64-build.env"
CACHE="${JUICE_X64_CACHE:-$ROOT/build/x86_64-cache}"
TOOLCHAIN="$CACHE/llvm-mingw-$JUICE_LLVM_MINGW_VERSION-ucrt-ubuntu-22.04-aarch64"
BUILD="${JUICE_ARM64EC_PE_BUILD:-$ROOT/build/wine-arm64ec-pe}"

test "$(uname -s)" = Linux || {
  echo "The hybrid PE build must run on an ARM64 Linux host." >&2
  exit 2
}
case "$BUILD" in
  "$ROOT"/build/*) ;;
  *) test "${JUICE_ALLOW_EXTERNAL_BUILD:-0}" = 1 || {
       echo "Refusing hybrid Wine build outside build/: $BUILD" >&2
       exit 2
     };;
esac
for tool in bison flex make; do
  command -v "$tool" >/dev/null || { echo "Missing build tool: $tool" >&2; exit 2; }
done

"$ROOT/scripts/bootstrap-x86_64-toolchain-linux.sh"
export PATH="$TOOLCHAIN/bin:/usr/local/bin:/usr/bin:/bin"
mkdir -p "$BUILD"
(
  cd "$BUILD"
  "$ROOT/wine/configure" \
    --prefix=/usr/local \
    --enable-archs=arm64ec,aarch64 \
    --with-mingw=clang \
    --disable-tests --disable-win16 \
    --without-freetype --without-x --without-wayland --without-coreaudio \
    --without-cups --without-dbus --without-ffmpeg --without-fontconfig \
    --without-gettext --without-gphoto --without-gnutls --without-gssapi \
    --without-gstreamer --without-krb5 --without-netapi --without-opencl \
    --without-opengl --without-oss --without-pcap --without-pcsclite \
    --without-pulse --without-sane --without-sdl --without-udev \
    --without-usb --without-v4l2 --without-vulkan
)
grep -Eq '^PE_ARCHS = +arm64ec aarch64$' "$BUILD/Makefile" || {
  echo "Wine configure did not enable the ARM64EC/AArch64 hybrid build." >&2
  exit 3
}
echo "JUICE_ARM64EC_CONFIGURE_OK path=$BUILD"
