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

case "$(uname -s):$(uname -m)" in
  Linux:x86_64|Linux:amd64|Linux:aarch64|Linux:arm64) ;;
  *) echo "This bootstrap target requires a 64-bit x86 or ARM Linux host." >&2; exit 2;;
esac
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
# cctools-port expects the SDK directory itself as the archive's top-level item.
# Keep a completed input archive when the SDK has not changed; compressing the
# SDK is otherwise a substantial fraction of bootstrap time on ARM build hosts.
if test ! -s "$archive" || test -n "$(find "$SDK" -type f -newer "$archive" -print -quit)"; then
  temporary_archive="$archive.new.$$"
  trap 'rm -f "$temporary_archive"' EXIT INT TERM
  tar -C "$(dirname "$SDK")" -cJf "$temporary_archive" "$(basename "$SDK")"
  mv "$temporary_archive" "$archive"
  trap - EXIT INT TERM
fi

example="$SOURCE/usage_examples/ios_toolchain"
test -x "$example/build.sh" || chmod +x "$example/build.sh"
rm -rf "$example/target"
# The upstream example extracts the SDK version from its argv path. Passing an
# absolute checkout path containing strings such as "x86_64" makes it mistake
# that directory component for the iOS version. A version-only symlink keeps
# the upstream parser deterministic regardless of the checkout name.
example_archive="$example/iPhoneOS${sdk_version}.sdk.tar.xz"
ln -sfn "$archive" "$example_archive"
(
  cd "$example"
  # build.sh changes into target/SDK before extracting the argv path.
  JOBS="$JOBS" ./build.sh "../../$(basename "$example_archive")" arm64
)
rm -f "$example_archive"

test -x "$example/target/bin/arm-apple-darwin11-clang" || {
  echo "cctools-port finished without the expected arm64 iOS compiler." >&2
  exit 4
}
rm -rf "$DEST"
mkdir -p "$(dirname "$DEST")"
mv "$example/target" "$DEST"

echo "JUICE_IOS_TOOLCHAIN_OK path=$DEST revision=$REV sdk=$sdk_version"
