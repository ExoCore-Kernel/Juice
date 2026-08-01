#!/var/jb/usr/bin/bash

set -e
set -o pipefail

cd "$HOME/Juice/build/wine-ios"

rm -f \
  config.cache \
  config.log \
  config.status \
  Makefile \
  configure-juice.log

export PATH="/var/jb/usr/bin:/var/jb/usr/sbin:$PATH"

export CONFIG_SHELL="/var/jb/usr/bin/sh"
export SHELL="$CONFIG_SHELL"

export CC="$HOME/Juice/toolchain/juice-cc"
export CXX="$HOME/Juice/toolchain/juice-cxx"
export CPPBIN="/var/jb/usr/bin/clang"

export BISON="/var/jb/usr/bin/bison"
export YACC="/var/jb/usr/bin/bison -y"
export M4="/var/jb/usr/bin/m4"

export CFLAGS="-O2"
export CXXFLAGS="-O2"

# Bison 3.8.2 is installed; its exact grammar test was already verified.
export wine_cv_recent_bison=yes

"$CONFIG_SHELL" "$HOME/Juice/src/wine-11.13/configure" \
  --build=aarch64-apple-darwin22.6.0 \
  --host=aarch64-apple-darwin22.6.0 \
  --prefix="$HOME/Juice/runtime" \
  --enable-archs=none \
  --disable-tests \
  --disable-win16 \
  --without-mingw \
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
  2>&1 | tee configure-juice.log
