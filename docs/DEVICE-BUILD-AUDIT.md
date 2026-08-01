# Device build audit

This repository was assembled on 2026-08-01 from the local staging tree and the
development iPad at /var/jb/var/mobile/Juice.

## Audited environment

- Hardware: iPad12,1, internal model J181AP.
- OS: iPadOS 16.6 (20G75), Darwin 22.6.0.
- Toolchain: Procursus Clang 16.0.0, GNU Make 4.4.1.
- Rootless prefix: /var/jb.
- Upstream Wine commit:
  6eb2e4c32cc9e271856146df11ed3a5c2cf29234.

## Source reconciliation

Before the repository-only FreeType library-path adjustment, the active iPad
GUI source and local source matched byte-for-byte:

- GuiApp/main.m:
  300f85941477fabfecc668c6245ee3917d0c7c982de075ebf8aa4ecf3f242625
- JuiceZip.m:
  c4e466a01d412e57a77d3e129de305fc916cf1658495b288d7cdef7568817fc3

The only subsequent app-source change adds
DYLD_LIBRARY_PATH=/var/jb/usr/lib to the child environment. The resulting
repository app/main.m hash is:

    b1041ab6e107570500370cdf2e21724285e77a6e4cc1d09f1bb5855d4612170a

The six current wineios.drv source hashes also matched the iPad:

- Makefile.in:
  d075eef09df80de1c3578711a882563f499487a13a4a09efc79d2e33b618d28d
- dllmain.c:
  a6192ac2edf4ac68b5fa2ab77b56c54074bc8f47cabe06378685e8ce8febb751
- iosdrv.c:
  9e3a3b5d152be3b0af714968ac07aa880dc0a84020dea758267b351f1283da30
- iosdrv.h:
  4266ecc932a7312f14115734ec36117daad5373ab31abbe022da4a6cbfc30d87
- ipc.c:
  88b1dbc6a30d05c24aa657d52195d3832f104bbd3d58931e421639818ac32ed8
- ipc.h:
  a2256af80867de26677fd24302a1aa6194c905f3a2f0db49d4f43c81d8e305af

Every historical Wine modification was compared with the included full source
and matched. One additional source-level correction was then made to
dlls/win32u/Makefile.in: iOS links CoreFoundation instead of macOS-only AppKit.
The resulting 35-path patch also contains a semantics-preserving expansion of
Wine's generated-file attribute macro so the source works as a nested tree. Its
SHA-256 is:

    5f4d651e3f71ad310a07dbb4639b1765e1f3ebb4497ade6c79f706188cdce331

It was applied to a detached worktree at the base commit, diff-checked, compared
back to the included modified files, and reverse-checked from wine.

## Build-state findings

The native iOS build's recorded configure arguments explicitly contained
--without-freetype. Its generated config did not define HAVE_FT2BUILD_H. That is
consistent with the observed state where frames and control backgrounds
rendered and text messages were delivered, but glyphs were invisible.

The primary ARM64 PE configure generated roughly 725 top-level PE targets and
had 371 outputs present during the audit. A historical per-target build log
ended around target 394 of 616 and was not accepted as proof of a complete clean
build. An alternate older PE directory configured through --with-wine-tools had
only 13 outputs and is not used by the repository scripts.

The supported configuration uses a resource-aware wrapper around the direct
Clang --with-mingw behavior proven on the device. It now requires FreeType for
the native side and checks that wineios.drv exists in the newly generated PE
Makefile. The wrapper collapses Winebuild's roughly 2,100 shell32 resource
slices into one assembler input so Procursus LLVM 16 does not exhaust memory.

## Repository build validation

The final scripts were exercised from an isolated repository checkout on the
iPad on 2026-08-01:

- Device preflight passed with the deliberate low-space diagnostic override.
- Native configure completed with FreeType enabled, the rootless shell recorded
  in Makefile, and toolchain/juice-bison selected.
- Native Wine built and CoreTrust-signed loader/wine, wineserver, ntdll.so,
  ws2_32.so, win32u.so, and wineios.so.
- A clean generated win32u link used CoreText and CoreFoundation, not AppKit.
- PE configure completed with the source-built Clang/LLD wrapper, and all 42
  entries in config/runtime-modules.txt were present as generated Make targets.
- Fresh PE builds produced wineios.drv, winemine.exe, and the previously
  failing shell32.dll. Shell32 packed exactly 2,103 .incbin slices into one
  8,254,820-byte resource and linked as a 13-section PE32+ Aarch64 DLL.
- The final build script completed its entire 42-target closure, identified
  every output as PE32+ Aarch64, patched or confirmed ntdll shared data, and
  wrote native and PE SHA-256 manifests.
- The final UIKit source compiled into an ARM64 Mach-O app, both Grape launcher
  helpers compiled, and the portable-ZIP positive and traversal-rejection tests
  passed.
- Runtime assembly staged all 42 manifest entries plus native wineios.so (43
  module files total), then a 36 MiB TIPA passed unzip integrity and checksum
  verification. Its audit-build SHA-256 was
  02e840e45727f7b012a134ecff7b8cc9307ab1fc9b5ff82cd127d2fe1b8b2790.

Only about 2.0 GiB remained free during the final validation. The repository's
4 GiB preflight guard therefore correctly rejects a new full build unless
JUICE_ALLOW_LOW_SPACE=1 is explicitly set. To avoid deleting the owner's
existing development tree, the Wine objects were not erased for an artificial
from-zero rebuild. The final scripts did execute and validate the complete
curated target set; native win32u, representative driver/program targets, and
the shell32 failure case were rebuilt through final generated Makefiles. The
isolated checkout used a symlink to the reconciled full Wine source solely to
avoid a second 420 MiB copy; the publishable local tree and source archive hold
ordinary files and pass make verify without that test-only symlink.

## What was preserved

The complete modified Wine source, current app source, launchers, prefix seed,
entitlements, proof logs/images, and active build logic are first-class
repository content. A 112 KiB source-only recovery bundle is under legacy. The
original curated audit tar had SHA-256:

    544cb377163a4e1b96b4906be8fba3656b8b66a630a08ea807248cea54a1d171

## What was intentionally excluded

Generated Wine build directories, staged runtimes, prefixes, imported third
party Windows applications, TIPAs/IPAs, device-specific trust carriers,
autosign logs, backup copies, and nested Git metadata were excluded. The iPad's
scattered tree was about 6.8 GiB; copying it wholesale would have preserved
stale and contradictory binaries rather than a reproducible source repository.

Historical scripts under legacy keep their old absolute paths and flags only as
provenance. They are not supported entrypoints.
