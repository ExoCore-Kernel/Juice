#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
required=(
  app/main.m app/JuiceZip.m app/tests/ZipExtractorTests.m
  launcher/grape-trace-parent.c launcher/grape-nested-wrapper.c
  config/runtime-modules.txt config/wine-base.txt patches/wine-ios.patch
  config/x86_64-build.env patches/fex-juice-ios.patch patches/fex-rpmalloc-juice-ios.patch
  scripts/build-all-device.sh scripts/build-pe-compiler-wrapper-device.sh
  scripts/detect-freetype-soname-linux.sh scripts/patch-ios-wow64-pagezero.py
  scripts/regenerate-wine-patch.sh
  scripts/regenerate-fex-patch.sh scripts/verify-fex-patch.sh
  scripts/run-control-bridge-smoke-device.py
  scripts/run-gui-text-smoke-device.py scripts/run-grape-cli-device.sh
  scripts/run-arm64-smoke-device.sh scripts/run-x86_64-smoke-device.sh
  scripts/verify-wine-patch.sh
  toolchain/juice-bison toolchain/juice-cc toolchain/juice-cxx
  toolchain/juice-pe-clang.c toolchain/juice-pack-incbins.py
  wine/configure wine/configure.ac wine/COPYING.LIB
  wine/dlls/wineios.drv/Makefile.in wine/dlls/wineios.drv/dllmain.c
  wine/dlls/wineios.drv/iosdrv.c wine/dlls/wineios.drv/iosdrv.h
  wine/dlls/wineios.drv/ipc.c wine/dlls/wineios.drv/ipc.h
  wine/dlls/wineios.drv/control.c wine/dlls/wineios.drv/control.h
  wine/dlls/wineios.drv/control_protocol.h
  wine/programs/juicegui/juicegui.c
  wine/programs/juicesetupsmoke/main.c
  wine/programs/juicetextsmoke/main.c wine/include/juiceios.h
  packaging/prefix-template/system.reg packaging/prefix-template/user.reg
  proofs/verified/2026-08-11/final-v20/README.md
  proofs/verified/2026-08-11/final-v20/SHA256SUMS
  proofs/verified/apps/chocolate-doom-game-x86_64-v10-full-20260821/README.md
  proofs/verified/apps/chocolate-doom-game-x86_64-v10-full-20260821/SHA256SUMS
  proofs/verified/x86_64-post-chocolate-doom-v8-20260821/README.md
  proofs/verified/x86_64-post-chocolate-doom-v8-20260821/SHA256SUMS
)
for path in "${required[@]}"; do
  test -e "$ROOT/$path" || { echo "Missing $path" >&2; exit 2; }
done
test -L "$ROOT/toolchain/juice-cxx" || {
  echo "toolchain/juice-cxx must remain a symlink to juice-cc." >&2
  exit 2
}

while IFS= read -r script; do bash -n "$script"; done < <(
  find "$ROOT/scripts" -type f -name '*.sh' | sort
)
bash -n "$ROOT/toolchain/juice-bison" "$ROOT/toolchain/juice-cc"
for python_source in \
  "$ROOT/scripts/patch-ios-wow64-pagezero.py" \
  "$ROOT/scripts/patch-pe-shared-data.py" \
  "$ROOT/scripts/run-control-bridge-smoke-device.py" \
  "$ROOT/scripts/run-gui-text-smoke-device.py" \
  "$ROOT/toolchain/juice-pack-incbins.py"; do
  python3 -c 'import ast,pathlib,sys; ast.parse(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))' \
    "$python_source"
done
cc -std=c11 -Wall -Wextra -fsyntax-only "$ROOT/toolchain/juice-pe-clang.c"

