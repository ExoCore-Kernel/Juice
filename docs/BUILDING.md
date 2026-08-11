# Building Juice

## What each host can build

The end-to-end Grape and Juice build runs on a rootless-jailbroken ARM64
iOS/iPadOS device with TrollStore. It produces native iOS Wine components,
ARM64 Windows PE modules and programs, launch helpers, the UIKit app, and a
TIPA.

macOS with Xcode can build the UIKit app and launch helpers for iOS. It can also
package a Grape runtime copied from a verified device build. This repository
does not contain a native macOS Juice application.

The audited build environment is:

- iPad12,1, iPadOS 16.6 build 20G75, Darwin 22.6.0;
- Procursus Clang 16.0.0 and GNU Make 4.4.1;
- rootless prefix /var/jb;
- Wine base commit 6eb2e4c32cc9e271856146df11ed3a5c2cf29234.

## Device prerequisites

Install TrollStore separately. With the Procursus repositories configured, the
complete tool dependency command is:

    sudo /var/jb/usr/bin/apt-get install bash bison build-essential clang coreutils file git ldid libfreetype-dev lld-16 m4 make odcctools pkg-config python3 rsync sudo unzip zip

`lld-16` supplies the `lld-link` PE linker matched to the audited Clang 16
toolchain. libfreetype-dev installs the FreeType runtime and its PNG/Brotli dependencies.
It is required for Windows glyph rendering. A different target device that
receives the TIPA must also have the matching rootless FreeType runtime package.

Keep at least 4 GiB free before an incremental build and preferably 6 GiB or
more for a new checkout and build. The source tree itself is roughly 420 MiB.
The scripts default to two parallel jobs.

## One-command device build

From a clean checkout:

    cd Juice
    make preflight
    make device

The device target performs these operations in order:

1. Verify platform, toolchain, TrollStore, FreeType, disk space, source markers,
   the PE module manifest, and the Wine patch/full-tree relationship.
2. Build and install a small TrollStore trust carrier when one is absent.
3. Build and CoreTrust-sign the native PE compiler shim.
4. Configure native iOS Wine with FreeType enabled.
5. Configure ARM64 Windows PE output with the device Clang/LLD toolchain.
6. Build native Grape pieces and the deterministic PE runtime module set.
7. Patch and validate ARM64 PE ntdll shared-data addressing.
8. Assemble build/runtime-stage/Grape.
9. Build the UIKit app and package a tested TIPA plus checksum under dist.

Install the newest TIPA with:

    make install

TrollStore performs the final installation/signing pass. Directly overwriting a
Mach-O inside an installed app is unsupported and normally breaks iOS trust.

The default package preserves the known-good ARM64 path. If a completed
Grape-X64 stage is supplied through `JUICE_X64_RUNTIME_STAGE`, packaging adds
it beside Grape without replacing any ARM64 file.

## Individual stages

Run stages separately while diagnosing a build:

    make verify
    make preflight
    make bootstrap
    make pe-wrapper
    make configure-wine
    make build-wine
    make runtime
    make tipa
    make install

The PE configure stage is invoked automatically by make build-wine when its
Makefile is absent. Force both native and PE configure steps after source or
configure changes with:

    JUICE_RECONFIGURE=1 make device

The configure scripts only remove generated configure state inside their
validated build directories. A genuinely clean checkout naturally has no build
directory; generated output is excluded from Git.

## Runtime selection

config/runtime-modules.txt records the deterministic runtime proven by the
WineMine and Notepad4 traces. Its paths are both Make targets and staging
inputs, which keeps the built and packaged sets identical.

For a larger compatibility build, build and stage every generated top-level
ARM64 PE DLL, EXE, and driver:

    JUICE_BUILD_ALL_PE=1 JUICE_INCLUDE_ALL_BUILT_PE=1 make device

That mode takes substantially longer and uses more storage, but is useful for
testing arbitrary portable applications.

## Why the compiler wrapper exists

iOS will not execute newly linked Mach-O Wine build tools after a normal ad-hoc
signature. toolchain/juice-cc links with Clang, places each executable in the
temporary trust carrier, asks TrollStore to install it, and copies the
CoreTrust-patched result back.

Parallel link steps share one carrier. The wrapper uses an atomic lock so two
jobs cannot overwrite the carrier simultaneously. If a killed build leaves the
lock behind, remove only build/trust-carrier/.autosign.lock after confirming no
compiler process is active.

Do not publish build/trust-carrier, generated IPAs, or device-specific signing
material.

Procursus Bison also needs its data directory, M4 executable, and a writable
temporary directory exported for real Wine grammars. toolchain/juice-bison
provides those settings and is recorded into both generated Makefiles.

GNU Make canonicalizes a rootless /var/jb working directory to its
/private/preboot backing path. Winebuild emits resource files through assembler
.incbin directives, and target Clang cannot reopen that canonical spelling.
The build script explicitly exports each logical build directory as PWD; the
corresponding Wine change then emits accessible /var/jb resource paths.

