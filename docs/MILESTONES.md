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

The latest v12 driver moved socket handling onto the Wine GUI queue, changed
text delivery to synchronous NtUserMessageCall, queried control length,
invalidated parent and child, and forced an immediate surface presentation.
Despite those successful logs, the tested binary still showed no glyphs.

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

This is a source and reproducibility milestone. Visible text from a newly built
FreeType-enabled TIPA remains the next visual acceptance test.
