#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/x86_64-build.env"
source "$ROOT/config/graphics-build.env"
CACHE="${JUICE_X64_CACHE:-$ROOT/build/x86_64-cache}"
TOOLCHAIN="$CACHE/$JUICE_LLVM_MINGW_DIRNAME"
BUILD="${JUICE_WOW64_PE_BUILD:-$ROOT/build/wine-wow64-pe}"
CONFIG_GUESS="${JUICE_CONFIG_GUESS:-$ROOT/wine/tools/config.guess}"
HOST_CC="${JUICE_HOST_CC:-$(command -v cc || true)}"
HOST_CXX="${JUICE_HOST_CXX:-$(command -v c++ || true)}"

case "$BUILD" in
  "$ROOT"/build/*) ;;
  *) test "${JUICE_ALLOW_EXTERNAL_BUILD:-0}" = 1 || {
       echo "Refusing WoW64 Wine build outside build/: $BUILD" >&2
       exit 2
     };;
esac

test "$(uname -s)" = Linux || {
  echo "The WoW64 PE build must run on Linux." >&2
  exit 2
}
case "$(uname -m)" in
  x86_64|amd64|aarch64|arm64) ;;
  *) echo "Unsupported Linux host architecture: $(uname -m)" >&2; exit 2;;
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
  env \
    -u CPP -u CPPFLAGS -u CFLAGS -u CXXFLAGS -u LDFLAGS \
    -u AR -u AS -u LD -u NM -u OBJCOPY -u OBJDUMP -u RANLIB -u STRIP \
    CC="$HOST_CC" CXX="$HOST_CXX" ac_cv_lib_soname_MoltenVK="$JUICE_MOLTENVK_RUNTIME_NAME" \
    "$ROOT/wine/configure" \
      --build="$BUILD_TRIPLET" \
      --prefix=/usr/local \
      --enable-archs=i386,aarch64 \
      --with-mingw=clang \
      --disable-tests --disable-win16 \
      --without-freetype --without-x --without-wayland --without-coreaudio \
      --without-cups --without-dbus --without-ffmpeg --without-fontconfig \
      --without-gettext --without-gphoto --without-gnutls --without-gssapi \
      --without-gstreamer --without-krb5 --without-netapi --without-opencl \
      --without-opengl --without-oss --without-pcap --without-pcsclite \
      --without-pulse --without-sane --without-sdl --without-udev \
      --without-usb --without-v4l2 --with-vulkan
)

pe_archs="$(sed -n 's/^PE_ARCHS = *//p' "$BUILD/Makefile" | head -1)"
[[ " $pe_archs " == *" i386 "* && " $pe_archs " == *" aarch64 "* ]] || {
  echo "Wine configure did not enable i386/AArch64 WoW64. PE_ARCHS=$pe_archs" >&2
  exit 3
}
echo "JUICE_WOW64_CONFIGURE_OK path=$BUILD pe_archs=$pe_archs build=$BUILD_TRIPLET host_cc=$HOST_CC"