grep -q 'PORTABLE_ZIP_READY' "$ROOT/app/main.m"
grep -q 'FULLSCREEN_CHANGED' "$ROOT/app/main.m"
grep -q 'GUI_TEXT_SENT' "$ROOT/app/main.m"
grep -q 'CONTROL_V1_FILE_PICKER_OPEN' "$ROOT/app/main.m"
grep -q 'PE_ARCH_DETECTED' "$ROOT/app/main.m"
grep -q 'MOUSE_BUTTON_MODE' "$ROOT/app/main.m"
grep -q 'DYLD_LIBRARY_PATH=' "$ROOT/app/main.m"
grep -q 'offset + 22u + JZRead16' "$ROOT/app/JuiceZip.m"
grep -q 'host-page expanding executable section' "$ROOT/wine/dlls/ntdll/unix/virtual.c"
grep -q 'redirected KUSER_SHARED_DATA fault' "$ROOT/wine/dlls/ntdll/unix/signal_arm64.c"
grep -q 'WINE_CONFIG_MAKEFILE(dlls/wineios.drv)' "$ROOT/wine/configure.ac"
grep -q 'JUICE_IOS_TEXT' "$ROOT/wine/dlls/wineios.drv/ipc.h"
grep -q 'MOUSEEVENTF_RIGHTDOWN' "$ROOT/wine/dlls/wineios.drv/ipc.c"
grep -q 'self.activeClient=fd' "$ROOT/app/main.m"
grep -q 'NtUserWindowFromPoint' "$ROOT/wine/dlls/wineios.drv/ipc.c"
grep -q 'NtUserChildWindowFromPointEx' "$ROOT/wine/dlls/wineios.drv/ipc.c"
grep -q 'NtUserMessageCall(target,WM_CHAR' "$ROOT/wine/dlls/wineios.drv/ipc.c"
grep -q 'ios_ipc_register_queue' "$ROOT/wine/dlls/wineios.drv/ipc.c"
grep -q 'iosdrv_present_now' "$ROOT/wine/dlls/wineios.drv/ipc.c"
grep -q 'JUICE_CONTROL_VERSION' "$ROOT/wine/dlls/wineios.drv/control_protocol.h"
grep -q 'JUICE_GUI_ARM64_OK' "$ROOT/wine/programs/juicegui/juicegui.c"
grep -q 'JUICE_TEXT_GDI_OK' "$ROOT/wine/programs/juicetextsmoke/main.c"
grep -q 'input.mi.dx+=window.left' "$ROOT/wine/dlls/wineios.drv/ipc.c"
grep -q 'runtime/lib/wine/aarch64-windows/wineios.so' "$ROOT/scripts/assemble-runtime.sh"
grep -q 'FREETYPE_CFLAGS' "$ROOT/scripts/configure-wine-device.sh"
grep -q 'ac_cv_lib_soname_freetype' "$ROOT/scripts/configure-wine-linux.sh"
grep -q '@executable_path/../../../../Libraries/' "$ROOT/scripts/configure-wine-linux.sh"
grep -q 'JUICE_FREETYPE_CONFIG_RETROFIT' "$ROOT/scripts/build-all-linux-x86_64.sh"
grep -q 'JUICE_RUNTIME_LIBRARIES_READY' "$ROOT/scripts/package-tipa.sh"
grep -q 'JUICE_IOS_LIBRARIES_BUNDLED' "$ROOT/scripts/bundle-ios-libraries.sh"
grep -q 'JUICE_WOW64_PAGEZERO_PATCHED' "$ROOT/scripts/patch-ios-wow64-pagezero.py"
# The experimental x64 loader now keeps its signed 4 GiB __PAGEZERO intact so
# iOS will exec it. Low VA is unlocked in the live task by the bundled root
# helper instead; verify that packaging preserves the specialized entitlement.
grep -q 'JUICE_LOWVA_HELPER_SIGNED' "$ROOT/scripts/package-tipa.sh"
grep -q 'lowva-helper-entitlements.plist' "$ROOT/scripts/package-tipa.sh"
grep -q 'IOSurfaceRootUserClient' "$ROOT/config/lowva-helper-entitlements.plist"
grep -q 'bundle libraries path=' "$ROOT/launcher/grape-trace-parent.c"
grep -q 'PWD="$PEBUILD"' "$ROOT/scripts/build-wine-device.sh"
grep -q 'with-mingw="$PE_CLANG"' "$ROOT/scripts/configure-wine-pe-device.sh"
grep -q '^UNIX_LIBS.*CORETEXT_LIBS' "$ROOT/wine/dlls/win32u/Makefile.in"
if grep -q '^UNIX_LIBS.*APPKIT_LIBS' "$ROOT/wine/dlls/win32u/Makefile.in"; then
  echo "win32u must not link the macOS-only AppKit framework on iOS." >&2
  exit 1
fi

python3 - "$ROOT/scripts/patch-ios-wow64-pagezero.py" <<'PY'
import pathlib
import struct
import subprocess
import sys
import tempfile

patcher = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix="juice-pagezero-test-") as temporary:
    path = pathlib.Path(temporary) / "wine"
    header = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 1, 72, 0, 0)
    segment = struct.pack(
        "<2I16s4Q4I",
        0x19,
        72,
        b"__PAGEZERO\0\0\0\0\0\0",
        0,
        0x100000000,
        0,
        0,
        0,
        0,
        0,
        0,
    )
    path.write_bytes(header + segment)
    subprocess.run([sys.executable, str(patcher), str(path)], check=True, stdout=subprocess.DEVNULL)
    data = path.read_bytes()
    assert struct.unpack_from("<Q", data, 32 + 32)[0] == 0x4000
print("JUICE_WOW64_PAGEZERO_PATCHER_OK")
PY

