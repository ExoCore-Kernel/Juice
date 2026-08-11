# Verified iPad screenshots

These are the curated, non-blank full-window captures from the iPad. They use
the same `wineios.drv` framebuffer protocol as the Juice UIKit host. Raw
power-of-two child surfaces and blank pre-paint frames remain only in the
underlying `proofs/` evidence directories, not in this gallery.

- `01-juicegui-desktop.png`: clean 1024x768 modern JuiceGUI desktop with
  owner-drawn shortcuts and its lightweight built-in wallpaper.
- `JuiceGUI-desktop-WORKING.png`: cache-safe re-encoded copy of the same
  visually verified desktop capture, provided under an unmistakable filename.
- `02-winemine-launched-from-juicegui.png`: full 1024x768 JuiceGUI desktop
  showing the WineMine selection and the readable `Launched winemine.exe`
  result. The raw WineMine child surface is retained with its driver log under
  `proofs/verified/2026-08-11/juicegui/juicegui-arm-launch-v2/`.
- `03-text-rendering-and-input.png`: Win32/GDI text and focused EDIT input.
- `04-msi-import-through-juicegui.png`: JuiceGUI after the deterministic
  control-bridge MSI import/install test.
- `05-x86-64-launch-requested-from-juicegui.png`: JuiceGUI after selecting its
  experimental x86-64 entry; the paired marker and FEX logs live under
  `proofs/verified/2026-08-11/juicegui/juicegui-x64-launch-v2/`.
- `06-msi-installed-and-persistent.png`: the MSI-installed program still
  listed after JuiceGUI and Wine were restarted.
- `07-custom-wallpaper.png`: the same desktop loading and centre-cropping a
  temporary user-supplied BMP from Juice's persistent data directory. The test
  bitmap was removed from the iPad after capture so it does not become the
  user's wallpaper.

See `SHA256SUMS` for integrity hashes and `proofs/verified/` for the complete
logs and marker files behind each screenshot.
