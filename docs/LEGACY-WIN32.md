# Experimental Legacy Win32 support

Juice has an optional experimental route for 32-bit x86 (PE32 / i386) Windows applications.

## Architecture

The feature uses Wine's modern WoW64 architecture on the existing 64-bit ARM64 host runtime. Guest i386 instructions are translated by FEX's Windows WoW64 backend (`libwow64fex.dll`), while Wine/Win32 calls return to native ARM64 Wine code. No 32-bit iOS or Unix userspace is required.

The feature intentionally lives beside, rather than inside, the verified ARM64 path:

- ARM64 Windows applications continue to use `Grape`.
- AMD64 / ARM64EC applications continue to use `Grape-X64` + `libarm64ecfex.dll`.
- i386 applications use `Grape-X64` + Wine WoW64 + `libwow64fex.dll`.

The UIKit controller exposes **Experimental → Legacy Win32 (x86 / 32-bit)**. It defaults to off and is persisted under `JuiceExperimentalLegacyWin32`.

## Build

On the ARM64 Linux build host:

```sh
make x64-components
make win32-components
JUICE_REQUIRE_WIN32=1 make win32-runtime
```

`win32-components` builds:

1. FEX `libwow64fex.dll` as a native ARM64 Windows translator DLL.
2. Wine i386 PE modules from the same Wine source revision using `--enable-archs=i386,aarch64`.
3. A real PE32 `x86-smoke.exe` used for device verification.

The normal translated runtime assembler remains backwards compatible. If the Win32 components are absent, `make x64-runtime` still creates an x86-64-only `Grape-X64`. Set `JUICE_REQUIRE_WIN32=1` (or use `make win32-runtime`) when a missing Win32 component should fail the build.

## Runtime layout

When Legacy Win32 components are present, `Grape-X64` gains:

- `runtime/lib/wine/aarch64-windows/libwow64fex.dll`
- `runtime/lib/wine/i386-windows/*.dll` / `*.exe` / `*.drv`
- `tests/x86-smoke.exe`

At launch Juice detects `IMAGE_FILE_MACHINE_I386`, requires the experimental toggle, confirms the WoW64 runtime is packaged, selects `Grape-X64`, and adds:

```text
HODLL=libwow64fex.dll
JUICE_EXPERIMENTAL_WIN32=1
```

It also exposes the i386 Wine directory through `WINEDLLPATH` and links the packaged i386 PE modules into the persistent prefix's `windows/syswow64` directory.

## Verification status

The source/build/runtime integration is experimental and must not be described as device-verified until `x86-smoke.exe` has run on the target iPad and produced `/var/mobile/Documents/Juice-x86-smoke.ok`. ARM64 and x86-64 verification status is unchanged by this feature.
