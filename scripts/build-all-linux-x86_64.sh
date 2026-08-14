#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUTPUT="${JUICE_TIPA_OUTPUT:-}"
TOOLS="${JUICE_WINE_TOOLS_BUILD:-$ROOT/build/wine-tools-linux}"
WINE_BUILD="${JUICE_WINE_BUILD:-$ROOT/build/wine-ios}"
PE_BUILD="${JUICE_PE_BUILD:-$ROOT/build/wine-arm64-pe}"

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

# The first Linux cross-build implementation considered FreeType enabled when
# configure found ft2build.h. Wine's actual win32u renderer has a second gate:
# SONAME_LIBFREETYPE. Darwin soname discovery can fail while cross-configuring
# on Linux, leaving perfectly valid FreeType headers but compiling the renderer
# out. Repair that old cached configuration in place rather than discarding the
# configured tree or any already-built PE/FEX/WoW64 work.
freetype_reconfigure=0
if test "${JUICE_WITHOUT_FREETYPE:-0}" != 1 && test -f "$WINE_BUILD/Makefile"; then
  native_config="$WINE_BUILD/include/config.h"
  if ! grep -q '^#define HAVE_FT2BUILD_H 1' "$native_config" 2>/dev/null; then
    echo "JUICE_FREETYPE_CONFIG_REPAIR mode=reconfigure reason=missing-header path=$native_config"
    freetype_reconfigure=1
  else
    freetype_soname="$(bash "$ROOT/scripts/detect-freetype-soname-linux.sh")"
    if grep -Fq "#define SONAME_LIBFREETYPE \"$freetype_soname\"" "$native_config"; then
      echo "JUICE_FREETYPE_CONFIG_REUSE path=$native_config soname=$freetype_soname"
    else
      python3 - "$native_config" "$freetype_soname" <<'PY'
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
      echo "JUICE_FREETYPE_CONFIG_RETROFIT path=$native_config soname=$freetype_soname"
    fi
  fi
fi

if test "${JUICE_RECONFIGURE:-0}" = 1 || test ! -f "$WINE_BUILD/Makefile" || test "$freetype_reconfigure" = 1; then
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

echo "JUICE_LINUX_X86_64_BUILD_OK x64=${JUICE_BUILD_X64:-0}"
