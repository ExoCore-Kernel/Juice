#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/x86_64-build.env"
SOURCE="${JUICE_FEX_SOURCE:-$ROOT/build/fex-source}"
PATCH="$ROOT/patches/fex-juice-ios.patch"
RPMALLOC_SOURCE="$SOURCE/External/rpmalloc"
RPMALLOC_PATCH="$ROOT/patches/fex-rpmalloc-juice-ios.patch"

test -d "$SOURCE/.git" || { echo "Run scripts/fetch-fex-linux.sh first." >&2; exit 2; }
test "$(git -C "$SOURCE" rev-parse HEAD)" = "$JUICE_FEX_REVISION" || {
  echo "FEX source is not at the pinned revision." >&2
  exit 2
}
git -C "$SOURCE" diff --check
test "$(git -C "$RPMALLOC_SOURCE" rev-parse HEAD)" = "$JUICE_FEX_RPMALLOC_REVISION" || {
  echo "FEX rpmalloc submodule is not at the pinned revision." >&2
  exit 2
}
git -C "$RPMALLOC_SOURCE" diff --check
git -C "$SOURCE" apply --reverse --check "$PATCH"
git -C "$RPMALLOC_SOURCE" apply --reverse --check "$RPMALLOC_PATCH"
temporary="$(mktemp "$ROOT/build/fex-patch-verify.XXXXXX")"
rpmalloc_temporary="$(mktemp "$ROOT/build/fex-rpmalloc-patch-verify.XXXXXX")"
cleanup()
{
  case "$temporary" in "$ROOT"/build/fex-patch-verify.*) rm -f "$temporary";; esac
  case "$rpmalloc_temporary" in "$ROOT"/build/fex-rpmalloc-patch-verify.*) rm -f "$rpmalloc_temporary";; esac
}
trap cleanup EXIT
git -C "$SOURCE" diff --no-ext-diff --src-prefix=a/ --dst-prefix=b/ \
  --output="$temporary" -- . ':(exclude)External/rpmalloc'
git -C "$RPMALLOC_SOURCE" diff --no-ext-diff --src-prefix=a/ --dst-prefix=b/ \
  --output="$rpmalloc_temporary"
cmp -s "$temporary" "$PATCH" || {
  echo "patches/fex-juice-ios.patch is stale." >&2
  exit 3
}
cmp -s "$rpmalloc_temporary" "$RPMALLOC_PATCH" || {
  echo "patches/fex-rpmalloc-juice-ios.patch is stale." >&2
  exit 3
}
echo "JUICE_FEX_PATCH_OK revision=$JUICE_FEX_REVISION rpmalloc_revision=$JUICE_FEX_RPMALLOC_REVISION"
