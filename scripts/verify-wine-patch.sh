#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PATCH="$ROOT/patches/wine-ios.patch"
BASE_FILE="$ROOT/config/wine-base.txt"

test -s "$PATCH" || { echo "Missing Wine patch: $PATCH" >&2; exit 2; }
test -s "$BASE_FILE" || { echo "Missing Wine base revision: $BASE_FILE" >&2; exit 2; }
base="$(tr -d '[:space:]' < "$BASE_FILE")"
case "$base" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
    test "${#base}" -eq 40 || { echo "Invalid Wine base commit: $base" >&2; exit 2; };;
  *) echo "Invalid Wine base commit: $base" >&2; exit 2;;
esac

(
  cd "$ROOT"
  git apply --reverse --check --directory=wine patches/wine-ios.patch
)

path_count="$(grep -c '^diff --git a/' "$PATCH")"
test "$path_count" -ge 25 || {
  echo "Wine patch contains only $path_count paths; expected the complete iOS delta." >&2
  exit 3
}
grep -Fq ' b/UPSTREAM-JUICE.txt' "$PATCH" || {
  echo "Wine patch is missing UPSTREAM-JUICE.txt" >&2
  exit 3
}
for path in Makefile.in dllmain.c iosdrv.c iosdrv.h ipc.c ipc.h; do
  grep -Fq " b/dlls/wineios.drv/$path" "$PATCH" || {
    echo "Wine patch is missing dlls/wineios.drv/$path" >&2
    exit 3
  }
done

echo "JUICE_WINE_PATCH_VERIFY_OK base=$base paths=$path_count"
