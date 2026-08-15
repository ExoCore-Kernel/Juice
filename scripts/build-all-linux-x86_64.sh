#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUTPUT="${JUICE_TIPA_OUTPUT:-}"
TOOLS="${JUICE_WINE_TOOLS_BUILD:-$ROOT/build/wine-tools-linux}"
WINE_BUILD="${JUICE_WINE_BUILD:-$ROOT/build/wine-ios}"
PE_BUILD="${JUICE_PE_BUILD:-$ROOT/build/wine-arm64-pe}"
LOWVA_HEADER="$ROOT/toolchain/juice-ios-map-tryfixed.h"
LOWVA_OBJECT="$WINE_BUILD/dlls/ntdll/unix/virtual.o"
LOWVA_STAMP="$WINE_BUILD/.juice-ios-lowva-shim.sha256"
LOWVA_BOOTSTRAP_HEADER="$ROOT/toolchain/juice-ios-lowva-bootstrap.h"
LOWVA_BOOTSTRAP_OBJECT="$WINE_BUILD/loader/main.o"
LOWVA_BOOTSTRAP_STAMP="$WINE_BUILD/.juice-ios-lowva-bootstrap.sha256"
STATIC_FREETYPE="${JUICE_STATIC_FREETYPE:-1}"
STATIC_FREETYPE_BUILD="${JUICE_STATIC_FREETYPE_BUILD:-$ROOT/build/freetype-static-ios}"
STATIC_FREETYPE_LIB="$STATIC_FREETYPE_BUILD/install/lib/libfreetype.a"
STATIC_FREETYPE_HEADER="$STATIC_FREETYPE_BUILD/shim/juice-static-freetype.h"
STATIC_FREETYPE_SONAME="juice-static-freetype"

# POSIX/FUSE overlays may not preserve executable mode bits reliably. Invoke
# repository shell helpers explicitly through bash so builds do not require
# sudo or manual chmod fixes on the backing filesystem.
bash "$ROOT/scripts/preflight-linux-x86_64.sh"

required_host_tools=(
  "$TOOLS/tools/makedep"
  "$TOOLS/tools/winebuild/winebuild"
  "$TOOLS/tools/winegcc/winegcc"
  "$TOOLS/tools/widl/widl"
  "$TOOLS/tools/wrc/wrc"
  "$TOOLS/tools/wmc/wmc"
)
need_host_tools=0
if test "${JUICE_REBUILD_HOST_TOOLS:-0}" = 1; then
  need_host_tools=1
else
  for tool in "${required_host_tools[@]}"; do
    if test ! -x "$tool"; then
      echo "JUICE_WINE_TOOL_MISSING path=$tool"
      need_host_tools=1
    fi
  done
fi
if test "$need_host_tools" = 1; then
  bash "$ROOT/scripts/build-wine-tools-linux.sh"
else
  echo "JUICE_WINE_TOOLS_REUSE path=$TOOLS count=${#required_host_tools[@]}"
fi

# iOS dyld is a poor place to discover a missing optional font dependency.
# Build FreeType into Wine's native win32u and DirectWrite Unix sides instead.
# The preparation script performs a one-time native configure migration while
# preserving every compiled Wine object that does not depend on the font setup.
if test "${JUICE_WITHOUT_FREETYPE:-0}" != 1 && test "$STATIC_FREETYPE" = 1; then
  bash "$ROOT/scripts/prepare-static-freetype-wine-linux.sh"
fi

# These iOS compatibility headers are force-included by the compiler wrapper,
# so Wine's generated dependency graph does not necessarily know that changing
# either header must rebuild its translation unit. Track both by content hash
# and discard only the affected object. Everything else remains incremental.
if test -f "$WINE_BUILD/Makefile" && test -f "$LOWVA_HEADER"; then
  lowva_hash="$(sha256sum "$LOWVA_HEADER" | awk '{print $1}')"
  old_lowva_hash="$(cat "$LOWVA_STAMP" 2>/dev/null || true)"
  if test "$lowva_hash" != "$old_lowva_hash"; then
    rm -f "$LOWVA_OBJECT"
    printf '%s\n' "$lowva_hash" > "$LOWVA_STAMP"
    echo "JUICE_IOS_LOWVA_OBJECT_REFRESH object=$LOWVA_OBJECT hash=$lowva_hash"
  else
    echo "JUICE_IOS_LOWVA_OBJECT_REUSE object=$LOWVA_OBJECT hash=$lowva_hash"
  fi
fi

if test -f "$WINE_BUILD/Makefile" && test -f "$LOWVA_BOOTSTRAP_HEADER"; then
  bootstrap_hash="$(sha256sum "$LOWVA_BOOTSTRAP_HEADER" | awk '{print $1}')"
  old_bootstrap_hash="$(cat "$LOWVA_BOOTSTRAP_STAMP" 2>/dev/null || true)"
  if test "$bootstrap_hash" != "$old_bootstrap_hash"; then
    rm -f "$LOWVA_BOOTSTRAP_OBJECT" "$WINE_BUILD/loader/wine"
    printf '%s\n' "$bootstrap_hash" > "$LOWVA_BOOTSTRAP_STAMP"
    echo "JUICE_IOS_LOWVA_BOOTSTRAP_REFRESH object=$LOWVA_BOOTSTRAP_OBJECT hash=$bootstrap_hash"
  else
    echo "JUICE_IOS_LOWVA_BOOTSTRAP_REUSE object=$LOWVA_BOOTSTRAP_OBJECT hash=$bootstrap_hash"
  fi
fi

