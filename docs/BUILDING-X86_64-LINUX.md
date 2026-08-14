# Building Juice on x86_64 Linux

x86_64 Linux is the primary full build host for Juice. The Linux pipeline cross-compiles the iOS ARM64 runtime and app, ARM64 Windows PE modules, ARM64EC/FEX support for AMD64 applications, and the available WoW64/i386 modules for legacy 32-bit x86 applications. No target binary needs to execute on the iPhone or iPad during compilation.

## Quick start

On Ubuntu/Debian, install the host packages once:

```sh
sudo apt install -y \
  build-essential clang lld cmake git python3 bison flex m4 curl file rsync \
  zip unzip xz-utils tar pkg-config autoconf automake libtool \
  libssl-dev libxml2-dev zlib1g-dev
```

Then:

```sh
git clone https://github.com/ExoCore-Kernel/Juice.git
cd Juice
make
```

The build itself should run as the normal user. Do not run `make` with `sudo`.

`make` is the default full build and resolves to `make linux-x86_64-x64`. The full target enables the available legacy Win32/WoW64 build by default as well as ARM64EC/FEX.

The final TIPA is written under `dist/`.

## Automatically fetched build inputs

The normal Linux build downloads its external cross-build inputs into `build/` and verifies them before use.

### iPhoneOS SDK

The default SDK version is selected with:

```sh
JUICE_IOS_SDK_VERSION=16.5
```

The SDK fetcher stores the selected Theos SDK under:

```text
build/deps/theos-sdks/iPhoneOS<VERSION>.sdk
```

If you already have an iPhoneOS device SDK, override the automatic input with:

```sh
export IOS_SDK=/absolute/path/to/iPhoneOS.sdk
```

### Rootless FreeType

The default build fetches the Procursus rootless `libfreetype-dev` and runtime packages, verifies the repository metadata/checksums, and extracts the required files under:

```text
build/deps/rootless-sysroot
```

An existing extracted rootless sysroot can instead be supplied with:

```sh
export JUICE_IOS_ROOTLESS_SYSROOT=/absolute/path/to/rootless-sysroot
```

`JUICE_WITHOUT_FREETYPE=1` exists only for graphics diagnostics and is not the normal release configuration.

## What the default build does

The default `make` pipeline performs these broad stages:

1. Fetch and validate the iPhoneOS SDK and rootless FreeType inputs.
2. Build or reuse the Linux-hosted cctools-port iOS toolchain.
3. Run a real Mach-O ARM64 compile/link preflight.
4. Build or reuse the native x86_64 Linux Wine host tools (`makedep`, `winebuild`, `winegcc`, `widl`, `wrc`, and `wmc`).
5. Configure and build native iOS Wine/Grape.
6. Configure and build the ARM64 Windows PE runtime with the resource-aware Linux PE compiler wrapper.
7. Assemble the native ARM64 Grape runtime.
8. Build ARM64EC Wine and FEX for AMD64/x86-64 applications.
9. Build the supported WoW64/i386 Wine modules and the Win32 FEX component.
10. Assemble `Grape-X64`, retaining ARM64 helper programs where Wine has no generated ARM64EC/Win32 equivalent.
11. Build the UIKit app and launch helpers.
12. Package the final combined TIPA under `dist/`.

The resource-aware PE compiler wrapper is required for Wine modules with large resource sets such as shell32. It rewrites Winebuild's many temporary `.incbin` resource slices into a stable packed resource file before invoking Clang.

## Incremental builds

The Linux pipeline is designed to be rerun after failures without throwing away successful work. Normal retries reuse:

- the downloaded SDK and Procursus inputs;
- the cctools-port iOS toolchain;
- pinned LLVM-MinGW toolchains;
- Wine host tools;
- existing configured Wine build trees;
- compiled Wine objects and PE modules;
- FEX source/build trees;
- already completed ARM64EC and WoW64 modules.

Run the same command again after updating the repository:

```sh
git pull --ff-only origin main
make
```

Do **not** delete `build/` as a routine troubleshooting step.

Only force Wine configure when it is actually required:

```sh
JUICE_RECONFIGURE=1 make
```

Only force the native Linux Wine host tools to rebuild when required:

```sh
JUICE_REBUILD_HOST_TOOLS=1 make
```

## Explicit build variants

Complete build (same as plain `make`):

```sh
make linux-x86_64-x64
```

ARM64-only build without FEX/ARM64EC/WoW64:

```sh
make linux-x86_64
```

Disable legacy Win32 while keeping AMD64/ARM64EC/FEX:

```sh
JUICE_REQUIRE_WIN32=0 make linux-x86_64-x64
```

Use a specific output path inside the repository:

```sh
JUICE_TIPA_OUTPUT="$PWD/dist/Juice-Full-Linux.tipa" make
```

## Storage and POSIX filesystem requirements

The Wine source/build tree needs normal POSIX filename and symlink behavior. ext4 and other ordinary Linux filesystems work directly.

Raw exFAT is not suitable for a Juice checkout because Wine contains tracked symlinks and paths that exFAT cannot represent, including filenames containing `:`. If the large build must live on exFAT, use POSIXovl so the files remain physically on the large drive while Git and Wine see POSIX semantics.

Example:

```sh
sudo apt install -y fuse-posixovl
mkdir -p /mnt/Personal/winework ~/winework-posix
mount.posixovl -S /mnt/Personal/winework ~/winework-posix
cd ~/winework-posix
git clone https://github.com/ExoCore-Kernel/Juice.git
cd Juice
make
```

Repository shell helpers are explicitly run through Bash where needed, so a FUSE/POSIXovl backing filesystem does not need to preserve executable mode bits for every script.

If an overlay must be unmounted later:

```sh
fusermount -u ~/winework-posix
```

## Useful individual stages

These remain available for debugging or development:

```sh
make linux-x86_64-sdk
make linux-x86_64-freetype
make linux-x86_64-ios-toolchain
make linux-x86_64-preflight
make linux-x86_64-host-tools
make linux-x86_64-configure
make linux-x86_64-configure-pe
make linux-x86_64-build
make x64-components
make win32-components
make x64-runtime
make x64-tipa
```

The normal full build invokes the necessary stages automatically; they do not need to be run one by one for a normal checkout.

## Useful overrides

- `JOBS=<n>` or `JUICE_JOBS=<n>` changes parallelism.
- `IOS_SDK=/path/to/iPhoneOS.sdk` uses an existing SDK instead of the default fetched SDK.
- `JUICE_IOS_SDK_VERSION=<version>` changes the automatically selected SDK version.
- `JUICE_IOS_ROOTLESS_SYSROOT=/path` uses an existing rootless iOS sysroot.
- `JUICE_IOS_TOOLCHAIN=/path` changes the cctools-port target directory.
- `JUICE_RECONFIGURE=1` deliberately reruns Wine configure.
- `JUICE_REBUILD_HOST_TOOLS=1` deliberately rebuilds the Linux Wine host tools.
- `JUICE_REQUIRE_WIN32=0` omits the WoW64/i386 layer from the x64 build.
- `JUICE_KEEP_PACKED_RESOURCES=1` retains temporary packed PE resources for debugging.
- `JUICE_ALLOW_LOW_SPACE=1` bypasses the free-space guard for deliberate incremental diagnostics.

External build/output directories are rejected unless their corresponding explicit allow override is set.

## Older build hosts

The on-device rootless iOS build remains available with `make device`, and the macOS scripts remain useful for selected UIKit/launcher work and packaging from prebuilt runtime inputs. They are maintained as alternative development paths; the complete x86_64 Linux pipeline is now the primary documented build method.
