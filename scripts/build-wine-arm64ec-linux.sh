#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/x86_64-build.env"
CACHE="${JUICE_X64_CACHE:-$ROOT/build/x86_64-cache}"
TOOLCHAIN="$CACHE/$JUICE_LLVM_MINGW_DIRNAME"
BUILD="${JUICE_ARM64EC_PE_BUILD:-$ROOT/build/wine-arm64ec-pe}"
MODULES="${JUICE_X64_RUNTIME_MODULES:-$ROOT/config/runtime-modules.txt}"
JOBS="${JUICE_JOBS:-$(getconf _NPROCESSORS_ONLN)}"
MAKE="${MAKE:-make}"
SHELL_BIN="${SHELL_BIN:-/bin/bash}"
REAL_CLANG="${JUICE_ARM64EC_REAL_CLANG:-$TOOLCHAIN/bin/clang}"
PE_WRAPPER="${JUICE_ARM64EC_PE_WRAPPER:-$ROOT/build/toolchain-linux/clang}"
PE_PACKER="${JUICE_INCBIN_PACKER:-$ROOT/toolchain/juice-pack-incbins.py}"
PE_PYTHON="${JUICE_PYTHON:-$(command -v python3 || true)}"
LOGDIR="${JUICE_BUILD_LOG_DIR:-$ROOT/build/logs}"

if test "${JUICE_ARM64EC_RECONFIGURE:-${JUICE_RECONFIGURE:-0}}" = 1 || test ! -f "$BUILD/Makefile"; then
  "$ROOT/scripts/configure-wine-arm64ec-linux.sh"
else
  echo "JUICE_ARM64EC_CONFIGURE_REUSE path=$BUILD"
fi
export PATH="$TOOLCHAIN/bin:/usr/local/bin:/usr/bin:/bin"

test -x "$REAL_CLANG" || { echo "Missing llvm-mingw Clang for ARM64EC: $REAL_CLANG" >&2; exit 2; }
test -n "$PE_PYTHON" -a -x "$PE_PYTHON" || { echo "Missing Python 3 for ARM64EC resource packing." >&2; exit 2; }
test -r "$PE_PACKER" || { echo "Missing PE incbin packer: $PE_PACKER" >&2; exit 2; }
mkdir -p "$LOGDIR"

# Winebuild emits temporary assembly containing many .incbin slices of .res
# files. On FUSE/POSIX overlay build directories Clang's integrated assembler
# can fail to reopen those resource paths even though Winebuild just read them.
# Reuse Juice's proven resource-aware compiler wrapper: it collapses the
# slices into a single local blob before invoking the real llvm-mingw Clang.
JUICE_PE_WRAPPER="$PE_WRAPPER" \
JUICE_REAL_PE_CLANG="$REAL_CLANG" \
JUICE_PYTHON="$PE_PYTHON" \
JUICE_INCBIN_PACKER="$PE_PACKER" \
  "$ROOT/scripts/build-pe-compiler-wrapper-linux.sh"
export JUICE_REAL_PE_CLANG="$REAL_CLANG"
export JUICE_PYTHON="$PE_PYTHON"
export JUICE_INCBIN_PACKER="$PE_PACKER"
export JUICE_PE_BUILD_DIR="$BUILD"

# Cached ARM64EC configure trees have the discovered compiler (normally
# "clang") baked both into arm64ec_CC/aarch64_CC and literal --cc-cmd values.
# Retrofit those fields in place instead of throwing the expensive configure
# tree away. The wrapper preserves all -target arm64ec/aarch64 flags.
"$PE_PYTHON" - "$BUILD/Makefile" "$PE_WRAPPER" <<'PY'
from pathlib import Path
import re
import sys

makefile = Path(sys.argv[1])
wrapper = sys.argv[2]
text = makefile.read_text(encoding="utf-8", errors="surrogateescape")
old_compilers = set()
changed = False

for arch in ("arm64ec", "aarch64"):
    pattern = re.compile(rf"(?m)^({re.escape(arch)}_CC[ \t]*=[ \t]*)(.*)$")
    match = pattern.search(text)
    if not match:
        raise SystemExit(f"ARM64EC Makefile has no {arch}_CC assignment")
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
    print(f"JUICE_ARM64EC_MAKEFILE_WRAPPER_RETROFIT path={makefile} compiler={wrapper}")
else:
    print(f"JUICE_ARM64EC_MAKEFILE_WRAPPER_REUSE path={makefile} compiler={wrapper}")

check = makefile.read_text(encoding="utf-8", errors="surrogateescape")
for arch in ("arm64ec", "aarch64"):
    if not re.search(rf"(?m)^{re.escape(arch)}_CC[ \t]*=[ \t]*{re.escape(wrapper)}$", check):
        raise SystemExit(f"ARM64EC Makefile did not retain wrapper for {arch}_CC")
