#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/x86_64-build.env"
SOURCE="${JUICE_FEX_SOURCE:-$ROOT/build/fex-source}"
PATCH="$ROOT/patches/fex-juice-ios.patch"
EXPECTED=$'FEXCore/Source/Interface/Core/ArchHelpers/Arm64Emitter.cpp\nFEXCore/Source/Interface/Core/ArchHelpers/Arm64Emitter.h\nFEXCore/Source/Interface/Core/CPUBackend.cpp\nFEXCore/Source/Interface/Core/Dispatcher/Dispatcher.cpp\nFEXCore/Source/Interface/Core/Frontend.cpp\nFEXCore/Source/Interface/Core/JIT/BranchOps.cpp\nFEXCore/Source/Interface/Core/JIT/JIT.cpp\nFEXCore/Source/Interface/Core/JIT/MemoryOps.cpp\nFEXCore/Source/Interface/Core/JuiceIOSArm64EC.h\nFEXCore/Source/Interface/Core/LookupCache.cpp\nFEXCore/Source/Interface/Core/OpcodeDispatcher.cpp\nFEXCore/Source/Utils/AllocatorHooks.cpp\nFEXCore/include/FEXCore/Utils/AllocatorHooks.h\nSource/Windows/ARM64EC/Module.cpp\nSource/Windows/Common/Allocator.cpp\nSource/Windows/Common/CallRetStack.h\nSource/Windows/Common/Priv.h\nSource/Windows/Common/SHMStats.cpp\nSource/Windows/Common/WinAPI/Alloc.cpp\nSource/Windows/Defs/ntdll.def'

test -d "$SOURCE/.git" || { echo "Run scripts/fetch-fex-linux.sh first." >&2; exit 2; }
test "$(git -C "$SOURCE" rev-parse HEAD)" = "$JUICE_FEX_REVISION" || {
  echo "FEX source is not at the pinned revision." >&2
  exit 2
}
git -C "$SOURCE" diff --check
actual="$(git -C "$SOURCE" diff --name-only)"
test "$actual" = "$EXPECTED" || {
  echo "Unexpected FEX patch file set:" >&2
  printf '%s\n' "$actual" >&2
  exit 3
}
temporary="$(mktemp "$ROOT/patches/.fex-juice-ios.XXXXXX")"
cleanup()
{
  case "$temporary" in "$ROOT"/patches/.fex-juice-ios.*) rm -f "$temporary";; esac
}
trap cleanup EXIT
git -C "$SOURCE" diff --no-ext-diff --src-prefix=a/ --dst-prefix=b/ \
  --output="$temporary"
test -s "$temporary"
mv "$temporary" "$PATCH"
trap - EXIT
echo "JUICE_FEX_PATCH_REGENERATED path=$PATCH revision=$JUICE_FEX_REVISION"