Resource-heavy PE modules create another device-specific constraint. Shell32
contains roughly 2,100 resource slices, and LLVM 16's integrated assembler runs
out of memory when each is represented by a separate .incbin directive.
The source-built build/toolchain/clang is the PE compiler selected by
configure. A native executable is necessary because Winebuild uses
posix_spawn, which cannot launch a shell-script compiler shim on the audited
iOS version. The wrapper recognizes only Winebuild's labeled resource pattern,
packs those slices at their original four-byte-aligned offsets, rewrites them
as aliases into one .incbin blob, and then delegates unchanged compiler
arguments to /var/jb/usr/bin/clang. Ordinary C, C++, and assembly inputs pass
through untouched. make verify includes a functional packing test.
Set JUICE_KEEP_PACKED_RESOURCES=1 only when inspecting a saved Winebuild
assembly; successful normal builds remove the temporary packed blob.

## Prefix initialization and installers

New prefixes run controlled Wineboot initialization and write
`.juice-prefix-ready` only after Wineboot signals readiness. The GUI setting
means “skip Wineboot after initialization”; it never suppresses the first
bootstrap of a new default prefix. `JUICE_SKIP_WINEBOOT=0` and
`JUICE_FORCE_WINEBOOT=1` are available to the device CLI runner for explicit
initialization and repair tests.

The default 81-module runtime includes Wineboot, msiexec, MSI, Cabinet, RPC,
OLE, services, registry, and shell support. After Grape and its ARM64 PE build
exist, build the deterministic MSI and setup smoke packages with:

    make installer-smokes

They are written below `build/tests/installers`. They are test inputs, not
third-party redistributables.

## Experimental x86-64 build

The translator components are intentionally separate from the ARM64 device
build. On an ARM64 Linux host with CMake, Ninja or Make, Git, Curl, Python, and
an xz-capable tar, run:

    make verify-fex
    make x64-components

The scripts verify the pinned FEX revision and patch, download the pinned
ARM64 LLVM-MinGW archive only after checking its SHA-256, build
`libarm64ecfex.dll`, build the 81-module ARM64X/ARM64EC Wine closure, and build
the AMD64 marker executable. Once a verified ARM64 stage is available at
`build/runtime-stage/Grape`, assemble and package both roots with:

    make x64-runtime
    make x64-tipa

`Grape` and `Grape-X64` remain separate in the TIPA, as do their persistent
prefixes. The UIKit host reads the PE machine field and selects Grape-X64 only
for AMD64/ARM64EC input when the experimental option is enabled. This is
translation through Wine/FEX, not a virtual machine.

## FreeType detail

Procursus' freetype2.pc references zlib.pc, while this iOS SDK supplies zlib
without that pkg-config file. The configure script therefore supplies the
verified header and library locations directly:

    FREETYPE_CFLAGS=-I/var/jb/usr/include/freetype2
    FREETYPE_LIBS=-L/var/jb/usr/lib -lfreetype

Wine configure still compiles and links its own probe and must write
HAVE_FT2BUILD_H to build/wine-ios/include/config.h. The app passes
DYLD_LIBRARY_PATH=/var/jb/usr/lib to Wine child processes so win32u can load the
rootless FreeType dylib. Upstream win32u links both CoreText and macOS AppKit on
Darwin; this fork's win32u Makefile replaces AppKit with the iOS-compatible
CoreFoundation dependency while retaining CoreText.

JUICE_WITHOUT_FREETYPE=1 is retained only for graphics-path diagnostics. It is
not a supported release configuration.

## macOS app build

With Xcode and its iPhoneOS SDK selected:

    make verify
    make app launchers

This emits iOS ARM64 binaries beneath build/app and build/launchers. To package
on macOS, copy a device-built Grape directory to
build/runtime-stage/Grape and run make tipa. Installation and privileged final
signing still happen through TrollStore on the target.

## Useful overrides

- JOBS=1 reduces Wine build memory use.
- JBROOT changes the rootless prefix.
- IOS_SDK selects a different iPhoneOS SDK.
- JUICE_MIN_IOS changes the app and launcher deployment target.
- JUICE_WINE_BUILD and JUICE_PE_BUILD select build directories.
- JUICE_RUNTIME_STAGE selects the runtime staging directory.
- JUICE_TRUST_CARRIER selects the trust-carrier workspace.
- JUICE_PE_CLANG selects the resource-aware target compiler wrapper.
- JUICE_REAL_PE_CLANG selects the real Clang used by that wrapper.
- JUICE_ALLOW_EXTERNAL_OUTPUT=1 permits an explicitly supplied TIPA path
  outside the repository's dist directory.
- JUICE_RECONFIGURE=1 reruns both configure stages.
- JUICE_ALLOW_LOW_SPACE=1 bypasses the space guard for deliberate incremental
  diagnostics; it is unsafe for a clean build.

External build directories are rejected unless
JUICE_ALLOW_EXTERNAL_BUILD=1 is explicitly set.
