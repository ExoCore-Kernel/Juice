#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
JBROOT="${JBROOT:-/var/jb}"
SOURCE="$ROOT/wine"
BUILD="${JUICE_WINE_BUILD:-$ROOT/build/wine-ios}"
SHELL_BIN="${SHELL_BIN:-$JBROOT/usr/bin/sh}"
HOST_TRIPLET="${JUICE_HOST_TRIPLET:-aarch64-apple-darwin$(uname -r)}"
TRUST_CARRIER="${JUICE_TRUST_CARRIER:-$ROOT/build/trust-carrier}"

case "$BUILD" in
  "$ROOT"/build/*) ;;
  *) test "${JUICE_ALLOW_EXTERNAL_BUILD:-0}" = 1 || {
       echo "Unsafe native build path: $BUILD" >&2; exit 2;
     };;
esac
test -x "$ROOT/toolchain/juice-cc" || { echo "Missing toolchain/juice-cc." >&2; exit 2; }
test -d "$TRUST_CARRIER/Payload/JuiceTrust.app" || {
  echo "Run bootstrap-trust-carrier-device.sh first." >&2; exit 2;
}
test -x "$SHELL_BIN" || { echo "Missing shell: $SHELL_BIN" >&2; exit 2; }

mkdir -p "$BUILD"
cd "$BUILD"
rm -f config.cache config.log config.status Makefile configure.log

export PATH="$JBROOT/usr/bin:$JBROOT/usr/sbin:$PATH"
export CONFIG_SHELL="$SHELL_BIN" SHELL="$SHELL_BIN"
export CC="$ROOT/toolchain/juice-cc" CXX="$ROOT/toolchain/juice-cxx"
export CPPBIN="$JBROOT/usr/bin/clang"
export BISON="$ROOT/toolchain/juice-bison" YACC="$ROOT/toolchain/juice-bison -y"
export M4="$JBROOT/usr/bin/m4"
export PKG_CONFIG="$JBROOT/usr/bin/pkg-config"
export PKG_CONFIG_PATH="$JBROOT/usr/lib/pkgconfig:$JBROOT/usr/share/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export CFLAGS="${CFLAGS:--O2}" CXXFLAGS="${CXXFLAGS:--O2}"
export wine_cv_recent_bison=yes ac_cv_func_pthread_create=yes
export JUICE_IOS_DEVICE=1

freetype_args=()
if test "${JUICE_WITHOUT_FREETYPE:-0}" = 1; then
  freetype_args+=(--without-freetype)
else
  test -f "$JBROOT/usr/include/freetype2/ft2build.h" &&
    test -f "$JBROOT/usr/lib/libfreetype.dylib" || {
      echo "FreeType is missing; run scripts/preflight-device.sh." >&2; exit 3;
    }
  # Procursus' freetype2.pc references a zlib.pc that iOS does not ship.
  # Supplying the known rootless paths avoids that packaging-only mismatch.
  export FREETYPE_CFLAGS="${FREETYPE_CFLAGS:--I$JBROOT/usr/include/freetype2}"
  export FREETYPE_LIBS="${FREETYPE_LIBS:--L$JBROOT/usr/lib -lfreetype}"
fi

set +e
"$SHELL_BIN" "$SOURCE/configure" \
  --build="$HOST_TRIPLET" --host="$HOST_TRIPLET" \
  --prefix="$ROOT/build/wine-runtime" --enable-archs=none \
  --disable-tests --disable-win16 --without-mingw \
  --without-x --without-wayland --without-coreaudio --without-cups \
  --without-dbus --without-ffmpeg --without-fontconfig \
  "${freetype_args[@]}" \
  --without-gettext --without-gphoto --without-gnutls --without-gssapi \
  --without-gstreamer --without-krb5 --without-netapi --without-opencl \
  --without-opengl --without-oss --without-pcap --without-pcsclite \
  --without-pulse --without-sane --without-sdl --without-udev --without-usb \
  --without-v4l2 --without-vulkan 2>&1 | tee configure.log
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
test -f Makefile || { echo "Wine configure did not create a Makefile." >&2; exit 4; }
sed -i "s|^SHELL[[:space:]]*=.*|SHELL = $SHELL_BIN|" Makefile

freetype_status=enabled
if test "${JUICE_WITHOUT_FREETYPE:-0}" != 1; then
  grep -q '^#define HAVE_FT2BUILD_H 1' include/config.h || {
    echo "Wine configure did not enable FreeType." >&2; exit 5;
  }
else
  freetype_status=disabled
fi
echo "JUICE_WINE_CONFIGURE_OK path=$BUILD freetype=$freetype_status"
