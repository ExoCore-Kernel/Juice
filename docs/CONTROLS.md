# GUI controls

Juice keeps its controls outside the Windows surface in normal mode. Fullscreen
expands the surface while retaining an exit overlay.

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

The v12 driver synchronously delivers WM_CHAR, queries the resulting text
length, invalidates parent and child, and presents the active surface. This
message path has diagnostic proof, but the old binary displayed no glyphs
because native Wine was configured without FreeType. A FreeType-enabled build
and visual retest are required before release.

## Fullscreen

Tap Fullscreen to hide the launcher form and diagnostic view and expand the
canvas to the safe display area. Tap Exit Fullscreen to restore the controls.
Juice also hides the status bar and home-indicator hint while fullscreen is
active.

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
length, repaint, and presentation path. Visible glyphs are still the required
end-to-end result; successful transport logs alone are insufficient.
