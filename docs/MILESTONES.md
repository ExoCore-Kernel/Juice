# Milestones

## Diamond: WineMine rendering and touch

The immutable pre-portable-app archive is stored outside this repository as
Diamond.tar.gz.

- Archive SHA-256:
  75cbcd44f05169caab848dae40acd482c4ab0b7bb9ea36d8a15a2b0b5b5112e8
- Touch TIPA SHA-256:
  965a44862a9abfa535682c87b7db07d5e5a9886a2af4a7a043018f6f06509431
- Result: WineMine rendered through the Juice GUI and normal client-area touch
  input worked.

The archive was gzip-tested and copied to /var/mobile/Documents with a matching
checksum. It must not be rewritten; later milestones use new names.

## Portable ZIP and external ARM64 app

- TIPA: Juice-Portable-ZIP-X18-v3-20260720.tipa
- SHA-256:
  3171d50833f8bcf3f61d8d85786954f951eddb1107d86f77e1f757167b67d564
- Imported application: Notepad4 ARM64 portable ZIP.
- Result: real Notepad4 main HWND 0x100f2, 736 by 736 window geometry, and
  three 768 by 768 frames delivered before the proof snapshot.
- Proof-frame SHA-256:
  b57ed696584fdce2680a41cbe0e54e7d4c10b55f69baa56af572f7b39fede151

The ZIP preserved eight files, found Notepad4.exe and matepath.exe, and launched
from the selected executable directory. The process remained alive during an
extended observation. Logs also captured 16 KiB section expansion and the
KUSER_SHARED_DATA redirect.

## Input controls

Fullscreen, selectable left/right mouse input, UTF-16 text transport, and
Backspace, Tab, and Enter controls were added. The pointer path and app-to-driver
text protocol produced their expected on-device markers.

The v12 driver moved socket handling onto the Wine GUI queue, changed text
delivery to synchronous NtUserMessageCall, queried control length, invalidated
parent and child, and forced an immediate surface presentation. The later v20
FreeType-enabled build visibly rendered its GDI text suite and the exact phrase
delivered to a Win32 EDIT control.

## FreeType and repository recovery

The 2026-08-01 audit established that the native Wine build had been configured
with --without-freetype and HAVE_FT2BUILD_H was absent. The supported build now
requires libfreetype-dev, bypasses a broken Procursus zlib.pc dependency with
verified direct flags, and passes /var/jb/usr/lib to Wine children.

The same audit reconciled the scattered iPad tree with the local source:

- app/main.m and app/JuiceZip.m matched byte-for-byte;
- all six wineios.drv source files matched the current iPad versions;
- every tracked Wine modification matched the full included source;
- the Wine base was pinned to
  6eb2e4c32cc9e271856146df11ed3a5c2cf29234;
- the standalone patch was regenerated and reverse-verified against wine.

This was the source and reproducibility milestone that enabled the verified v20
device build below.

## Core v20: desktop, installers, text, and x86-64

On 2026-08-11, `Juice-Core-v20-20260811.tipa` passed ZIP integrity with
SHA-256:

    48f3a1e0dd845e130c629dcdb1e697d3a556e8143802a2ea7aa9af6c38201e41

The same installed app bundle produced these independent device results:

- ARM64 `cmd.exe` smoke: pass, exit status 0.
- AMD64 marker executable: pass through FEX, expected translated status 100.
- JuiceGUI desktop: 1024 by 768 full-screen frame from the current app-bundle
  binary, not a stale prefix copy.
- ARM64 desktop launch: WineMine reached its expected 160 by 226 window.
- x86-64 desktop launch: automatic AMD64 selection generated a version-1 host
  action, initialized FEX, and wrote `JUICE_X86_64_SMOKE_OK`.
- GDI/text/input: `TextOutW`, `DrawTextW`, Unicode, and edit-control text were
  visible; render, create, and exact-input markers all passed.
- controlled Wineboot: a fresh prefix ran Wineboot, wrote
  `.juice-prefix-ready`, then executed an ARM64 marker command.
- MSI: versioned import request, msiexec install, application discovery after a
  restart, launch, and uninstall all passed.
- setup EXE: versioned import request, persistent install, registration, and
  installed-program launch all passed.
- custom wallpaper: a user BMP loaded and centre-cropped; the temporary test
  wallpaper was removed after capture.

The canonical evidence is in `proofs/verified/2026-08-11/final-v20/`, with
curated screenshots and their hashes under `screenshots/`. Direct UIKit picker
presentation remains an attended release check; the headless MSI/setup tests
used a deterministic peer for the exact same control protocol so they did not
depend on private UI automation.