# Older builds used a bundled dylib loaded with SONAME_LIBFREETYPE. Keep that
# path as an opt-out fallback, but the default Linux build now requires the
# static resolver prepared above. This avoids silently reverting a cached tree
# to the runtime dlopen path after it was migrated.
freetype_reconfigure=0
if test "${JUICE_WITHOUT_FREETYPE:-0}" != 1 && test -f "$WINE_BUILD/Makefile"; then
  native_config="$WINE_BUILD/include/config.h"
  if test "$STATIC_FREETYPE" = 1; then
    grep -Fq "#define SONAME_LIBFREETYPE \"$STATIC_FREETYPE_SONAME\"" "$native_config" || {
      echo "Static FreeType preparation did not persist in $native_config." >&2
      exit 5
    }
    grep -Fq "$STATIC_FREETYPE_LIB" "$WINE_BUILD/Makefile" || {
      echo "Static FreeType archive is missing from the native Wine Makefile." >&2
      exit 5
    }
    grep -Fq "$STATIC_FREETYPE_HEADER" "$WINE_BUILD/Makefile" || {
      echo "Static FreeType shim is missing from the native Wine Makefile." >&2
      exit 5
    }
    echo "JUICE_FREETYPE_CONFIG_REUSE mode=static path=$native_config soname=$STATIC_FREETYPE_SONAME"
  elif ! grep -q '^#define HAVE_FT2BUILD_H 1' "$native_config" 2>/dev/null; then
    echo "JUICE_FREETYPE_CONFIG_REPAIR mode=reconfigure reason=missing-header path=$native_config"
    freetype_reconfigure=1
  else
    ROOTLESS="${JUICE_IOS_ROOTLESS_SYSROOT:-$ROOT/build/deps/rootless-sysroot}"
    freetype_soname="$(JUICE_IOS_ROOTLESS_SYSROOT="$ROOTLESS" bash "$ROOT/scripts/detect-freetype-soname-linux.sh")"
    freetype_runtime_name="@executable_path/../../../../Libraries/$freetype_soname"
    if grep -Fq "#define SONAME_LIBFREETYPE \"$freetype_runtime_name\"" "$native_config"; then
      echo "JUICE_FREETYPE_CONFIG_REUSE mode=dynamic path=$native_config soname=$freetype_runtime_name"
    else
      python3 - "$native_config" "$freetype_runtime_name" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
soname = sys.argv[2]
text = path.read_text(encoding="utf-8", errors="surrogateescape")
pattern = re.compile(
    r'(?m)^(?:/\* #undef SONAME_LIBFREETYPE \*/|#define SONAME_LIBFREETYPE ".*")$'
)
replacement = f'#define SONAME_LIBFREETYPE "{soname}"'
if not pattern.search(text):
    raise SystemExit(f"Wine config.h has no SONAME_LIBFREETYPE slot: {path}")
text = pattern.sub(replacement, text, count=1)
temporary = path.with_name(path.name + ".juice-freetype-new")
temporary.write_text(text, encoding="utf-8", errors="surrogateescape")
temporary.replace(path)
PY
      echo "JUICE_FREETYPE_CONFIG_RETROFIT mode=dynamic path=$native_config soname=$freetype_runtime_name"
    fi
  fi
fi

if test "$STATIC_FREETYPE" = 1 && test "${JUICE_WITHOUT_FREETYPE:-0}" != 1; then
  test -f "$WINE_BUILD/Makefile" || { echo "Static FreeType preparation did not configure native Wine." >&2; exit 5; }
  echo "JUICE_WINE_CONFIGURE_REUSE path=$WINE_BUILD mode=static-freetype"
elif test "${JUICE_RECONFIGURE:-0}" = 1 || test ! -f "$WINE_BUILD/Makefile" || test "$freetype_reconfigure" = 1; then
  bash "$ROOT/scripts/configure-wine-linux.sh"
else
  echo "JUICE_WINE_CONFIGURE_REUSE path=$WINE_BUILD"
fi
if test "${JUICE_RECONFIGURE:-0}" = 1 || test ! -f "$PE_BUILD/Makefile"; then
  bash "$ROOT/scripts/configure-wine-pe-linux.sh"
else
  echo "JUICE_PE_CONFIGURE_REUSE path=$PE_BUILD"
fi

bash "$ROOT/scripts/build-wine-linux.sh"

# Reuse the upstream app/runtime assembly paths; they inherit these cross-build inputs.
export CC="${JUICE_IOS_CC:-$ROOT/toolchain/juice-ios-cc}"
export IOS_SDK="${IOS_SDK:?Set IOS_SDK to an iPhoneOS device SDK directory}"
export JUICE_IOS_TOOLCHAIN="${JUICE_IOS_TOOLCHAIN:-$ROOT/build/ios-toolchain}"
bash "$ROOT/scripts/assemble-runtime.sh"

x64_stage=""
if test "${JUICE_BUILD_X64:-0}" = 1; then
  bash "$ROOT/scripts/build-experimental-x86_64-linux.sh"
  x64_stage="${JUICE_X64_RUNTIME_STAGE:-$ROOT/build/x86_64-runtime-stage}"
fi

export JUICE_REQUIRE_SIGNING=1
if test -n "$x64_stage"; then
  export JUICE_X64_RUNTIME_STAGE="$x64_stage"
fi
if test -n "$OUTPUT"; then
  bash "$ROOT/scripts/package-tipa.sh" "$OUTPUT"
else
  bash "$ROOT/scripts/package-tipa.sh"
fi

echo "JUICE_LINUX_X86_64_BUILD_OK x64=${JUICE_BUILD_X64:-0} static_freetype=$STATIC_FREETYPE"
