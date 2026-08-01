#!/var/jb/usr/bin/bash

set -o pipefail

SOURCE="$HOME/Juice/src/wine-11.13"
BUILD="$HOME/Juice/build/wine-arm64-pe"

mkdir -p "$BUILD"
cd "$BUILD"

export PATH="$HOME/Juice/toolchain/bin:/var/jb/usr/bin:/var/jb/usr/sbin:$PATH"

export CONFIG_SHELL="/var/jb/usr/bin/sh"
export SHELL="$CONFIG_SHELL"

# iOS host executables use the automatic CoreTrust wrapper.
export CC="$HOME/Juice/toolchain/juice-cc"
export CXX="$HOME/Juice/toolchain/juice-cxx"
export CPPBIN="/var/jb/usr/bin/clang"

# Parser/build tools.
export BISON="/var/jb/usr/bin/bison"
export YACC="/var/jb/usr/bin/bison -y"
export M4="/var/jb/usr/bin/m4"

export CFLAGS="-O2"
export CXXFLAGS="-O2"

# Tests already confirmed on this device.
export wine_cv_recent_bison=yes
export ac_cv_func_pthread_create=yes

"$CONFIG_SHELL" "$SOURCE/configure" \
  --build=aarch64-apple-darwin22.6.0 \
  --host=aarch64-apple-darwin22.6.0 \
  --prefix="$HOME/Juice/runtime-arm64" \
  --enable-archs=aarch64 \
  --with-mingw=/var/jb/usr/bin/clang \
  --disable-tests \
  --disable-win16 \
  --without-x \
  --without-wayland \
  --without-coreaudio \
  --without-cups \
  --without-dbus \
  --without-ffmpeg \
  --without-fontconfig \
  --without-freetype \
  --without-gettext \
  --without-gphoto \
  --without-gnutls \
  --without-gssapi \
  --without-gstreamer \
  --without-krb5 \
  --without-netapi \
  --without-opencl \
  --without-opengl \
  --without-oss \
  --without-pcap \
  --without-pcsclite \
  --without-pulse \
  --without-sane \
  --without-sdl \
  --without-udev \
  --without-usb \
  --without-v4l2 \
  --without-vulkan \
  2>&1 | tee configure-pe.log

CONFIGURE_STATUS=${PIPESTATUS[0]}

# Autoconf hardcodes /bin/sh, which rootless iOS lacks.
if [ -f config.status ]; then
    sed -i '1s|^#!.*|#!/var/jb/usr/bin/sh|' config.status
    chmod 755 config.status
fi

if [ ! -f Makefile ]; then
    if [ ! -f config.status ]; then
        echo "Configure failed before creating config.status"
        exit "$CONFIGURE_STATUS"
    fi

    "$CONFIG_SHELL" ./config.status
fi

sed -i \
  's|^SHELL[[:space:]]*=.*|SHELL = /var/jb/usr/bin/sh|' \
  Makefile

echo
echo "=== PE configuration ==="

grep -E \
  '^(HOST_ARCH|PE_ARCHS|aarch64_CC|aarch64_TARGET|SHELL)[[:space:]]*=' \
  Makefile || true
