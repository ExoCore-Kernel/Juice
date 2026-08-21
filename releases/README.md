# Installable builds

`Juice-Steam-Chocolate-Network-v0.2.0-rc1.tipa` is the current release
candidate. It contains native ARM64, x86-64 FEX, i386 WoW64/FEX, bundled
GnuTLS networking, the SteamSetup unwind correction, and Normaliz.dll for
modern bootstrap installers. Its nested iOS Wine executables and libraries are
ad-hoc signed by the reproducible Linux packaging path.

`Juice-Steam-Chocolate-Network-20260822.tipa` is retained as the preceding
milestone artifact, but is superseded by `v0.2.0-rc1` because its Linux reuse
build could skip nested Mach-O signing.

The TIPA is stored with Git LFS. Verify it before installation:

```sh
sha256sum -c Juice-Steam-Chocolate-Network-v0.2.0-rc1.tipa.sha256
```
