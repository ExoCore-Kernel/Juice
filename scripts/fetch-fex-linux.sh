#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
source "$ROOT/config/x86_64-build.env"
SOURCE="${JUICE_FEX_SOURCE:-$ROOT/build/fex-source}"
PATCH="$ROOT/patches/fex-juice-ios.patch"
RPMALLOC_PATCH="$ROOT/patches/fex-rpmalloc-juice-ios.patch"

test "$(uname -s)" = Linux || { echo "FEX source preparation requires Linux." >&2; exit 2; }
case "$SOURCE" in
  "$ROOT"/build/*) ;;
  *) test "${JUICE_ALLOW_EXTERNAL_BUILD:-0}" = 1 || {
       echo "Refusing FEX source outside build/: $SOURCE" >&2
       exit 2
     };;
esac
test -s "$PATCH" || { echo "Missing FEX iOS patch: $PATCH" >&2; exit 2; }
test -s "$RPMALLOC_PATCH" || { echo "Missing FEX rpmalloc iOS patch: $RPMALLOC_PATCH" >&2; exit 2; }

if test ! -d "$SOURCE/.git"; then
  if test -d "$SOURCE" && test -n "$(find "$SOURCE" -mindepth 1 -print -quit)"; then
    echo "Refusing non-empty non-Git FEX source directory: $SOURCE" >&2
    exit 3
  fi
  mkdir -p "$SOURCE"
  git -C "$SOURCE" init
  git -C "$SOURCE" remote add origin "$JUICE_FEX_REPOSITORY"
fi

origin="$(git -C "$SOURCE" remote get-url origin)"
test "$origin" = "$JUICE_FEX_REPOSITORY" || {
  echo "Unexpected FEX origin: $origin" >&2
  exit 3
}
head="$(git -C "$SOURCE" rev-parse HEAD 2>/dev/null || true)"
if test "$head" != "$JUICE_FEX_REVISION"; then
  test -z "$(git -C "$SOURCE" status --porcelain)" || {
    echo "FEX checkout has local changes at the wrong revision." >&2
    exit 3
  }
  git -C "$SOURCE" fetch --depth 1 origin "$JUICE_FEX_REVISION"
  git -C "$SOURCE" checkout --detach FETCH_HEAD
fi
test "$(git -C "$SOURCE" rev-parse HEAD)" = "$JUICE_FEX_REVISION"

git -C "$SOURCE" submodule update --init --recursive --depth 1
RPMALLOC_SOURCE="$SOURCE/External/rpmalloc"
test "$(git -C "$RPMALLOC_SOURCE" rev-parse HEAD)" = "$JUICE_FEX_RPMALLOC_REVISION" || {
  echo "FEX rpmalloc submodule is not at the pinned revision." >&2
  exit 3
}
if git -C "$SOURCE" apply --reverse --check "$PATCH" 2>/dev/null; then
  :
else
  git -C "$SOURCE" apply --check "$PATCH"
  git -C "$SOURCE" apply "$PATCH"
fi
if git -C "$RPMALLOC_SOURCE" apply --reverse --check "$RPMALLOC_PATCH" 2>/dev/null; then
  :
else
  git -C "$RPMALLOC_SOURCE" apply --check "$RPMALLOC_PATCH"
  git -C "$RPMALLOC_SOURCE" apply "$RPMALLOC_PATCH"
fi
git -C "$SOURCE" diff --check
git -C "$RPMALLOC_SOURCE" diff --check
echo "JUICE_FEX_SOURCE_OK path=$SOURCE revision=$JUICE_FEX_REVISION"
