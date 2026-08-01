#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TIPA="${1:-}"
if test -z "$TIPA"; then
  shopt -s nullglob
  candidates=("$ROOT"/dist/*.tipa)
  shopt -u nullglob
  test "${#candidates[@]}" -gt 0 || {
    echo "No .tipa files found beneath $ROOT/dist." >&2; exit 2;
  }
  TIPA="${candidates[0]}"
  for candidate in "${candidates[@]:1}"; do
    test "$candidate" -nt "$TIPA" && TIPA="$candidate"
  done
fi
test -f "$TIPA" || { echo "TIPA not found: $TIPA" >&2; exit 2; }
HELPER="$(find /var/containers/Bundle/Application -type f \
  -path '*/TrollStore.app/trollstorehelper' -print -quit 2>/dev/null)"
test -x "$HELPER" || { echo "TrollStore helper was not found." >&2; exit 3; }
"${SUDO:-/var/jb/usr/bin/sudo}" "$HELPER" install force "$TIPA"
echo "JUICE_TIPA_INSTALLED path=$TIPA"
