#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/x86_64-build.env"
CACHE="${JUICE_X64_CACHE:-$ROOT/build/x86_64-cache}"
TOOLCHAIN="$CACHE/$JUICE_LLVM_MINGW_DIRNAME"
BUILD="${JUICE_WOW64_PE_BUILD:-$ROOT/build/wine-wow64-pe}"
MODULES="${JUICE_X64_RUNTIME_MODULES:-$ROOT/config/runtime-modules.txt}"
JOBS="${JUICE_JOBS:-$(getconf _NPROCESSORS_ONLN)}"
MAKE="${MAKE:-make}"
SHELL_BIN="${SHELL_BIN:-/bin/bash}"
REAL_CLANG="${JUICE_WOW64_REAL_CLANG:-$TOOLCHAIN/bin/clang}"
PE_WRAPPER="${JUICE_WOW64_PE_WRAPPER:-$ROOT/build/toolchain-linux/clang}"
PE_PACKER="${JUICE_INCBIN_PACKER:-$ROOT/toolchain/juice-pack-incbins.py}"
PE_PYTHON="${JUICE_PYTHON:-$(command -v python3 || true)}"
LOGDIR="${JUICE_BUILD_LOG_DIR:-$ROOT/build/logs}"
LOADER_FIX_MARKER="$BUILD/.juice-i386-loader-init-v1"

if test "${JUICE_WOW64_RECONFIGURE:-${JUICE_RECONFIGURE:-0}}" = 1 || test ! -f "$BUILD/Makefile"; then
  bash "$ROOT/scripts/configure-wine-wow64-linux.sh"
else
  echo "JUICE_WOW64_CONFIGURE_REUSE path=$BUILD"
fi
export PATH="$TOOLCHAIN/bin:/usr/local/bin:/usr/bin:/bin"

test -x "$REAL_CLANG" || { echo "Missing llvm-mingw Clang for WoW64: $REAL_CLANG" >&2; exit 2; }
test -n "$PE_PYTHON" -a -x "$PE_PYTHON" || { echo "Missing Python 3 for WoW64 resource packing." >&2; exit 2; }
test -r "$PE_PACKER" || { echo "Missing PE incbin packer: $PE_PACKER" >&2; exit 2; }
mkdir -p "$LOGDIR"

# Winebuild embeds .res data through temporary assembly .incbin directives.
# Use the same resource-aware wrapper as the ARM64/ARM64EC Linux paths so FUSE
# or POSIX overlay storage cannot make the integrated assembler lose those
# resource paths while producing the i386/AArch64 PE modules.
JUICE_PE_WRAPPER="$PE_WRAPPER" \
JUICE_REAL_PE_CLANG="$REAL_CLANG" \
JUICE_PYTHON="$PE_PYTHON" \
JUICE_INCBIN_PACKER="$PE_PACKER" \
  bash "$ROOT/scripts/build-pe-compiler-wrapper-linux.sh"
export JUICE_REAL_PE_CLANG="$REAL_CLANG"
export JUICE_PYTHON="$PE_PYTHON"
export JUICE_INCBIN_PACKER="$PE_PACKER"
export JUICE_PE_BUILD_DIR="$BUILD"

# Preserve the cached configure tree. Replace only the discovered PE compiler
# assignments and the literal --cc-cmd values that makedep baked from them.
"$PE_PYTHON" - "$BUILD/Makefile" "$PE_WRAPPER" <<'PY'
from pathlib import Path
import re
import sys

makefile = Path(sys.argv[1])
wrapper = sys.argv[2]
text = makefile.read_text(encoding="utf-8", errors="surrogateescape")
old_compilers = set()
changed = False

for arch in ("i386", "aarch64"):
    pattern = re.compile(rf"(?m)^({re.escape(arch)}_CC[ \t]*=[ \t]*)(.*)$")
    match = pattern.search(text)
    if not match:
        raise SystemExit(f"WoW64 Makefile has no {arch}_CC assignment")
    old = match.group(2).strip()
    old_compilers.add(old)
    if old != wrapper:
        text = text[:match.start(2)] + wrapper + text[match.end(2):]
        changed = True

for old in old_compilers:
    old_cc_cmd = f'--cc-cmd="{old}"'
    new_cc_cmd = f'--cc-cmd="{wrapper}"'
    if old_cc_cmd in text:
        text = text.replace(old_cc_cmd, new_cc_cmd)
        changed = True

if changed:
    temporary = makefile.with_name(makefile.name + ".juice-wrapper-new")
    temporary.write_text(text, encoding="utf-8", errors="surrogateescape")
    temporary.replace(makefile)
    print(f"JUICE_WOW64_MAKEFILE_WRAPPER_RETROFIT path={makefile} compiler={wrapper}")
else:
    print(f"JUICE_WOW64_MAKEFILE_WRAPPER_REUSE path={makefile} compiler={wrapper}")

