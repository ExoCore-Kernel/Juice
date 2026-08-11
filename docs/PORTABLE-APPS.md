# Portable applications

Juice accepts a Windows `.exe` or portable `.zip` from Files or the JuiceGUI
Install App command. ZIP contents are imported into a unique directory beneath
`/var/mobile/Documents/JuiceData/Imported`. The hierarchy is preserved, Juice
recursively finds `.exe` files, and a chooser is shown when more than one is
present. The selected executable's directory becomes the process working
directory, allowing adjacent DLLs, configuration files, plugins, and asset
subdirectories to resolve normally.

## Supported ZIP features

- Stored and Deflate compression.
- UTF-8 or legacy single-byte filenames.
- CRC-32 verification for every extracted file.
- Nested folders and multiple executable selection.
- A 4 GiB total extracted-data safety ceiling.

Encrypted, multi-volume, ZIP64, and non-Deflate compression methods are
rejected with an error in the Juice log. Absolute paths, drive-prefixed paths,
and `..` traversal are rejected. A failed extraction is removed.

The parser validates the central-directory boundary and the EOCD comment
length, so an EOCD-looking byte sequence inside an archive comment is not
mistaken for the real record.

## Compatibility expectations

Windows ARM64 applications and dependencies use the stable Grape runtime.
AMD64 applications are detected from the PE header and can use the separate,
experimental Grape-X64/FEX translator when it is packaged and enabled. Adjacent
AMD64 DLLs remain beside the executable and follow the same preserved working
directory. 32-bit x86 is not supported. Mixed-architecture plugins, kernel
drivers, and programs depending on unimplemented Wine APIs may still fail.

MSI and setup EXE installers are supported separately from portable ZIPs. MSI
uses Wine's msiexec; a setup EXE is routed according to its detected machine.
Installed programs and imported payloads live outside the app bundle and
persist across Juice restarts and updates.

The 2026-07-20 on-device milestone used the Notepad4 ARM64 portable archive:
eight files were preserved, `Notepad4.exe` and `matepath.exe` were discovered,
and the selected Notepad4 process delivered a 768 x 768 GUI frame. The exact
frame and logs are in `proofs/`.

Touch works across the normal client surface. Deliberate presses exactly on a
window border can still be less reliable and remain a known, non-blocking edge
case.
