#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
VERSION="${JUICE_IOS_SDK_VERSION:-16.5}"
SDK_NAME="iPhoneOS${VERSION}.sdk"
REPO="${JUICE_THEOS_SDK_REPOSITORY:-https://github.com/theos/sdks.git}"
REF="${JUICE_THEOS_SDK_REF:-master}"
CACHE="${JUICE_THEOS_SDK_CACHE:-$ROOT/build/deps/theos-sdks}"
SDK="$CACHE/$SDK_NAME"

case "$(uname -s)" in Linux) ;; *) echo "The automatic SDK fetcher is for Linux hosts." >&2; exit 2;; esac
for tool in git python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing SDK fetch dependency: $tool" >&2; exit 2; }
done

valid_sdk()
{
  test -d "$1/System/Library/Frameworks/UIKit.framework" &&
    { test -e "$1/usr/lib/libSystem.tbd" || test -e "$1/usr/lib/libSystem.dylib"; }
}

if test -n "${IOS_SDK:-}"; then
  valid_sdk "$IOS_SDK" || { echo "IOS_SDK is set but is not a usable iPhoneOS SDK: $IOS_SDK" >&2; exit 3; }
  echo "JUICE_IOS_SDK_OK path=$(readlink -f "$IOS_SDK") source=environment"
  exit 0
fi

if valid_sdk "$SDK" && test "${JUICE_REFRESH_DEPS:-0}" != 1; then
  echo "JUICE_IOS_SDK_OK path=$SDK source=theos cached=1 version=$VERSION"
  exit 0
fi

mkdir -p "$(dirname "$CACHE")"
if test ! -d "$CACHE/.git"; then
  rm -rf "$CACHE"
  git clone --depth 1 --filter=blob:none --sparse --branch "$REF" "$REPO" "$CACHE"
else
  git -C "$CACHE" remote set-url origin "$REPO"
  git -C "$CACHE" fetch --depth 1 origin "$REF"
  git -C "$CACHE" checkout --detach FETCH_HEAD
fi

git -C "$CACHE" sparse-checkout init --cone
git -C "$CACHE" sparse-checkout set "$SDK_NAME"
# A fresh sparse clone is already on REF; an existing cache is detached at FETCH_HEAD.
git -C "$CACHE" checkout -f HEAD -- "$SDK_NAME" 2>/dev/null || true

valid_sdk "$SDK" || {
  echo "The requested SDK '$SDK_NAME' was not found or is incomplete in $REPO at $REF." >&2
  echo "Set JUICE_IOS_SDK_VERSION to an SDK available in theos/sdks (for example 15.6 or 16.5), or set IOS_SDK manually." >&2
  exit 4
}

mkdir -p "$ROOT/build/deps"
printf '%s\n' "$SDK" > "$ROOT/build/deps/ios-sdk.path"
echo "JUICE_IOS_SDK_OK path=$SDK source=theos cached=0 version=$VERSION ref=$REF"
