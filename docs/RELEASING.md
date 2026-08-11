# Releasing

## Mandatory gates

1. Choose and add an open-source license for Juice-original code. Until then,
   the repository is source-available but does not grant reuse rights. Preserve
   Wine's LGPL-2.1-or-later notices and corresponding-source obligations.
2. Start from a clean checkout and run make verify.
3. On the target device, install the documented dependencies and run make
   preflight followed by make device.
4. Install the generated TIPA through TrollStore.
5. Manually test all of the following:
   - JuiceGUI fills the desktop, remains responsive, and exposes the host
     controls through its corner button.
   - WineMine creates a visible, stable window and receives left-click input.
   - Right click produces the expected context behavior in a suitable app.
   - Fullscreen enters and exits without losing the active surface.
   - The GDI text smoke visibly renders its heading, paragraphs, Unicode, edit
     text, and PASS state—not merely successful transport log lines.
   - One portable ZIP resolves an adjacent DLL or asset from its preserved
     directory.
   - The real UIKit document picker imports an MSI while the iPad is unlocked;
     cancellation also returns to JuiceGUI without hanging.
   - The MSI installs, appears after a Juice restart, launches, and uninstalls.
   - The setup EXE installs and launches its registered application.
   - If Grape-X64 is included, an AMD64 executable is auto-detected, visibly
     labelled experimental, routed through FEX, and writes its marker.
6. Run the deterministic ARM64, x86-64, text, control-channel, installer, and
   clean-prefix Wineboot smokes, then preserve their logs, markers, frames, and
   a SHA-256 manifest.
7. Confirm the app and driver log markers described in docs/CONTROLS.md and
   retain a scrubbed release log.
8. Run make zip-test on device.
9. Regenerate `patches/wine-ios.patch`, verify the FEX patch, and run
   `make verify` after the final source edit.
10. Run make source-archive and verify its gzip test and checksum.
11. Verify the TIPA with unzip -t and its generated checksum.

## GitHub contents

Commit source, documentation, workflow files, the complete modified wine tree,
the Wine patch, and small proof artifacts. Do not commit:

- build or dist;
- TIPA, IPA, runtime, or source archives;
- CoreTrust carrier output or autosign logs;
- Wine prefixes or imported Windows applications;
- device-specific signing material;
- nested Git metadata or backup copies;
- any individual file at or above GitHub's 100 MB boundary.

scripts/verify-source.sh checks the most common source-tree mistakes. Upload
TIPAs, source archives, immutable Diamond backups, and large runtime bundles as
GitHub release assets instead.

## Release notes

Record the Wine base commit, Juice revision, device model, iOS/iPadOS build,
toolchain versions, build date, runtime selection (curated or all PE), manual
tests, known issues, and SHA-256 values. Clearly distinguish stable ARM64 from
experimental x86-64 and any later experimental graphics backend.

Before publishing logs, inspect them for usernames, device identifiers, private
paths, imported application names, passwords, and keys.