check = makefile.read_text(encoding="utf-8", errors="surrogateescape")
for arch in ("i386", "aarch64"):
    if not re.search(rf"(?m)^{re.escape(arch)}_CC[ \t]*=[ \t]*{re.escape(wrapper)}$", check):
        raise SystemExit(f"WoW64 Makefile did not retain wrapper for {arch}_CC")
if f'--cc-cmd="{wrapper}"' not in check:
    raise SystemExit("WoW64 Makefile has no resource-aware --cc-cmd wrapper")
PY

# Juice's direct ARM64 loader trampoline intentionally renames loader_init() to
# loader_init_impl() for the AArch64 PE build. The source-level condition also
# reaches the i386 WoW64 compile, but i386 has no AArch64 trampoline to recreate
# loader_init. The PE wrapper restores the upstream symbol only while compiling
# i386 ntdll/loader.c. Rebuild just that object and ntdll once; keep every other
# cached WoW64 object intact.
if test ! -f "$LOADER_FIX_MARKER" || test "$ROOT/toolchain/juice-pe-clang.c" -nt "$LOADER_FIX_MARKER"; then
  echo "JUICE_WOW64_LOADER_SYMBOL_REPAIR target=dlls/ntdll/i386-windows/ntdll.dll"
  rm -f "$BUILD/dlls/ntdll/i386-windows/loader.o" \
        "$BUILD/dlls/ntdll/i386-windows/ntdll.dll"
  "$MAKE" --output-sync=target -C "$BUILD" -j1 \
    SHELL="$SHELL_BIN" PWD="$BUILD" \
    "i386_CC=$PE_WRAPPER" "aarch64_CC=$PE_WRAPPER" \
    dlls/ntdll/i386-windows/ntdll.dll
  test -s "$BUILD/dlls/ntdll/i386-windows/ntdll.dll" || {
    echo "WoW64 i386 ntdll loader-symbol repair did not produce ntdll.dll" >&2
    exit 3
  }
  touch "$LOADER_FIX_MARKER"
  echo "JUICE_WOW64_LOADER_SYMBOL_OK path=$BUILD/dlls/ntdll/i386-windows/ntdll.dll"
fi

mapfile -t base_targets < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$MODULES")
targets=()
for target in "${base_targets[@]}"; do
  case "$target" in
    programs/juicegui/*|programs/juicetextsmoke/*) continue ;;
  esac
  targets+=("${target/aarch64-windows/i386-windows}")
done

test "${#targets[@]}" -gt 0 || { echo "WoW64 runtime target list is empty." >&2; exit 2; }

LOG="$LOGDIR/wine-wow64.log"
RETRY_LOG="$LOGDIR/wine-wow64-retry.log"
echo "JUICE_WOW64_BUILD_STAGE jobs=$JOBS log=$LOG"
set +e
"$MAKE" --output-sync=target -C "$BUILD" -j"$JOBS" \
  SHELL="$SHELL_BIN" PWD="$BUILD" \
  "i386_CC=$PE_WRAPPER" "aarch64_CC=$PE_WRAPPER" \
  "${targets[@]}" 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e

if test "$status" -ne 0; then
  echo "JUICE_WOW64_PARALLEL_RETRY status=$status log=$RETRY_LOG"
  : > "$RETRY_LOG"
  for target in "${targets[@]}"; do
    echo "===== $target =====" | tee -a "$RETRY_LOG"
    set +e
    "$MAKE" --output-sync=target -C "$BUILD" -j1 \
      SHELL="$SHELL_BIN" PWD="$BUILD" \
      "i386_CC=$PE_WRAPPER" "aarch64_CC=$PE_WRAPPER" \
      "$target" 2>&1 | tee -a "$RETRY_LOG"
    status=${PIPESTATUS[0]}
    set -e
    if test "$status" -ne 0; then
      echo "JUICE_WOW64_BUILD_FAILED target=$target status=$status log=$RETRY_LOG" >&2
      echo "---- likely WoW64 error lines ----" >&2
      grep -Ei -C 3 'fatal error:|error:|undefined reference|unresolved external|incbin|winebuild:|winegcc:|ld\.lld:|lld-link:|clang[^:]*: error|make(\[[0-9]+\])?: \*\*\*' "$RETRY_LOG" | tail -n 160 >&2 || true
      exit "$status"
    fi
  done
  echo "JUICE_WOW64_SERIAL_RECOVERY_OK modules=${#targets[@]}"
fi

bad=0
for target in "${targets[@]}"; do
  module="$BUILD/$target"
  test -s "$module" || { echo "Missing i386 module: $target" >&2; bad=$((bad + 1)); continue; }
  machine="$("$TOOLCHAIN/bin/llvm-readobj" --file-headers "$module" 2>/dev/null |
    sed -n 's/^  Machine: //p')"
  case "$machine" in
    IMAGE_FILE_MACHINE_I386*) ;;
    *) echo "Unexpected WoW64 module machine $machine: $target" >&2; bad=$((bad + 1));;
  esac
done

test "$bad" -eq 0
echo "JUICE_WOW64_BUILD_OK path=$BUILD modules=${#targets[@]}"
