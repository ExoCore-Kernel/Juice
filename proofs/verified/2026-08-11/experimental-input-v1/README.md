# External input iPad proof

This directory is the passing `input-v1-retry5` device run. The earlier
attempts diagnosed an untrusted native-library location, a missing `hid.dll`,
and a missing nested trace wrapper; they are intentionally not presented as
passes.

The final run used the installed, CoreTrust-valid Grape runtime and a native
ARM64 `JuiceInputSmoke.exe`. It verifies two independent paths:

- a USB-HID key mapping was transported as real key down/up hardware input and
  the Win32 window observed both events;
- a deterministic GameController state page was read through Wine's
  `xinput1_4.dll`, including packet 42, button A, left trigger 96, left-stick X
  12345, and right-stick Y -23456.

`frame-after-input.png` visibly reports both passes. `execution.log` contains
the display connection, hardware-key dispatch, XInput bridge selection, and
fresh-marker lifecycle. `SHA256SUMS` covers both frames and all three markers.

The protocol test does not claim that a particular physical Bluetooth gamepad
was paired during this unattended run. UIKit compilation verifies the
GameController.framework adapter; a physical-device compatibility matrix is a
separate release check.
