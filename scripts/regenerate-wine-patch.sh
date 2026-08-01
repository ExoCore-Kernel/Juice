#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
UPSTREAM="${1:-}"
BASE="$(tr -d '[:space:]' < "$ROOT/config/wine-base.txt")"
OUTPUT="$ROOT/patches/wine-ios.patch"

test -n "$UPSTREAM" || {
  echo "Usage: $0 /path/to/upstream-wine-git-checkout" >&2
  exit 2
}
git -C "$UPSTREAM" rev-parse --git-dir >/dev/null 2>&1 || {
  echo "Not a Wine Git checkout: $UPSTREAM" >&2
  exit 2
}
git -C "$UPSTREAM" cat-file -e "$BASE^{commit}" || {
  echo "Upstream checkout does not contain $BASE" >&2
  exit 3
}

work="$(mktemp -d /tmp/juice-wine-patch.XXXXXX)"
temporary="$(mktemp "$ROOT/patches/wine-ios.patch.XXXXXX")"
registered=0
cleanup()
{
  if test "$registered" = 1; then
    git -C "$UPSTREAM" worktree remove --force "$work" >/dev/null 2>&1 || true
  else
    rmdir "$work" >/dev/null 2>&1 || true
  fi
  rm -f "$temporary"
}
trap cleanup EXIT

git -C "$UPSTREAM" worktree add --detach "$work" "$BASE"
registered=1
rsync -a --delete --exclude=.git "$ROOT/wine/" "$work/"
git -C "$work" add -N .
git -C "$work" diff --check
git -C "$work" diff --binary HEAD > "$temporary"
test -s "$temporary" || { echo "Generated Wine patch is empty." >&2; exit 4; }
mv "$temporary" "$OUTPUT"
"$ROOT/scripts/verify-wine-patch.sh"
echo "JUICE_WINE_PATCH_REGENERATED path=$OUTPUT"
