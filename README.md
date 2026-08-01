# Juice

Juice is an experimental Wine GUI runtime for ARM64 Windows applications on
iPhone and iPad. The bundled Wine runtime is named Grape. This repository is
the maintainable source snapshot recovered from the development iPad: it
contains the UIKit app, launch helpers, complete modified Wine 11.13 source,
the same Wine delta as an auditable patch, packaging assets, and build scripts.

Juice currently provides:

- a UIKit surface for Wine windows and BGRA frames;
- touch-to-Wine pointer input with selectable left and right buttons;
- direct ARM64 Windows EXE selection;
- safe portable ZIP import with adjacent DLLs and assets preserved;
- fullscreen display;
- UTF-16 text and Backspace, Tab, and Enter transport to a touched control;
- persistent app and Wine-driver diagnostic logs.

WineMine and the ARM64 portable build of Notepad4 have both rendered real
Windows windows on the test iPad. Touch, portable ZIP import, and frame delivery
were proven on device. The previous binary had been configured without
FreeType, so Windows text glyphs were not visible even when message logs showed
successful delivery. The supported build now requires FreeType and exposes its
runtime library path. That corrected build still needs a final visual text
retest before text rendering is called a completed milestone.

## Supported target

The complete build is verified on a rootless-jailbroken ARM64 iPad with
TrollStore. The audited device is an iPad12,1 running iPadOS 16.6 (20G75).
Private entitlements and CoreTrust signing are required, so Juice is not App
Store compatible.

macOS with Xcode can cross-compile the UIKit app and launch helpers for iOS. A
native macOS Juice application is not part of this repository, and the complete
Grape build has only been verified on the target device.

## Build

On the iOS/iPadOS build device:

    cd Juice
    sudo /var/jb/usr/bin/apt-get install libfreetype-dev
    make preflight
    make device
    make install

The first full build needs several gigabytes and repeatedly uses a
TrollStore-installed trust carrier to make newly linked Wine build tools
executable. The final TIPA and checksum are written under dist. See
[Building](docs/BUILDING.md) for the complete prerequisite command, clean-build
behavior, useful overrides, and macOS-only steps.

## Source integrity

The full Wine tree is based on commit
6eb2e4c32cc9e271856146df11ed3a5c2cf29234. Running:

    make verify

checks source syntax and safety markers, validates the runtime module manifest,
and proves that patches/wine-ios.patch reverses cleanly from the included
modified Wine tree. This prevents the full tree and standalone patch from
silently drifting apart.

## Using Juice

Tap Choose EXE or Portable ZIP and select an ARM64 Windows executable or ZIP.
For ZIPs, Juice preserves the directory tree and launches from the selected
executable's directory, allowing adjacent dependencies to resolve. x86 and x64
translation are not included. See [Portable applications](docs/PORTABLE-APPS.md)
and [GUI controls](docs/CONTROLS.md).

## Repository map

- app: UIKit GUI, input bridge, file picker, and ZIP extractor.
- wine: complete Wine 11.13 source with the Juice changes already applied.
- patches: the reproducible Wine delta against the recorded upstream commit.
- launcher: source for the trace parent, nested launcher, and trust carrier.
- toolchain: active CoreTrust-aware compiler and PE resource-wrapper sources.
- scripts: verified device/macOS build, staging, packaging, install, and checks.
- config: entitlements, plists, base revision, and runtime module manifest.
- packaging: minimal Wine prefix template.
- proofs: small historical frames and diagnostic logs.
- legacy: curated source-only material recovered from the scattered iPad tree;
  it is provenance, not an active build input.

The detailed source reconciliation is in
[Device build audit](docs/DEVICE-BUILD-AUDIT.md), and the upstream relationship
is in [Wine upstream](docs/UPSTREAM.md).

## Security and licensing

Juice runs Windows programs without the normal iOS app sandbox and exposes the
host filesystem through Wine's Z: drive. Only run software you trust. Read
[Security](SECURITY.md) before testing or distributing it.

Wine remains LGPL-2.1-or-later under its in-tree license files. Juice-original
code has not yet been assigned an open-source license by its owner. Choose and
add that license before public release; see [Licensing](LICENSES/README.md).
