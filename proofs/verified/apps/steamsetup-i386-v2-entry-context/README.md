# Steam Setup i386 iPad proof

This is the successful 2026-08-22 iPad run of Valve's unmodified PE32
`SteamSetup.exe` through Wine WoW64 and FEX. `frame-after-input.png` visibly
shows the Steam Setup welcome page with readable text and controls.

`device.log` ends with `JUICE_TEXT_HOST_RESULT success=1`; `result.env` records
the i386 route, persistent prefix, executable, and status. The executable hash
in `SHA256SUMS` is the hash recorded on the device. The fix is runtime-wide:
the FEX WoW64 entry wrapper normalizes the native caller PC/SP after Wine's
ARM64EC context capture, preventing APC/longjmp unwinds from resuming with the
wrapper's temporary stack. No Steam-specific branch was added.

Verify the retained evidence with:

```sh
sha256sum -c LOCAL-SHA256SUMS
```
