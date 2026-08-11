# Low-space prebuilt runtime builds

Juice can rebuild its iOS frontend without rebuilding Wine or FEX and can package against an existing runtime tree without duplicating the entire runtime into `build/package`.

## Basic use

```bash
make reuse BINARIES=/path/to/prebuilt
```

`BINARIES` may point to:

- a previous Juice build directory,
- a directory containing `Grape` and/or `Grape-X64`,
- `Payload/Juice.app` from an unpacked TIPA,
- an installed `Juice.app`, or
- a parent directory that contains one of those layouts.

The script searches beneath the supplied directory for valid runtime roots. A native `Grape` runtime is required. `Grape-X64` is included automatically when found.

The frontend is always rebuilt from the current checkout with `scripts/build-app.sh`. Wine, FEX, ARM64EC and WoW64 components are reused from the supplied binaries.

## Install immediately

```bash
make reuse-install BINARIES=/path/to/prebuilt
```

This packages the new frontend with the discovered runtimes and installs the resulting TIPA using the existing TrollStore install helper.

## Runtime selection

Default behaviour:

```bash
make reuse BINARIES=/path/to/prebuilt REUSE_X64=auto
```

Native-only package:

```bash
make reuse BINARIES=/path/to/prebuilt REUSE_X64=0
```

Require the translated runtime:

```bash
make reuse BINARIES=/path/to/prebuilt REUSE_X64=1
```

When the discovered `Grape-X64` contains both `libwow64fex.dll` and an `i386-windows/ntdll.dll`, the packager reports `win32=1`; the Legacy Win32 runtime is then carried into the package automatically.

## Why this uses less space

On the same filesystem, the packager stages the large runtime trees with hardlinks via `rsync --link-dest`. It does not sign those hardlinks in place: each Mach-O file is detached before `ldid` modifies it, so the original prebuilt runtime remains unchanged.

This means most PE DLLs, resources, prefix templates and other large runtime files consume no second copy while the TIPA is being produced. Only the small rebuilt Juice frontend, detached/signature-modified Mach-O files, and the final compressed TIPA require new data blocks.

The temporary `build/reuse-package` directory is removed automatically after success or failure unless `JUICE_KEEP_REUSE_STAGE=1` is set.

If the supplied binaries are on a filesystem that cannot be hard-linked to the checkout, the script refuses to silently fall back to a multi-gigabyte copy. `JUICE_REUSE_ALLOW_COPY=1` explicitly enables that fallback when it is actually desired.
