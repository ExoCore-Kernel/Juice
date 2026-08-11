# Wine upstream and patch maintenance

The included wine directory is a complete Wine source tree based on:

    6eb2e4c32cc9e271856146df11ed3a5c2cf29234

That revision is recorded in config/wine-base.txt. The current Juice delta spans
62 paths. It includes the complete iOS driver and its versioned control channel,
ARM64/ARM64EC startup and signal work, Wineboot control, the native JuiceGUI and
smoke programs, expanded installer/runtime support, and one provenance file.
Both configure.ac and the generated configure file include every new component
so a release checkout does not require Autoconf just to register it.

Because the complete Wine tree lives beneath wine, its top-level-only
generated-file attribute macro would otherwise be invalid in this repository.
wine/.gitattributes expands that macro at each use; the resulting GitHub and
GitLab generated-file metadata is equivalent and works both nested and
standalone.

Two equivalent forms are deliberately shipped:

- wine is immediately buildable and contains no nested Git metadata.
- patches/wine-ios.patch is the auditable binary-safe delta against the base.

make verify runs git apply in reverse-check mode against wine. This proves that
the current patch exactly describes every modified and added Wine file. The
2026-08-11 core checkpoint patch SHA-256 is:

    837ad8d75adf0af46f93bc6c4fb06e4052f1d8f4e688bc81a439b44a791b9659

## Applying the patch elsewhere

In an upstream Wine Git checkout containing the recorded commit:

    git checkout 6eb2e4c32cc9e271856146df11ed3a5c2cf29234
    git apply /path/to/Juice/patches/wine-ios.patch

The resulting modified paths should match the included wine tree.

## Regenerating after a Wine edit

After editing the complete wine tree, point the repository helper at any Wine
Git checkout that contains the base commit:

    scripts/regenerate-wine-patch.sh /path/to/upstream-wine
    make verify

The helper creates a detached temporary worktree at the exact base, mirrors the
included wine source into it, includes new files with intent-to-add, checks the
diff, rewrites patches/wine-ios.patch, and reverse-verifies the result. It does
not alter the supplied checkout's branch or working tree.

Do not initialize a nested Git repository inside wine, and do not commit backup
files there. The source verifier rejects both.
