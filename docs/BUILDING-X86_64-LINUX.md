# Building Juice entirely on x86_64 Linux

Juice can use an x86_64 Linux machine as the complete **build host** while still producing arm64 iOS/Mach-O and Windows PE/ARM64EC outputs. No target binary needs to execute on the iPhone during compilation.

## Inputs

You need an iPhoneOS device SDK directory supplied from your own Apple/Xcode installation:

```sh
export IOS_SDK=/absolute/path/to/iPhoneOS.sdk
```

For the normal FreeType-enabled Juice runtime, also point at an extracted rootless iOS sysroot containing the FreeType headers and dylib:

```sh
export JUICE_IOS_ROOTLESS_SYSROOT=/absolute/path/to/rootless-sysroot
```

For a reduced build without FreeType, set `JUICE_WITHOUT_FREETYPE=1` instead.

## Toolchains

Build the Linux-hosted iOS cross-toolchain from cctools-port:

```sh
make linux-x86_64-ios-toolchain
```

The pinned llvm-mingw bootstrap now selects an executable archive for the Linux host architecture. On x86_64 it downloads the pinned x86_64-host archive; ARM64 Linux keeps using the pinned AArch64-host archive.

Run the real iOS link preflight before starting the large Wine build:

```sh
make linux-x86_64-preflight
```

## Build

Build the arm64 iOS Juice TIPA entirely from x86_64 Linux:

```sh
make linux-x86_64
```

Include the existing experimental FEX/x86-64 runtime too:

```sh
make linux-x86_64-x64
```

The Linux path reuses the same upstream app, launcher, runtime assembly, FEX/ARM64EC, Legacy Win32 and packaging scripts rather than maintaining separate copies of those features.
