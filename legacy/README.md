# Historical iPad material

This directory preserves small, source-only artifacts recovered during the
2026-08-01 repository audit. They are retained as provenance and are not active
build inputs.

- ipad-audit-20260801 is the curated source/script/log bundle copied from the
  development iPad. Its scripts contain historical absolute paths and obsolete
  build flags such as --without-freetype.
- experimental-toolchain contains superseded compiler and resource-wrapper
  experiments that were present in the local staging tree. The active build
  retains cleaned, relocatable Bison and PE-resource wrappers because the
  on-device audit proved both are required; the historical versions remain
  here only to document how those fixes evolved.

Use the scripts in the repository-level scripts directory. Do not copy the
historical scripts back over them.
