#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
SDK="${IOS_SDK:-}"
REV="${JUICE_CCTOOLS_REVISION:-1030.6.3-ld64-956.6}"
REPO="${JUICE_CCTOOLS_REPOSITORY:-https://github.com/tpoechtrager/cctools-port.git}"
SOURCE="${JUICE_CCTOOLS_SOURCE:-$ROOT/build/cctools-port-source}"
DEST="${JUICE_IOS_TOOLCHAIN:-$ROOT/build/ios-toolchain}"
WORK="$ROOT/build/ios-toolchain-input"
JOBS="${JOBS:-${JUICE_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)}}"

case "$(uname -s):$(uname -m)" in Linux:x86_64|Linux:amd64) ;; *) echo "This bootstrap target requires x86_64 Linux." >&2; exit 2;; esac
test -d "$SDK" || {
  echo "Set IOS_SDK to an iPhoneOS device SDK directory before bootstrapping cctools-port." >&2
  exit 2
}
SDK="$(readlink -f "$SDK")"
for tool in bash cc clang cmake git make python3 tar xz; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing cctools bootstrap dependency: $tool" >&2; exit 2; }
done

mkdir -p "$ROOT/build" "$WORK"
if test ! -d "$SOURCE/.git"; then
  git clone "$REPO" "$SOURCE"
fi
git -C "$SOURCE" fetch --depth 1 origin "$REV" || git -C "$SOURCE" fetch origin "$REV"
git -C "$SOURCE" checkout --detach FETCH_HEAD

sdk_version="${JUICE_IOS_SDK_VERSION:-}"
if test -z "$sdk_version"; then
  sdk_version="$(python3 - "$SDK" <<'PY'
import pathlib, plistlib, re, sys
sdk = pathlib.Path(sys.argv[1])
m = re.search(r'(\d+(?:\.\d+)+)', sdk.name)
if m:
    print(m.group(1)); raise SystemExit
for rel in ('SDKSettings.plist','System/Library/CoreServices/SystemVersion.plist'):
    p=sdk/rel
    if p.exists():
        try:
            d=plistlib.loads(p.read_bytes())
            for key in ('Version','ProductVersion','CanonicalName'):
                value=str(d.get(key,''))
                m=re.search(r'(\d+(?:\.\d+)+)', value)
                if m:
                    print(m.group(1)); raise SystemExit
        except Exception:
            pass
PY
)"
fi
test -n "$sdk_version" || {
  echo "Could not determine the SDK version. Set JUICE_IOS_SDK_VERSION (for example 18.5)." >&2
  exit 3
}

archive="$WORK/iPhoneOS${sdk_version}.sdk.tar.xz"
rm -f "$archive"
# cctools-port expects the SDK directory itself as the archive's top-level item.
tar -C "$(dirname "$SDK")" -cJf "$archive" "$(basename "$SDK")"

example="$SOURCE/usage_examples/ios_toolchain"
test -x "$example/build.sh" || chmod +x "$example/build.sh"
rm -rf "$example/target"
(
  cd "$example"
  JOBS="$JOBS" ./build.sh "$archive" arm64
)

test -x "$example/target/bin/arm-apple-darwin11-clang" || {
  echo "cctools-port finished without the expected arm64 iOS compiler." >&2
  exit 4
}
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
mv "$example/target" "$DEST"

echo "JUICE_IOS_TOOLCHAIN_OK path=$DEST revision=$REV sdk=$sdk_version"
