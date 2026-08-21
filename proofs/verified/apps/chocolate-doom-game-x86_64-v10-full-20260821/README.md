# Chocolate Doom x86-64 iPad proof

This capture is the successful 2026-08-21 iPad run of the unmodified upstream
Chocolate Doom 3.1.1 x86-64 executable through Grape ARM64EC and FEX. It loaded
Freedoom: Phase 2, created a live 640x480 software-rendered game window, and
kept normal sound and music initialization enabled.

`frame-after-input.png` visibly contains the Chocolate Doom title, rendered
first-person game view, and HUD. `device.log` ends with
`JUICE_TEXT_HOST_RESULT success=1`; `result.env` records process status 0 and
the persistent x86-64 prefix used by the run.

`SHA256SUMS` covers every locally retained proof file. `REMOTE-SHA256SUMS`
records the exact game, WAD, and translated runtime DLL checked on the iPad.
Verify the local evidence with:

```sh
sha256sum -c SHA256SUMS
```

The fix is runtime-wide: FEX's iOS rpmalloc span is reduced to fit fragmented
address space, generated code starts on fresh 16 KiB host pages, and published
code is no longer reopened for link backpatching. No executable-name or
Chocolate-Doom-specific runtime branch was added.
