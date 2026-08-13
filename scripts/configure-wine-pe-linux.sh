#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/x86_64-build.env"
SOURCE="$ROOT/wine"
BUILD="${JUICE_PE_BUILD:-$ROOT/build/wine-arm64-pe}"
TOOLS="${JUICE_WINE_TOOLS_BUILD:-$ROOT/build/wine-tools-linux}"
CACHE="${JUICE_X64_CACHE:-$ROOT/build/x86_64-cache}"
TOOLCHAIN="$CACHE/$JUICE_LLVM_MINGW_DIRNAME"
IOS_TOOLCHAIN="${JUICE_IOS_TOOLCHAIN:-$ROOT/build/ios-toolchain}"
IOS_PREFIX="${JUICE_IOS_TRIPLE_PREFIX:-arm-apple-darwin11}"
SDK="${IOS_SDK:-}"
CC_WRAPPER="${JUICE_IOS_CC:-$ROOT/toolchain/juice-ios-cc}"
CXX_WRAPPER="${JUICE_IOS_CXX:-$ROOT/toolchain/juice-ios-cxx}"
AR_BIN="${JUICE_IOS_AR:-$IOS_TOOLCHAIN/bin/$IOS_PREFIX-ar}"
RANLIB_BIN="${JUICE_IOS_RANLIB:-$IOS_TOOLCHAIN/bin/$IOS_PREFIX-ranlib}"
OTOOL_BIN="${JUICE_IOS_OTOOL:-$IOS_TOOLCHAIN/bin/$IOS_PREFIX-otool}"
BUILD_TRIPLET="${JUICE_BUILD_TRIPLET:-$($SOURCE/config.guess)}"
HOST_TRIPLET="${JUICE_HOST_TRIPLET:-aarch64-apple-darwin}"
PE_CLANG="${JUICE_PE_CLANG:-$TOOLCHAIN/bin/aarch64-w64-mingw32-clang}"
PE_ARCHS="${JUICE_PE_ARCHS:-aarch64}"
SHELL_BIN="${SHELL_BIN:-/bin/bash}"

case "$BUILD" in "$ROOT"/build/*) ;; *) test "${JUICE_ALLOW_EXTERNAL_BUILD:-0}" = 1 || { echo "Unsafe Linux PE build path: $BUILD" >&2; exit 2; };; esac
test "$(uname -s)" = Linux || { echo "This configure path requires Linux." >&2; exit 2; }
if test -z "$SDK" && test -d "$IOS_TOOLCHAIN/SDK"; then
  SDK="$(find "$IOS_TOOLCHAIN/SDK" -maxdepth 2 -type d -name 'iPhoneOS*.sdk' -print -quit 2>/dev/null || true)"
fi
test -d "$SDK" || { echo "Missing iPhoneOS SDK. Set IOS_SDK or JUICE_IOS_TOOLCHAIN." >&2; exit 2; }
for tool in "$CC_WRAPPER" "$CXX_WRAPPER" "$AR_BIN" "$RANLIB_BIN" "$OTOOL_BIN"; do
  test -x "$tool" || { echo "Missing iOS cross-toolchain executable: $tool" >&2; exit 2; }
done
test -x "$TOOLS/tools/makedep" -a -x "$TOOLS/tools/winebuild/winebuild" || "$ROOT/scripts/build-wine-tools-linux.sh"
"$ROOT/scripts/bootstrap-x86_64-toolchain-linux.sh"
test -x "$PE_CLANG" || { echo "Missing ARM64 PE compiler: $PE_CLANG" >&2; exit 2; }

mkdir -p "$BUILD"
cd "$BUILD"
rm -f config.cache config.log config.status Makefile configure.log

export CONFIG_SHELL="$SHELL_BIN" SHELL="$SHELL_BIN"
export IOS_SDK="$SDK" JUICE_IOS_TOOLCHAIN="$IOS_TOOLCHAIN"
export CC="$CC_WRAPPER" CXX="$CXX_WRAPPER" CPPBIN="${CPPBIN:-cpp}"
export AR="$AR_BIN" RANLIB="$RANLIB_BIN" OTOOL="$OTOOL_BIN"
export BISON="${BISON:-bison}" YACC="${YACC:-bison -y}" M4="${M4:-m4}"
export CFLAGS="${CFLAGS:--O2}" CXXFLAGS="${CXXFLAGS:--O2}"
export wine_cv_recent_bison=yes ac_cv_func_pthread_create=yes JUICE_IOS_DEVICE=1

set +e
"$SHELL_BIN" "$SOURCE/configure" \
  --build="$BUILD_TRIPLET" --host="$HOST_TRIPLET" --with-wine-tools="$TOOLS" \
  --prefix="$ROOT/build/wine-runtime-arm64" --enable-archs="$PE_ARCHS" --with-mingw="$PE_CLANG" \
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
test "$status" -eq 0 || exit "$status"
test -f Makefile || { echo "PE Linux cross-configure did not create a Makefile." >&2; exit 3; }

grep -Fq 'dlls/wineios.drv/aarch64-windows/wineios.drv:' Makefile || { echo "The configured Linux PE build is missing wineios.drv." >&2; exit 4; }
grep -Fq "aarch64_CC = $PE_CLANG" Makefile || { echo "PE Linux cross-configure did not select llvm-mingw: $PE_CLANG" >&2; exit 4; }
grep -Fq "toolsdir = $TOOLS" Makefile || { echo "PE Linux cross-configure did not use the native Linux Wine tools tree." >&2; exit 4; }

echo "JUICE_PE_LINUX_CONFIGURE_OK path=$BUILD compiler=$PE_CLANG archs=$PE_ARCHS toolchain=$IOS_TOOLCHAIN"
