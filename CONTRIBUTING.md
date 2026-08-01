# Contributing

Keep changes focused and preserve the verified iOS path. Run
scripts/verify-source.sh before submitting changes. Changes to the ZIP extractor
should include safe and unsafe fixture coverage; changes to rendering or input
should include on-device frame, touch, and text logs plus the visible result.

Do not commit generated runtimes, TIPAs, Wine build directories, imported
Windows applications, backup copies, device signing artifacts, or nested Git
metadata. Wine changes must be reflected both in wine and in the audit patch.
Run scripts/regenerate-wine-patch.sh against an upstream Wine checkout at the
recorded base, then run make verify.
