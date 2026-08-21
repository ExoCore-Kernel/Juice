# Installable builds

`Juice-Steam-Chocolate-Network-20260822.tipa` is the device-tested package
from commit `7df93a6`. It contains native ARM64, x86-64 FEX, i386 WoW64/FEX,
bundled GnuTLS networking, the SteamSetup unwind correction, and Normaliz.dll
for modern bootstrap installers.

The TIPA is stored with Git LFS. Verify it before installation:

```sh
sha256sum -c Juice-Steam-Chocolate-Network-20260822.tipa.sha256
```
