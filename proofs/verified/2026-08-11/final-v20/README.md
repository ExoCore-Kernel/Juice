# Juice core v20 iPad verification

These files were copied without modification from the development iPad after
testing the installed `Juice-Core-v20-20260811.tipa`. The TIPA SHA-256 was
`48f3a1e0dd845e130c629dcdb1e697d3a556e8143802a2ea7aa9af6c38201e41`.

Canonical passing results:

- `arm64-retry/`: native ARM64 `cmd.exe` marker, status 0, and runtime hashes.
- `x86_64/`: AMD64 payload marker, FEX startup log, expected status 100, and
  payload/translator hashes.
- `juicegui/`: current app-bundle JuiceGUI symlink plus a painted 1024x768
  desktop frame.
- `juicegui-arm-launch-retry/`: desktop pointer input and the expected
  160x226 ARM64 WineMine window.
- `juicegui-x64/`: desktop selection, version-1 launch action, FEX startup, and
  translated payload marker.
- `text/`: visible GDI frame, 20-unit UTF-16 input, create/render/input markers,
  and the resulting control length of 20.
- `controlled-wineboot/`: a genuinely new prefix ran controlled Wineboot,
  wrote `.juice-prefix-ready`, and then ran an ARM64 marker command. The
  disposable 182 MB proof prefix was removed after these files were copied.
- `msi-install/`: version-1 import response, msiexec installation, installed
  payload, and framebuffer.
- `msi-persistence-launch-retry/`: installed MSI catalog/file survived a full
  Juice/Wine restart and launched the expected application window.
- `msi-uninstall/`: product-code uninstall removed both the payload and catalog
  entry.
- `setup-install/`: ordinary ARM64 setup EXE import, install, registration, and
  installed-program launch markers.

Three deliberately retained diagnostic attempts are not release passes:

- `arm64/` was contaminated by a still-running WineMine from a preceding GUI
  launch. The exact test-owned processes were terminated before `arm64-retry`.
- `juicegui-arm-launch/` used the historical maximum-frame bound and therefore
  ignored the new full-screen 1024x768 desktop. The corrected bounds passed in
  `juicegui-arm-launch-retry`.
- `msi-persistence-launch/` selected the third registry row while the MSI entry
  sorted first. The corrected deterministic row selection passed in
  `msi-persistence-launch-retry`.

The MSI and setup imports used the repository's deterministic device-side peer
for the exact version-1 control wire protocol. This proves the Wine/UI bridge,
path return, and installer dispatch without private UIKit automation. Opening
and tapping the real `UIDocumentPickerViewController` remains an attended
release check on an unlocked iPad.

`SHA256SUMS` covers every evidence file in this directory.
