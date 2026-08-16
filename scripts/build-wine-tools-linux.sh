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

# A cross-configured Wine tree uses native build-host generators from toolsdir.
# Build the complete set used by IDL/header/resource and module generation so a
# later target does not fail because only makedep/winebuild happened to exist.
host_targets=(
  tools/makedep
  tools/winebuild/winebuild
  tools/winegcc/winegcc
  tools/widl/widl
  tools/wrc/wrc
  tools/wmc/wmc
)

"$MAKE" --output-sync=target -C "$BUILD" -j"$JOBS" "${host_targets[@]}"

host_tools=(
  "$BUILD/tools/makedep"
  "$BUILD/tools/winebuild/winebuild"
  "$BUILD/tools/winegcc/winegcc"
  "$BUILD/tools/widl/widl"
  "$BUILD/tools/wrc/wrc"
  "$BUILD/tools/wmc/wmc"
)
case "$(uname -m)" in
  x86_64|amd64) host_file_pattern='ELF 64-bit.*x86-64' ;;
  aarch64|arm64) host_file_pattern='ELF 64-bit.*ARM aarch64' ;;
  *) echo "Unsupported Linux host architecture: $(uname -m)" >&2; exit 2 ;;
esac
for tool in "${host_tools[@]}"; do
  test -x "$tool" || { echo "Missing Linux Wine build tool: $tool" >&2; exit 3; }
  file "$tool" | grep -Eq "$host_file_pattern" || {
    echo "Wine build tool does not match the current Linux host: $tool" >&2
    file "$tool" >&2
    exit 3
  }
done

echo "JUICE_WINE_TOOLS_LINUX_OK path=$BUILD count=${#host_tools[@]}"
