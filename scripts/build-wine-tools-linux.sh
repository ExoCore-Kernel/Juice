#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SOURCE="$ROOT/wine"
BUILD="${JUICE_WINE_TOOLS_BUILD:-$ROOT/build/wine-tools-linux}"
JOBS="${JOBS:-${JUICE_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}}"
MAKE="${MAKE:-make}"
HOST_CC="${JUICE_HOST_CC:-cc}"
HOST_CXX="${JUICE_HOST_CXX:-c++}"

case "$BUILD" in
  "$ROOT"/build/*) ;;
  *) test "${JUICE_ALLOW_EXTERNAL_BUILD:-0}" = 1 || {
       echo "Refusing Wine tools build outside build/: $BUILD" >&2
       exit 2
     };;
esac
for tool in "$HOST_CC" "$HOST_CXX" bison flex m4 "$MAKE"; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing host build tool: $tool" >&2; exit 2; }
done

if test ! -f "$BUILD/Makefile" || test "${JUICE_RECONFIGURE:-0}" = 1; then
  rm -rf "$BUILD"
  mkdir -p "$BUILD"
  (
    cd "$BUILD"
    CC="$HOST_CC" CXX="$HOST_CXX" \
    "$SOURCE/configure" \
      --prefix=/usr/local \
      --enable-archs=none \
      --disable-tests --disable-win16 --without-mingw \
      --without-x --without-wayland --without-coreaudio --without-cups \
      --without-dbus --without-ffmpeg --without-fontconfig --without-freetype \
      --without-gettext --without-gphoto --without-gnutls --without-gssapi \
      --without-gstreamer --without-krb5 --without-netapi --without-opencl \
      --without-opengl --without-oss --without-pcap --without-pcsclite \
      --without-pulse --without-sane --without-sdl --without-udev \
      --without-usb --without-v4l2 --without-vulkan
  )
fi

"$MAKE" -C "$BUILD" -j"$JOBS" tools/makedep tools/winebuild/winebuild
for tool in "$BUILD/tools/makedep" "$BUILD/tools/winebuild/winebuild"; do
  test -x "$tool" || { echo "Missing Linux Wine build tool: $tool" >&2; exit 3; }
  file "$tool" | grep -Eq 'ELF 64-bit.*x86-64' || {
    echo "Wine build tool is not an x86_64 Linux executable: $tool" >&2
    file "$tool" >&2
    exit 3
  }
done

echo "JUICE_WINE_TOOLS_LINUX_OK path=$BUILD"
