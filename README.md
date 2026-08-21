# Juice

Juice is an experimental Wine GUI runtime for Windows applications on iPhone and iPad. The bundled Wine runtime is named **Grape**. This repository contains the UIKit app, launch helpers, complete modified Wine 11.13 source, the same Wine delta as an auditable patch, packaging assets, FEX integration, and the build system used to produce Juice TIPAs.

Juice currently provides:

- a lightweight native ARM64 `JuiceGUI.exe` desktop inside one Wine desktop surface, with an application list, taskbar, custom BMP wallpaper, Files, and installer controls;
- a UIKit surface for Wine windows and BGRA frames;
- touch-to-Wine pointer input with selectable left and right buttons;
- direct Windows ARM64 application execution;
- AMD64/x86-64 execution through ARM64EC Wine and FEX;
- legacy 32-bit x86 execution through the WoW64/i386 runtime when included in the full build;
- safe portable ZIP import with adjacent DLLs and assets preserved;
- fullscreen display;
- UTF-16 text and Backspace, Tab, and Enter transport to a touched control;
- persistent Wine prefixes plus MSI and ordinary setup-EXE support;
- a versioned, non-framebuffer control channel from `wineios.drv` to UIKit for file import and host-routed launches;
- persistent app and Wine-driver diagnostic logs.

The 2026-08-11 v20 device pass verified ARM64 WineMine, the native JuiceGUI desktop, visible GDI text, UTF-16 edit-control input, FEX-translated x86-64 execution, MSI install/launch/persistence/uninstall, and an ordinary ARM64 setup executable. The deterministic control peer exercised the same versioned request/response protocol used by the UIKit document picker and retained every marker, log, and framebuffer under `proofs/verified/2026-08-11/final-v20/`. A real foreground picker selection is still a manual release check because it requires an unlocked, attended iPad.

The 2026-08-21 application pass additionally verified the full unmodified
Chocolate Doom 3.1.1 x86-64 game on the iPad with Freedoom gameplay, readable
text/HUD, and sound enabled. Its checksummed frame and device log are under
`proofs/verified/apps/chocolate-doom-game-x86_64-v10-full-20260821/`.

## Supported target

Juice targets rootless-jailbroken ARM64 iPhones and iPads installed through TrollStore. The audited target is an iPad12,1 running iPadOS 16.6 (20G75). Private entitlements and CoreTrust signing are required, so Juice is not App Store compatible.

The **primary build host is now x86_64 Linux**. The Linux build cross-compiles the iOS ARM64 app/runtime, ARM64 Windows PE modules, the ARM64EC/FEX x86-64 runtime, and the WoW64/i386 runtime without executing target binaries on the iPhone during compilation.

The older on-device build remains available for development and verification, and macOS can still build selected iOS app/launcher pieces, but neither is the primary full-build path anymore.

## Build — primary x86_64 Linux method

A normal build should be run as your regular user, **not with `sudo`**. `sudo` is only needed to install host packages or mount/configure storage.

On Ubuntu/Debian, install the host dependencies once:

```sh
sudo apt install -y \
  build-essential clang lld cmake git python3 bison flex m4 curl file rsync \
  zip unzip xz-utils tar pkg-config autoconf automake libtool \
  libssl-dev libxml2-dev zlib1g-dev
```

Then clone Juice and build the complete TIPA:

```sh
git clone https://github.com/ExoCore-Kernel/Juice.git
cd Juice
make
```

`make` is now the main build target and is equivalent to the complete x86_64 Linux pipeline. It builds:

1. the Linux-hosted iOS cross-toolchain;
2. native ARM64 Grape/Wine for iOS;
3. ARM64 Windows PE runtime modules;
4. ARM64EC Wine and FEX for AMD64/x86-64 applications;
5. the WoW64/i386 runtime for legacy 32-bit x86 applications;
6. the UIKit Juice app and launch helpers;
7. the final combined TIPA under `dist/`.

The default Linux path automatically fetches its iPhoneOS SDK input and the rootless Procursus FreeType development/runtime files into `build/deps`. Advanced builds can override these with `IOS_SDK` and `JUICE_IOS_ROOTLESS_SYSROOT`.

