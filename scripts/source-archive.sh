#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist/Juice-source-$(date +%Y%m%d-%H%M%S).tar.gz}"
mkdir -p "$(dirname "$OUT")"
tar -C "$(dirname "$ROOT")" --exclude='Juice/.git' --exclude='Juice/build' \
  --exclude='Juice/dist' --exclude='__pycache__' -czf "$OUT" "$(basename "$ROOT")"
gzip -t "$OUT"
if command -v sha256sum >/dev/null 2>&1; then
  digest="$(sha256sum "$OUT" | awk '{print $1}')"
else
  digest="$(shasum -a 256 "$OUT" | awk '{print $1}')"
fi
printf '%s  %s\n' "$digest" "$(basename "$OUT")" > "$OUT.sha256"
echo "JUICE_SOURCE_ARCHIVE_OK path=$OUT sha256=$digest"
