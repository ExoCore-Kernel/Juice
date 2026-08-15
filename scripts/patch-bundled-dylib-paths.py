#!/usr/bin/env python3
"""Make bundled iOS dylibs resolve one another from Juice.app/Libraries.

Procursus rootless packages use install names rooted at /var/jb/usr/lib. Juice
ships a small self-contained subset of those libraries inside the app bundle,
so rewrite only dependencies whose basename is present beside the dylib. This
keeps Apple/system dependencies untouched and avoids requiring the destination
jailbreak to have matching optional packages installed.
"""

from __future__ import annotations

import pathlib
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
LC_LOAD_DYLIB = 0xC
LC_ID_DYLIB = 0xD
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_LAZY_LOAD_DYLIB = 0x20
LC_LOAD_UPWARD_DYLIB = 0x80000023
DYLIB_COMMANDS = {
    LC_LOAD_DYLIB,
    LC_ID_DYLIB,
    LC_LOAD_WEAK_DYLIB,
    LC_REEXPORT_DYLIB,
    LC_LAZY_LOAD_DYLIB,
    LC_LOAD_UPWARD_DYLIB,
}


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"bundled-dylib patch: {message}")


def decode_c_string(data: bytearray, start: int, end: int) -> str:
    raw = bytes(data[start:end]).split(b"\0", 1)[0]
    return raw.decode("utf-8", errors="surrogateescape")


def replace_c_string(data: bytearray, start: int, end: int, value: str, path: pathlib.Path) -> None:
    encoded = value.encode("utf-8", errors="surrogateescape") + b"\0"
    capacity = end - start
    if len(encoded) > capacity:
        fail(f"replacement path does not fit in {path}: {value!r} ({len(encoded)} > {capacity})")
    data[start:end] = b"\0" * capacity
    data[start : start + len(encoded)] = encoded


def patch_one(path: pathlib.Path, available: set[str]) -> int:
    data = bytearray(path.read_bytes())
    if len(data) < 32:
        return 0

    magic, _cpu, _subcpu, _filetype, ncmds, sizeofcmds, _flags, _reserved = struct.unpack_from(
        "<8I", data, 0
    )
    if magic != MH_MAGIC_64:
        return 0
    if 32 + sizeofcmds > len(data):
        fail(f"truncated load commands in {path}")

    changed = 0
    offset = 32
    for _ in range(ncmds):
        if offset + 8 > len(data):
            fail(f"truncated load command header in {path}")
        cmd, cmdsize = struct.unpack_from("<2I", data, offset)
        if cmdsize < 8 or offset + cmdsize > len(data):
            fail(f"invalid load command size {cmdsize} in {path}")

        if cmd in DYLIB_COMMANDS:
            if cmdsize < 24:
                fail(f"short dylib load command in {path}")
            name_offset = struct.unpack_from("<I", data, offset + 8)[0]
            if name_offset < 24 or name_offset >= cmdsize:
                fail(f"invalid dylib name offset in {path}")
            start = offset + name_offset
            end = offset + cmdsize
            old = decode_c_string(data, start, end)
            basename = pathlib.PurePosixPath(old).name

            replacement = None
            if cmd == LC_ID_DYLIB:
                replacement = f"@loader_path/{path.name}"
            elif basename in available:
                replacement = f"@loader_path/{basename}"

            if replacement and replacement != old:
                replace_c_string(data, start, end, replacement, path)
                changed += 1
                print(f"JUICE_DYLIB_REWRITE file={path.name} old={old} new={replacement}")

        offset += cmdsize

    if changed:
        path.write_bytes(data)
    return changed


def main(directory: pathlib.Path) -> None:
    if not directory.is_dir():
        fail(f"not a directory: {directory}")

    entries = list(directory.iterdir())
    available = {entry.name for entry in entries if entry.exists() or entry.is_symlink()}
    files = [entry for entry in entries if entry.is_file() and not entry.is_symlink()]
    patched_files = 0
    rewritten_commands = 0
    for path in sorted(files):
        count = patch_one(path, available)
        if count:
            patched_files += 1
            rewritten_commands += count

    print(
        f"JUICE_BUNDLED_DYLIB_PATHS_OK path={directory} "
        f"files={patched_files} rewrites={rewritten_commands}"
    )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} LIBRARIES_DIR")
    main(pathlib.Path(sys.argv[1]))
