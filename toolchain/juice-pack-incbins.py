#!/usr/bin/env python3
"""Collapse Winebuild's many resource .incbin slices into one packed blob."""

import os
import re
import sys
from pathlib import Path


def logical_absolute(path: Path, directory: Path) -> Path:
    """Return an absolute path without resolving the rootless /var/jb symlink."""
    if path.is_absolute():
        return Path(os.path.normpath(str(path)))
    return Path(os.path.normpath(str(directory / path)))


def resolve_resource(
    requested: str,
    assembly_directory: Path,
    original_directory: Path,
) -> Path:
    raw = Path(requested)
    build_directory = Path(
        os.environ.get(
            "JUICE_PE_BUILD_DIR",
            str(original_directory),
        )
    )

    candidates: list[Path] = []
    if raw.is_absolute():
        candidates.append(raw)

        # Some older Winebuild binaries emitted the rootless backing-store
        # spelling. Prefer its public /var/jb alias when it can be identified.
        text = str(raw)
        marker = "/procursus/"
        if text.startswith("/private/preboot/") and marker in text:
            candidates.append(Path("/var/jb") / text.split(marker, 1)[1])
    else:
        candidates.extend(
            (
                assembly_directory / raw,
                original_directory / raw,
                build_directory / raw,
            )
        )

    for candidate in candidates:
        try:
            if candidate.is_file():
                return candidate
        except OSError:
            pass

    raise FileNotFoundError(f"cannot resolve incbin resource: {requested}")


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: juice-pack-incbins.py assembly.s", file=sys.stderr)
        return 2

    # Python's getcwd() resolves /var/jb to /private/preboot on rootless iOS.
    # Make exports the logical PWD explicitly, so preserve it here.
    original_directory = Path(os.environ.get("PWD") or os.getcwd())
    assembly = logical_absolute(Path(sys.argv[1]), original_directory)
    assembly_directory = assembly.parent

    text = assembly.read_text(encoding="utf-8", errors="surrogateescape")
    pattern = re.compile(
        r"(?m)"
        r"^[ \t]*\.balign[ \t]+4[^\n]*\n"
        r"^(\.L__wine_spec_res_[0-9]+):[ \t]*\n"
        r"^[ \t]*\.incbin[ \t]+"
        r'"([^"\n]+)"'
        r"[ \t]*,[ \t]*([0-9]+)"
        r"[ \t]*,[ \t]*([0-9]+)"
        r"[^\n]*(?:\n|$)"
    )
    matches = list(pattern.finditer(text))
    if not matches:
        return 0

    packed_path = assembly_directory / (
        "." + assembly.name + ".juice-packed-resources.bin"
    )
    packed = bytearray()
    replacements: list[tuple[int, int, str]] = []
    base_symbol = ".L__wine_spec_packed_resources"
    assembler_packed_path = str(packed_path).replace("\\", "\\\\").replace('"', '\\"')

    for index, match in enumerate(matches):
        label = match.group(1)
        requested = match.group(2)
        input_offset = int(match.group(3))
        input_size = int(match.group(4))

        while len(packed) & 3:
            packed.append(0)
        packed_offset = len(packed)

        resource = resolve_resource(
            requested,
            assembly_directory,
            original_directory,
        )
        with resource.open("rb") as handle:
            handle.seek(input_offset)
            data = handle.read(input_size)
        if len(data) != input_size:
            raise RuntimeError(
                f"{resource}: wanted {input_size} bytes at offset "
                f"{input_offset}, got {len(data)}"
            )
        packed.extend(data)

        if index == 0:
            replacement = (
                "\t.balign 4\n"
                f"{base_symbol}:\n"
                f'\t.incbin "{assembler_packed_path}"\n'
                f"\t.set {label},{base_symbol}+{packed_offset}\n"
            )
        else:
            replacement = f"\t.set {label},{base_symbol}+{packed_offset}\n"
        replacements.append((match.start(), match.end(), replacement))

    pieces: list[str] = []
    position = 0
    for start, end, replacement in replacements:
        pieces.append(text[position:start])
        pieces.append(replacement)
        position = end
    pieces.append(text[position:])

    temporary_assembly = assembly.with_name(assembly.name + ".juice-new")
    temporary_packed = packed_path.with_name(packed_path.name + ".new")
    temporary_packed.write_bytes(packed)
    temporary_assembly.write_text(
        "".join(pieces),
        encoding="utf-8",
        errors="surrogateescape",
    )
    os.replace(temporary_packed, packed_path)
    os.replace(temporary_assembly, assembly)

    print(
        "juice-pe-clang: packed "
        f"{len(matches)} incbin directives into one "
        f"{len(packed)}-byte resource file",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"juice-pe-clang: packing failed: {error}", file=sys.stderr)
        raise SystemExit(1)
