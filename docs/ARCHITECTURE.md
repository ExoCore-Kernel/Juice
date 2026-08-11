# Architecture

Juice has five runtime layers.

1. The UIKit app owns an aspect-fit UIImageView canvas, launcher controls,
   Files import, text controls, fullscreen state, persistent per-architecture
   Wine prefixes, the display and control sockets, and the persistent log.
2. wineios.drv implements a software Wine display driver. It owns window
   surfaces, sends window and premultiplied BGRA frame records over the Unix
   socket named by JUICE_IOS_SOCKET, and decodes pointer/text messages coming
   back from the app.
3. `JuiceGUI.exe` is a small native ARM64 Win32/GDI desktop shell preinstalled
   in Grape. Wine owns its application windows and composites them into the
   single full-screen desktop surface.
4. Patched native Wine modules adapt process startup, Darwin signals, 16 KiB
   host pages, x18/TEB recovery, low shared-data references, iOS window
   geometry, and graphics-driver selection.
5. ARM64 Windows PE modules and applications execute through native Grape. The
   optional Grape-X64 runtime contains ARM64X/ARM64EC Wine modules and FEX's
   `libarm64ecfex.dll` to translate x86-64 code without a virtual machine. A
   trace parent completes the iOS PT_TRACE_ME/CS_DEBUGGED handshake; the nested
   wrapper repeats it for Wine-created children.

## Display flow

wineios.drv connects to the app and sends HELLO, WINDOW, DESTROY, and FRAME
records. A FRAME header includes the HWND, width, height, stride, dirty
rectangle origin, and payload size. The app wraps the BGRA payload in a CGImage,
assigns it to the canvas, and associates the source socket and HWND with the
currently displayed frame.

The software surface is also a GDI bitmap created through
NtGdiDdDDICreateDCFromMemory. Normal surface flushes send frames. The v12 input
path can force an immediate full-surface presentation after text or a special
key so a successful control update is not hidden behind a missed invalidation.

## Pointer flow

UIKit coordinates are mapped through the image's aspect-fit rectangle into
surface-local pixels. The app sends the current surface HWND plus explicit
left/right down or up flags only to the socket that supplied the visible frame.

The driver translates local pixels by the Wine window's desktop origin,
hit-tests with NtUserWindowFromPoint, focuses the deepest returned HWND, and
submits absolute MOUSEINPUT through NtUserSendHardwareInput. The most recent
pressed child is retained as the later text target.

## Text flow

The socket is registered as the current Wine GUI thread's queue file descriptor
through the Wine server. That wakes the normal Wine event loop when UIKit input
arrives and keeps window-message work on the GUI thread.

Text records carry a bounded UTF-16LE payload. The driver focuses the retained
child and synchronously invokes WM_CHAR for each UTF-16 code unit with
NtUserMessageCall and NtUserSendMessage. Backspace, Tab, and Enter use the same
path. It then queries WM_GETTEXTLENGTH, invalidates the child and parent, and
forces a surface presentation. Logs report delivered code units, resulting
control length, redraw status, and whether a surface was presented.

The v20 device proof visibly rendered `TextOutW`, wrapped `DrawTextW`, Unicode
glyphs, edit-control text, and the resulting PASS status. Its log records 20
UTF-16 units delivered and a resulting control length of 20; the paired PNG and
markers are under `proofs/verified/2026-08-11/final-v20/text/`.

## Native control channel

File-picker and host-launch requests do not share the blocking framebuffer
stream. `wineios.drv` uses the Unix socket named by
`JUICE_IOS_CONTROL_SOCKET` and fixed-size version-1 request/response records.
JuiceGUI starts an import asynchronously, polls without blocking its Wine GUI
thread, and receives a Windows `Z:` path or a cancellation/error result.

UIKit accepts the request on a background socket queue and dispatches only the
presentation of `UIDocumentPickerViewController` to the main thread. A selected
MSI, EXE, or ZIP is copied into
`/var/mobile/Documents/JuiceData/Imported`, then returned as a valid Windows
path. Host actions use the same channel for safe ZIP import and detected
x86-64 launches. Request IDs, protocol versions, bounds, busy state, and
cancellation are validated independently of display traffic.

## Native and PE split

The native build produces Mach-O loader, wineserver, ntdll, win32u, ws2_32, and
wineios.drv components. The PE build uses Clang/LLD to produce ARM64 Windows
DLLs, EXEs, and the PE half of wineios.drv. `config/runtime-modules.txt` names
the deterministic 81-module set that is both built and staged, including MSI,
Cabinet, RPC, OLE, services, registry, and shell components.

Wine can resolve native wineios.so beside either build-tree native modules or
the PE runtime directory. Runtime assembly places the identical signed file in
both locations to prevent a stale driver from silently handling input.

The experimental Grape-X64 stage begins as a copy of the known-good ARM64
Grape stage, then replaces the PE set with validated ARM64X/ARM64EC modules and
adds the pinned FEX translator. The two runtime roots and Wine prefixes remain
separate. Juice reads the PE machine field before launch and never sends a
known ARM64 application through FEX.

## iOS compatibility changes

- PE executable sections aligned to 4 KiB are expanded into safe anonymous
  mappings on the 16 KiB iOS host page size.
- Wine shared data is mapped at 0x17ffe0000 because iOS reserves the low 4 GiB.
  A narrow ARM64 fault redirect supports applications that still reference
  Windows' conventional 0x7ffe0000 address.
- Darwin signal return can clear ARM64 x18, Wine's TEB register. The signal
  bridge recognizes affected instruction patterns, restores x18, and retries.
- win32u geometry guards reject corrupt font and window dimensions before they
  create giant or negative surfaces.
- A FreeType-enabled native win32u supplies Windows glyph rasterization while
  fontconfig remains disabled.

The complete modified source is in wine. The exact delta is in
patches/wine-ios.patch.
