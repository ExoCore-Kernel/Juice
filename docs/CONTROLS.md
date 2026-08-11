# GUI controls

Juice normally opens directly into the full-screen `JuiceGUI.exe` desktop.
Wine manages and composites application windows inside this one surface. The
small `...` button in the upper-right exposes the UIKit diagnostic controls;
the same host controls can return to the desktop without restarting Wine.

The desktop application bar provides Juice, Launch, Install App, Files,
Refresh, and Uninstall. The application list is populated from Juice's catalog
and the standard per-user and machine-wide Wine uninstall keys. ARM64 entries
launch directly. Detected AMD64 or ARM64EC entries are visibly labelled
experimental and request the isolated Grape-X64/FEX host route.

## Installing applications

Install App requests a file through the versioned `wineios.drv`/UIKit control
channel. The iOS picker accepts MSI, EXE, and ZIP selections and imports the
chosen item into Juice's persistent imported-files directory.

- MSI files launch as `msiexec /i <path>`.
- ARM64 setup executables launch normally in Grape.
- AMD64 setup executables use Grape-X64/FEX when the experimental runtime is
  present and enabled.
- ZIP files use the host's traversal-safe portable importer.

The default Wine prefix is persistent under
`/var/mobile/Documents/JuiceData`; app restarts and TIPA updates do not erase
installed programs. Juice-owned programs are refreshed from the app bundle on
upgrade, while ordinary files belonging to installed programs are not
overwritten.

## Pointer input

Select Left click or Right click, then touch the Windows canvas. Touch-down
presses the selected button, movement updates the pointer, and lifting the
finger releases it. Switch back to left click after opening a context menu.

Coordinates are transformed through the displayed image's aspect-fit rectangle
and translated from surface-local to Wine desktop coordinates. The driver then
hit-tests the deepest child window. Touch across the normal client area is a
proven milestone. Deliberate presses exactly on a resize border can still be
less reliable.

## Sending text

1. Touch the edit control inside the Windows application.
2. Tap Text for focused Windows control and type with the iOS keyboard.
3. Tap Send Text or press Return in the iOS transport field.
4. Use the dedicated Backspace, Tab, and Enter controls as needed.

Juice sends UTF-16LE to the child HWND selected by the most recent pointer
press. Supplementary characters are represented by UTF-16 surrogate code
units. The Wine driver rejects payloads larger than 64 KiB.

The app-side transport field clears after a successful send. It is not the
Windows edit control itself. Input is sent only to the active socket and HWND
associated with the currently displayed frame.

The driver synchronously delivers WM_CHAR, queries the resulting text length,
invalidates parent and child, and presents the active surface. The v20 iPad
proof visibly rendered the test phrase and PASS status after 20 UTF-16 units
reached a Win32 EDIT control. The paired frame, log, and independent
render/input markers are in
`proofs/verified/2026-08-11/final-v20/text/`.

## Fullscreen

Tap Fullscreen to hide the launcher form and diagnostic view and expand the
canvas to the safe display area. Tap Exit Fullscreen to restore the controls.
Juice also hides the status bar and home-indicator hint while fullscreen is
active.

## Wallpaper

The built-in desktop background is drawn procedurally and allocates no bitmap.
To use a custom image, place a Windows BMP at:

    /var/mobile/Documents/JuiceData/Wallpaper.bmp

Then choose Juice > Reload wallpaper. Juice centre-crops the bitmap to fill the
desktop. Advanced users can override the Windows path in
`HKCU\Software\Juice\Desktop`, value `Wallpaper`.

## Diagnostics

The persistent log is:

    /var/mobile/Documents/Juice-GUI-Headless.log

Relevant markers are:

    FULLSCREEN_CHANGED enabled=1
    MOUSE_BUTTON_MODE right
    GUI_TEXT_SENT hwnd=... utf16_units=...
    GUI_KEY_SENT hwnd=... key=enter vk=0xd
    [JuiceInput] queue fd registered fd=... tid=...
    [JuiceInput] dispatched surface=... target=... local=... desktop=... sent=...
    [JuiceInput] text surface=... target=... utf16_units=... delivered=... length=... redraw=... present=...
    [JuiceInput] key surface=... target=... vk=d delivered=... length=... redraw=... present=...

GUI_TEXT_SENT proves the app wrote the protocol message. The JuiceInput line
proves the active Wine driver decoded it and ran the synchronous message,
length, repaint, and presentation path. For a release proof, retain both these
lines and the rendered framebuffer; protocol logs alone do not prove that
glyphs were visible.
