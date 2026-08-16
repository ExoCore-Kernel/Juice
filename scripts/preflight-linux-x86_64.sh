#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
TOOLCHAIN="${JUICE_IOS_TOOLCHAIN:-$ROOT/build/ios-toolchain}"
PREFIX="${JUICE_IOS_TRIPLE_PREFIX:-arm-apple-darwin11}"
SDK="${IOS_SDK:-}"
ROOTLESS="${JUICE_IOS_ROOTLESS_SYSROOT:-}"
MIN_FREE_KB="${JUICE_MIN_FREE_KB:-8388608}"
MIN_IOS="${JUICE_MIN_IOS:-14.0}"
missing=()

test "$(uname -s)" = Linux || { echo "The x86_64 Linux build must run on Linux." >&2; exit 2; }
case "$(uname -m)" in
  x86_64|amd64|aarch64|arm64) ;;
  *) echo "This target requires a 64-bit x86 or ARM Linux host; found $(uname -m)." >&2; exit 2;;
esac

for tool in bash bison cmake curl file flex git make m4 python3 rsync sha256sum tar xz zip clang; do
  command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done

for tool in clang clang++ ar ranlib otool; do
  path="$TOOLCHAIN/bin/$PREFIX-$tool"
  test -x "$path" || missing+=("$path")
done
LDID_BIN="${LDID:-$TOOLCHAIN/bin/ldid}"
if test ! -x "$LDID_BIN"; then
  LDID_BIN="$(command -v ldid 2>/dev/null || true)"
fi
test -n "$LDID_BIN" && test -x "$LDID_BIN" || missing+=("ldid (cctools target/bin/ldid or PATH)")

if test -z "$SDK" && test -d "$TOOLCHAIN/SDK"; then
  SDK="$(find "$TOOLCHAIN/SDK" -maxdepth 2 -type d -name 'iPhoneOS*.sdk' -print -quit 2>/dev/null || true)"
fi
test -n "$SDK" || missing+=("IOS_SDK=/absolute/path/to/iPhoneOS.sdk")
if test -n "$SDK"; then
  test -d "$SDK" || missing+=("$SDK")
  test -d "$SDK/System/Library/Frameworks/UIKit.framework" || missing+=("$SDK/System/Library/Frameworks/UIKit.framework")
  test -e "$SDK/usr/lib/libSystem.tbd" || test -e "$SDK/usr/lib/libSystem.dylib" || missing+=("$SDK/usr/lib/libSystem.{tbd,dylib}")
fi

if test "${JUICE_WITHOUT_FREETYPE:-0}" != 1; then
  test -n "$ROOTLESS" || missing+=("JUICE_IOS_ROOTLESS_SYSROOT=<extracted rootless iOS sysroot>")
  if test -n "$ROOTLESS"; then
    test -f "$ROOTLESS/usr/include/freetype2/ft2build.h" || missing+=("$ROOTLESS/usr/include/freetype2/ft2build.h")
    test -e "$ROOTLESS/usr/lib/libfreetype.dylib" || missing+=("$ROOTLESS/usr/lib/libfreetype.dylib")
  fi
fi

if test "${#missing[@]}" -ne 0; then
  printf 'Missing x86_64 Linux build prerequisite: %s\n' "${missing[@]}" >&2
  cat >&2 <<MSG

Juice expects cctools-port's Linux iOS toolchain at:
  $TOOLCHAIN
or set JUICE_IOS_TOOLCHAIN to its target directory.
MSG
  exit 5
fi

# Real link probe: this catches a host compiler that can emit Mach-O objects but
# has no iOS-capable linker. No target binary is executed on Linux.
mkdir -p "$ROOT/build"
probe_dir="$(mktemp -d "$ROOT/build/.linux-preflight.XXXXXX")"
cleanup() { rm -rf "$probe_dir"; }
trap cleanup EXIT
printf 'int main(void) { return 0; }\n' > "$probe_dir/probe.c"
IOS_SDK="$SDK" JUICE_IOS_TOOLCHAIN="$TOOLCHAIN" JUICE_MIN_IOS="$MIN_IOS" \
  "$ROOT/toolchain/juice-ios-cc" "$probe_dir/probe.c" -o "$probe_dir/probe"
file "$probe_dir/probe" | grep -Eq 'Mach-O 64-bit arm64' || {
  echo "The cctools-port compiler did not produce an arm64 Mach-O executable." >&2
  file "$probe_dir/probe" >&2 || true
  exit 6
}

free_kb="$(df -Pk "$ROOT" | awk 'NR == 2 {print $4}')"
case "$free_kb" in ''|*[!0-9]*) free_kb=0;; esac
if test "$free_kb" -lt "$MIN_FREE_KB"; then
  echo "A clean Linux cross-build should have at least $((MIN_FREE_KB / 1024)) MiB free; found $((free_kb / 1024)) MiB." >&2
  test "${JUICE_ALLOW_LOW_SPACE:-0}" = 1 || exit 7
fi

echo "JUICE_LINUX_X86_64_PREFLIGHT_OK sdk=$SDK toolchain=$TOOLCHAIN min_ios=$MIN_IOS ldid=$LDID_BIN free_mib=$((free_kb / 1024))"