The build is intentionally incremental. Re-running `make` reuses the iOS toolchain, Wine host tools, configured Wine trees, FEX trees, downloaded toolchains, and already-built objects whenever they are valid. Do not delete `build/` between ordinary retries. Use `JUICE_RECONFIGURE=1 make` only when you deliberately need Wine configure to run again.

To build only the ARM64 runtime without the x86-64/Win32 compatibility layers:

```sh
make linux-x86_64
```

To run the full target explicitly instead of the default `make` alias:

```sh
make linux-x86_64-x64
```

See [Building on x86_64 Linux](docs/BUILDING-X86_64-LINUX.md) for the full pipeline, storage notes, dependency overrides, and troubleshooting.

### Building on exFAT or another non-POSIX filesystem

Wine's source/build tree needs POSIX symlinks and filenames that filesystems such as exFAT cannot represent directly. If the large build directory must live on exFAT, mount a POSIXovl view over the storage rather than cloning/building directly on raw exFAT.

Example:

```sh
sudo apt install -y fuse-posixovl
mkdir -p ~/winework-posix
mount.posixovl -S /mnt/Personal/winework ~/winework-posix
cd ~/winework-posix
git clone https://github.com/ExoCore-Kernel/Juice.git
cd Juice
make
```

The build scripts invoke repository shell helpers through Bash so POSIX/FUSE overlays do not require executable mode bits to survive on the backing filesystem. The build itself still should not be run with `sudo`.

## Older on-device build

The original rootless iOS/iPadOS build remains supported as an alternative development path:

```sh
cd Juice
make preflight
make device
make install
```

This path requires the Procursus toolchain, TrollStore, a rootless jailbreak, FreeType, and the trust-carrier/CoreTrust workflow on the target device. See [Building](docs/BUILDING.md) for the device-specific details.

## Source integrity

The full Wine tree is based on commit `6eb2e4c32cc9e271856146df11ed3a5c2cf29234`. Running:

```sh
make verify
```

checks source syntax and safety markers, validates the runtime module manifest, and proves that `patches/wine-ios.patch` reverses cleanly from the included modified Wine tree. This prevents the full tree and standalone patch from silently drifting apart.

The same verification also checks the pinned FEX parent and rpmalloc submodule
patch workflow. `patches/fex-rpmalloc-juice-ios.patch` is intentionally kept
separate because rpmalloc is a nested upstream Git revision.

## Using Juice

Juice launches directly into its full-screen Wine desktop. Use Install App for an MSI, setup EXE, or portable ZIP; Files opens the persistent imported-files area. Juice preserves ZIP directory trees and launches from the selected executable's directory so adjacent dependencies resolve.

Windows ARM64 runs natively through Grape. AMD64 is detected automatically and routed through the ARM64EC/FEX runtime when that runtime is packaged and enabled. The full Linux build also includes the available WoW64/i386 modules for 32-bit x86 applications. `Grape` and `Grape-X64` remain separate runtime roots so the known-good native ARM64 path is not replaced by the translation path.

See [Portable applications](docs/PORTABLE-APPS.md) and [GUI controls](docs/CONTROLS.md).

## Repository map

- `app`: UIKit GUI, input bridge, file picker, and ZIP extractor.
- `wine`: complete Wine 11.13 source with the Juice changes already applied.
- `patches`: the reproducible Wine delta against the recorded upstream commit.
- `launcher`: source for the trace parent, nested launcher, and trust carrier.
- `toolchain`: iOS compiler wrappers and PE resource-wrapper sources.
- `scripts`: x86_64 Linux, device, runtime staging, packaging, install, FEX, and verification scripts.
- `config`: entitlements, plists, base revision, pinned toolchain/FEX settings, and runtime module manifest.
- `packaging`: minimal Wine prefix template.
- `proofs`: historical frames and diagnostic logs.
- `legacy`: curated source-only material recovered from the scattered iPad tree; it is provenance, not an active build input.

The detailed source reconciliation is in [Device build audit](docs/DEVICE-BUILD-AUDIT.md), and the upstream relationship is in [Wine upstream](docs/UPSTREAM.md).

## Security and licensing

Juice runs Windows programs without the normal iOS app sandbox and exposes the host filesystem through Wine's Z: drive. Only run software you trust. Read [Security](SECURITY.md) before testing or distributing it.

Wine remains LGPL-2.1-or-later under its in-tree license files. Juice-original code is licensed under the MIT license.
