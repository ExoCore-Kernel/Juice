#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
JBROOT="${JBROOT:-/var/jb}"
SOURCE="$ROOT/wine"
BUILD="${JUICE_PE_BUILD:-$ROOT/build/wine-arm64-pe}"
SHELL_BIN="${SHELL_BIN:-$JBROOT/usr/bin/sh}"
HOST_TRIPLET="${JUICE_HOST_TRIPLET:-aarch64-apple-darwin$(uname -r)}"
PE_CLANG="${JUICE_PE_CLANG:-$ROOT/build/toolchain/clang}"

case "$BUILD" in
  "$ROOT"/build/*) ;;
  *) test "${JUICE_ALLOW_EXTERNAL_BUILD:-0}" = 1 || {
       echo "Unsafe PE build path: $BUILD" >&2; exit 2;
     };;
esac
test -x "$ROOT/toolchain/juice-cc" || { echo "Missing toolchain/juice-cc." >&2; exit 2; }
test -x "$JBROOT/usr/bin/clang" || { echo "Missing iOS Clang." >&2; exit 2; }
if test -z "${JUICE_PE_CLANG+x}"; then
  "$JBROOT/usr/bin/bash" "$ROOT/scripts/build-pe-compiler-wrapper-device.sh"
fi
test -x "$PE_CLANG" || { echo "Missing PE compiler wrapper: $PE_CLANG" >&2; exit 2; }

mkdir -p "$BUILD"
cd "$BUILD"
rm -f config.cache config.log config.status Makefile configure.log

export PATH="$JBROOT/usr/bin:$JBROOT/usr/sbin:$PATH"
export CONFIG_SHELL="$SHELL_BIN" SHELL="$SHELL_BIN"
export CC="$ROOT/toolchain/juice-cc" CXX="$ROOT/toolchain/juice-cxx"
export CPPBIN="$JBROOT/usr/bin/clang"
export BISON="$ROOT/toolchain/juice-bison" YACC="$ROOT/toolchain/juice-bison -y"
export M4="$JBROOT/usr/bin/m4"
export CFLAGS="${CFLAGS:--O2}" CXXFLAGS="${CXXFLAGS:--O2}"
export wine_cv_recent_bison=yes ac_cv_func_pthread_create=yes
export JUICE_PE_BUILD_DIR="$BUILD"
export JUICE_INCBIN_PACKER="$ROOT/toolchain/juice-pack-incbins.py"
export JUICE_PYTHON="$JBROOT/usr/bin/python3"

set +e
"$SHELL_BIN" "$SOURCE/configure" \
  --build="$HOST_TRIPLET" --host="$HOST_TRIPLET" \
  --prefix="$ROOT/build/wine-runtime-arm64" \
  --enable-archs=aarch64 --with-mingw="$PE_CLANG" \
  --disable-tests --disable-win16 --without-freetype \
  --without-x --without-wayland --without-coreaudio --without-cups \
  --without-dbus --without-ffmpeg --without-fontconfig --without-gettext \
  --without-gphoto --without-gnutls --without-gssapi --without-gstreamer \
  --without-krb5 --without-netapi --without-opencl --without-opengl \
  --without-oss --without-pcap --without-pcsclite --without-pulse \
  --without-sane --without-sdl --without-udev --without-usb --without-v4l2 \
  --without-vulkan 2>&1 | tee configure.log
status=${PIPESTATUS[0]}
set -e
if test -f config.status; then
  sed -i "1s|^#!.*|#!$SHELL_BIN|" config.status
  chmod 755 config.status
fi
if test ! -f Makefile && test -f config.status; then
  set +e
  "$SHELL_BIN" ./config.status 2>&1 | tee -a configure.log
  status=${PIPESTATUS[0]}
  set -e
fi
test "$status" -eq 0 || exit "$status"
test -f Makefile || { echo "PE configure did not create a Makefile." >&2; exit 3; }
sed -i "s|^SHELL[[:space:]]*=.*|SHELL = $SHELL_BIN|" Makefile
grep -Fq 'dlls/wineios.drv/aarch64-windows/wineios.drv:' Makefile || {
  echo "The configured PE build is missing wineios.drv." >&2; exit 4;
}
grep -Fq "aarch64_CC = $PE_CLANG" Makefile || {
  echo "PE configure did not select the resource-aware Clang wrapper." >&2
  exit 4
}
echo "JUICE_PE_CONFIGURE_OK path=$BUILD compiler=$PE_CLANG"
