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
   - WineMine creates a visible, stable window and receives left-click input.
   - Right click produces the expected context behavior in a suitable app.
   - Fullscreen enters and exits without losing the active surface.
   - Notepad4 or another ARM64 edit control visibly renders typed text and
     Enter, not merely successful transport log lines.
   - One portable ZIP resolves an adjacent DLL or asset from its preserved
     directory.
6. Confirm the app and driver log markers described in docs/CONTROLS.md and
   retain a scrubbed release log.
7. Run make zip-test on device.
8. Run make source-archive and verify its gzip test and checksum.
9. Verify the TIPA with unzip -t and its generated checksum.

Do not declare the current text milestone complete until a FreeType-enabled
build visibly draws glyphs in a Windows control.

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
tests, known issues, and SHA-256 values.

Before publishing logs, inspect them for usernames, device identifiers, private
paths, imported application names, passwords, and keys.