python3 - "$ROOT/toolchain/juice-pack-incbins.py" <<'PY'
import os
import pathlib
import subprocess
import sys
import tempfile

packer = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix="juice-incbin-test-") as temporary:
    directory = pathlib.Path(temporary)
    resource = directory / "resources.bin"
    assembly = directory / "winebuild.s"
    resource.write_bytes(b"abcdefghij")
    assembly.write_text(
        ".text\n"
        "\t.balign 4\n.L__wine_spec_res_0:\n"
        f'\t.incbin "{resource}", 1, 3\n'
        "\t.balign 4\n.L__wine_spec_res_1:\n"
        f'\t.incbin "{resource}", 5, 2\n',
        encoding="utf-8",
    )
    environment = os.environ.copy()
    environment["PWD"] = str(directory)
    subprocess.run(
        [sys.executable, str(packer), str(assembly)],
        check=True,
        env=environment,
        stdout=subprocess.DEVNULL,
    )
    rewritten = assembly.read_text(encoding="utf-8")
    packed = directory / ".winebuild.s.juice-packed-resources.bin"
    assert rewritten.count(".incbin") == 1, rewritten
    assert ".set .L__wine_spec_res_0,.L__wine_spec_packed_resources+0" in rewritten
    assert ".set .L__wine_spec_res_1,.L__wine_spec_packed_resources+4" in rewritten
    assert packed.read_bytes() == b"bcd\0fg"
print("JUICE_INCBIN_PACKER_OK")
PY

python3 - "$ROOT/config/runtime-modules.txt" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
entries = []
for raw in path.read_text(encoding="utf-8").splitlines():
    entry = raw.split("#", 1)[0].strip()
    if entry:
        entries.append(entry)
pattern = re.compile(
    r"(?:dlls|programs)/[A-Za-z0-9_.+-]+/aarch64-windows/"
    r"[A-Za-z0-9_.+-]+\.(?:dll|exe|drv|sys)"
)
invalid = [entry for entry in entries if not pattern.fullmatch(entry)]
duplicates = sorted({entry for entry in entries if entries.count(entry) > 1})
basenames = [pathlib.PurePosixPath(entry).name for entry in entries]
basename_duplicates = sorted({name for name in basenames if basenames.count(name) > 1})
if len(entries) < 81 or invalid or duplicates or basename_duplicates:
    raise SystemExit(
        "invalid runtime manifest: "
        f"count={len(entries)} invalid={invalid} duplicates={duplicates} "
        f"basename_duplicates={basename_duplicates}"
    )
print(f"JUICE_RUNTIME_MANIFEST_OK modules={len(entries)}")
PY

"$ROOT/scripts/verify-wine-patch.sh"

excluded="$(find "$ROOT/wine" \( -type d -name .git -o -type f \
  \( -name '*.orig' -o -name '*.before-*' -o -name '*.backup' \
     -o -name '*.touch-backup' -o -name '*.juice-debug-backup' \) \) \
  -print)"
if test -n "$excluded"; then
  echo "Wine tree contains excluded Git metadata or backup file: $excluded" >&2
  exit 3
fi
oversized="$(find "$ROOT" \
  \( -path "$ROOT/.git" -o -path "$ROOT/build" -o -path "$ROOT/dist" \) -prune -o \
  -type f -size +95M -print)"
if test -n "$oversized"; then
  echo "A tracked-source candidate exceeds GitHub's 100 MB limit: $oversized" >&2
  exit 4
fi
if test -d "$ROOT/screenshots"; then
  (cd "$ROOT/screenshots" && sha256sum -c SHA256SUMS)
fi
if test -d "$ROOT/proofs/verified/2026-08-11/final-v20"; then
  (cd "$ROOT/proofs/verified/2026-08-11/final-v20" && sha256sum -c SHA256SUMS)
fi
if test -d "$ROOT/proofs/verified/apps/chocolate-doom-game-x86_64-v10-full-20260821"; then
  (cd "$ROOT/proofs/verified/apps/chocolate-doom-game-x86_64-v10-full-20260821" &&
    sha256sum -c SHA256SUMS)
fi
if test -d "$ROOT/proofs/verified/x86_64-post-chocolate-doom-v8-20260821"; then
  (cd "$ROOT/proofs/verified/x86_64-post-chocolate-doom-v8-20260821" &&
    sha256sum -c SHA256SUMS)
fi
if test -d "$ROOT/proofs/verified/apps/steamsetup-i386-v2-entry-context"; then
  (cd "$ROOT/proofs/verified/apps/steamsetup-i386-v2-entry-context" &&
    sha256sum -c LOCAL-SHA256SUMS)
fi
echo "JUICE_SOURCE_VERIFY_OK"