if f'--cc-cmd="{wrapper}"' not in check:
    raise SystemExit("ARM64EC Makefile has no resource-aware --cc-cmd wrapper")
PY

mapfile -t manifest_targets < <(sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$MODULES")
test "${#manifest_targets[@]}" -gt 0 || { echo "Hybrid runtime manifest is empty." >&2; exit 2; }

# ARM64X is required for Wine DLLs/drivers that contain executable code. Helper
# EXEs do not need to be hybrid: Grape-X64 starts as a copy of the verified ARM64
# Grape runtime and can execute ARM64 helper programs natively. Wine also has a
# small set of data-only PE images such as apisetschema.dll. They contain no
# architecture-specific executable code, and winebuild intentionally emits the
# aarch64-windows target as ordinary COFF-ARM64 even in a multiarch ARM64EC tree.
# Keep those data images native instead of rejecting a correct build for not
# being COFF-ARM64X.
hybrid_targets=()
program_count=0
for target in "${manifest_targets[@]}"; do
  case "$target" in
    programs/*) program_count=$((program_count + 1)) ;;
    *) hybrid_targets+=("$target") ;;
  esac
done

test "${#hybrid_targets[@]}" -gt 0 || { echo "Hybrid DLL target list is empty." >&2; exit 2; }
echo "JUICE_ARM64EC_TARGETS hybrid=${#hybrid_targets[@]} arm64_program_fallback=$program_count"

# Keep the fast parallel path. POSIX overlays can still expose transient
# dependency races under a very wide -j build, so if it fails, retry the same
# target list serially. Make keeps every successful object from the first pass;
# no reconfigure and no clean are performed.
LOG="$LOGDIR/wine-arm64ec.log"
RETRY_LOG="$LOGDIR/wine-arm64ec-retry.log"
echo "JUICE_ARM64EC_BUILD_STAGE jobs=$JOBS log=$LOG"
set +e
"$MAKE" --output-sync=target -C "$BUILD" -j"$JOBS" \
  SHELL="$SHELL_BIN" PWD="$BUILD" \
  "arm64ec_CC=$PE_WRAPPER" "aarch64_CC=$PE_WRAPPER" \
  "${hybrid_targets[@]}" 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}
set -e

if test "$status" -ne 0; then
  echo "JUICE_ARM64EC_PARALLEL_RETRY status=$status log=$RETRY_LOG"
  : > "$RETRY_LOG"
  for target in "${hybrid_targets[@]}"; do
    echo "===== $target =====" | tee -a "$RETRY_LOG"
    set +e
    "$MAKE" --output-sync=target -C "$BUILD" -j1 \
      SHELL="$SHELL_BIN" PWD="$BUILD" \
      "arm64ec_CC=$PE_WRAPPER" "aarch64_CC=$PE_WRAPPER" \
      "$target" 2>&1 | tee -a "$RETRY_LOG"
    status=${PIPESTATUS[0]}
    set -e
    if test "$status" -ne 0; then
      echo "JUICE_ARM64EC_BUILD_FAILED target=$target status=$status log=$RETRY_LOG" >&2
      echo "---- likely ARM64EC error lines ----" >&2
      grep -Ei -C 3 'fatal error:|error:|undefined reference|unresolved external|incbin|winebuild:|winegcc:|ld\.lld:|lld-link:|clang[^:]*: error|make(\[[0-9]+\])?: \*\*\*' "$RETRY_LOG" | tail -n 160 >&2 || true
      exit "$status"
    fi
  done
  echo "JUICE_ARM64EC_SERIAL_RECOVERY_OK modules=${#hybrid_targets[@]}"
fi

bad=0
for target in "${hybrid_targets[@]}"; do
  module="$BUILD/$target"
  test -s "$module" || { echo "Missing hybrid module: $target" >&2; bad=$((bad + 1)); continue; }
  format="$("$TOOLCHAIN/bin/llvm-readobj" --file-headers "$module" 2>/dev/null |
    sed -n 's/^Format: //p')"
  case "$target" in
    dlls/apisetschema/aarch64-windows/apisetschema.dll)
      valid_formats=" COFF-ARM64 COFF-ARM64X "
      ;;
    *)
      valid_formats=" COFF-ARM64X "
      ;;
  esac
  if [[ "$valid_formats" != *" $format "* ]]; then
    echo "Unexpected hybrid format $format: $target" >&2
    bad=$((bad + 1))
  elif test "$format" = COFF-ARM64; then
    echo "JUICE_ARM64EC_NATIVE_DATA_MODULE target=$target format=$format"
  fi
done
test "$bad" -eq 0
echo "JUICE_ARM64EC_BUILD_OK path=$BUILD hybrid_modules=${#hybrid_targets[@]} arm64_programs=$program_count"
