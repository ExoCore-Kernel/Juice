# ARM64 kernel32 path regression proof

This iPad proof captures the regression and the verified general fix. The
runtime search path and persistent-prefix linker now include the concrete
`runtime/lib/wine/aarch64-windows` directory instead of enumerating only its
parent. No executable-specific branch was added.

`device.log` and `result.env` retain the failing pre-fix run. The final run is
`device-final.log`; it contains `JUICE_KERNEL32_LOAD_OK`, and
`result-final.env` records status 0.

Verify the retained evidence with `sha256sum -c SHA256SUMS`.
