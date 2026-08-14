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
CONFIG_GUESS="${JUICE_CONFIG_GUESS:-$SOURCE/tools/config.guess}"
test -x "$CONFIG_GUESS" || { echo "Missing executable Wine config.guess: $CONFIG_GUESS" >&2; exit 2; }
BUILD_TRIPLET="${JUICE_BUILD_TRIPLET:-$($CONFIG_GUESS)}"
HOST_TRIPLET="${JUICE_HOST_TRIPLET:-aarch64-apple-darwin}"
REAL_PE_CLANG="${JUICE_REAL_PE_CLANG:-${JUICE_PE_CLANG:-$TOOLCHAIN/bin/aarch64-w64-mingw32-clang}}"
PE_WRAPPER="${JUICE_PE_WRAPPER:-$ROOT/build/toolchain-linux/clang}"
PE_PACKER="${JUICE_INCBIN_PACKER:-$ROOT/toolchain/juice-pack-incbins.py}"
PE_PYTHON="${JUICE_PYTHON:-$(command -v python3 || true)}"
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
test -x "$REAL_PE_CLANG" || { echo "Missing ARM64 PE compiler: $REAL_PE_CLANG" >&2; exit 2; }
test -n "$PE_PYTHON" -a -x "$PE_PYTHON" || { echo "Missing Python 3 for PE resource packing." >&2; exit 2; }
test -r "$PE_PACKER" || { echo "Missing PE incbin packer: $PE_PACKER" >&2; exit 2; }
JUICE_PE_WRAPPER="$PE_WRAPPER" \
JUICE_REAL_PE_CLANG="$REAL_PE_CLANG" \
JUICE_PYTHON="$PE_PYTHON" \
JUICE_INCBIN_PACKER="$PE_PACKER" \
  /bin/bash "$ROOT/scripts/build-pe-compiler-wrapper-linux.sh"
test -x "$PE_WRAPPER" || { echo "Missing Linux PE compiler wrapper: $PE_WRAPPER" >&2; exit 2; }

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
export JUICE_REAL_PE_CLANG="$REAL_PE_CLANG"
export JUICE_PE_BUILD_DIR="$BUILD"
export JUICE_INCBIN_PACKER="$PE_PACKER"
export JUICE_PYTHON="$PE_PYTHON"

# Wine's configure test keys off __GCC_HAVE_SYNC_COMPARE_AND_SWAP_8. Apple/iOS
# Clang does not reliably define that GCC compatibility macro for AArch64 even
# though 64-bit compare-and-swap is available on the target. Preseed Wine's
# cache result only for the AArch64 Darwin cross-target.
case "$HOST_TRIPLET" in
  aarch64-apple-darwin*)
    export wine_cv_64bit_compare_swap="${wine_cv_64bit_compare_swap:-none needed}"
    ;;
esac

set +e
"$SHELL_BIN" "$SOURCE/configure" \
  --build="$BUILD_TRIPLET" --host="$HOST_TRIPLET" --with-wine-tools="$TOOLS" \
  --prefix="$ROOT/build/wine-runtime-arm64" --enable-archs="$PE_ARCHS" --with-mingw="$PE_WRAPPER" \
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
pe_cc_line="$(grep -E '^aarch64_CC[[:space:]]*=' Makefile | head -n1 || true)"
test -n "$pe_cc_line" || { echo "PE Linux cross-configure did not define aarch64_CC." >&2; exit 4; }
pe_wrapper_name="$(basename "$PE_WRAPPER")"
case "$pe_cc_line" in
  *"$PE_WRAPPER"*|*"$pe_wrapper_name"*) ;;
  *)
    echo "PE Linux cross-configure did not select the resource-aware compiler wrapper." >&2
    echo "Requested: $PE_WRAPPER" >&2
    echo "Generated: $pe_cc_line" >&2
    exit 4
    ;;
esac
grep -Fq "toolsdir = $TOOLS" Makefile || { echo "PE Linux cross-configure did not use the native Linux Wine tools tree." >&2; exit 4; }

echo "JUICE_PE_LINUX_CONFIGURE_OK path=$BUILD compiler=$PE_WRAPPER real=$REAL_PE_CLANG archs=$PE_ARCHS toolchain=$IOS_TOOLCHAIN"
