#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/x86_64-build.env"
CACHE="${JUICE_X64_CACHE:-$ROOT/build/x86_64-cache}"
TOOLCHAIN="$CACHE/$JUICE_LLVM_MINGW_DIRNAME"
BUILD="${JUICE_ARM64EC_PE_BUILD:-$ROOT/build/wine-arm64ec-pe}"
CONFIG_GUESS="${JUICE_CONFIG_GUESS:-$ROOT/wine/tools/config.guess}"
HOST_CC="${JUICE_HOST_CC:-$(command -v cc || true)}"
HOST_CXX="${JUICE_HOST_CXX:-$(command -v c++ || true)}"

test "$(uname -s)" = Linux || {
  echo "The hybrid PE build must run on a Linux host." >&2
  exit 2
}
case "$(uname -m)" in
  x86_64|amd64|aarch64|arm64) ;;
  *) echo "Unsupported Linux host architecture: $(uname -m)" >&2; exit 2;;
esac
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
test -x "$CONFIG_GUESS" || { echo "Missing Wine config.guess: $CONFIG_GUESS" >&2; exit 2; }
test -n "$HOST_CC" -a -x "$HOST_CC" || { echo "Missing native Linux C compiler." >&2; exit 2; }
test -n "$HOST_CXX" -a -x "$HOST_CXX" || { echo "Missing native Linux C++ compiler." >&2; exit 2; }

"$ROOT/scripts/bootstrap-x86_64-toolchain-linux.sh"
export PATH="$TOOLCHAIN/bin:/usr/local/bin:/usr/bin:/bin"
mkdir -p "$BUILD"
BUILD_TRIPLET="${JUICE_BUILD_TRIPLET:-$($CONFIG_GUESS)}"
(
  cd "$BUILD"
  rm -f config.cache config.status

  # build-all-linux-x86_64.sh exports CC=juice-ios-cc for the iOS assembly
  # stage. Do not let that target compiler leak into this hybrid Wine tree:
  # configure needs a runnable native Linux compiler for its host/build tools,
  # while --enable-archs lets Wine discover the ARM64EC/AArch64 MinGW compilers
  # separately from llvm-mingw.
  env \
    -u CPP -u CPPFLAGS -u CFLAGS -u CXXFLAGS -u LDFLAGS \
    -u AR -u AS -u LD -u NM -u OBJCOPY -u OBJDUMP -u RANLIB -u STRIP \
    CC="$HOST_CC" CXX="$HOST_CXX" \
    "$ROOT/wine/configure" \
      --build="$BUILD_TRIPLET" \
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
echo "JUICE_ARM64EC_CONFIGURE_OK path=$BUILD build=$BUILD_TRIPLET host_cc=$HOST_CC"
