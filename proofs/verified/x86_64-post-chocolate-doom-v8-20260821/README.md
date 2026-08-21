# Post-Chocolate-Doom x86-64 regression

This iPad regression ran after deploying the final FEX allocator and 16 KiB
JIT page-isolation changes used by Chocolate Doom. The genuine AMD64 marker
executable exited with the expected translated status 100 and wrote
`JUICE_X86_64_SMOKE_OK`.

The checked translator SHA-256 was
`aa52a069affb23809ba283ca5b3c12c57d602f4de2911729149dc7be430baaa5`.
