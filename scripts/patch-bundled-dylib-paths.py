#!/usr/bin/env python3
"""Make bundled iOS dylibs resolve one another from Juice.app/Libraries.

Procursus rootless packages use install names rooted at /var/jb/usr/lib. Juice
ships a small self-contained subset of those libraries inside the app bundle,
so rewrite only dependency load commands whose basename is present beside the
dylib. Keep each dylib's LC_ID_DYLIB unchanged: the ID is not used to locate the
library being opened.

Mach-O load-command strings have fixed capacities. Some Procursus dependency
commands are too small to hold ``@loader_path/<original-long-name>``. In that
case create a compact local alias (j0, j1, ...) and point the dependency at
``@loader_path/<alias>``. Alias files are copied only after all original dylibs
have been patched, so aliases contain the same already-fixed dependency graph.
Apple/system dependencies are left untouched.

Zip-based iOS installers do not consistently preserve symbolic links. After
patching each canonical dylib, replace every Procursus soname symlink with a
regular copy of its fully patched target. The resulting Juice.app is therefore
self-contained even when a TIPA extractor flattens link metadata.
"""

from __future__ import annotations

import pathlib
import shutil
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
LC_LOAD_DYLIB = 0xC
LC_ID_DYLIB = 0xD
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_LAZY_LOAD_DYLIB = 0x20
LC_LOAD_UPWARD_DYLIB = 0x80000023
DEPENDENCY_COMMANDS = {
    LC_LOAD_DYLIB,
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


def encoded_length(value: str) -> int:
    return len(value.encode("utf-8", errors="surrogateescape")) + 1


def replace_c_string(data: bytearray, start: int, end: int, value: str, path: pathlib.Path) -> None:
    encoded = value.encode("utf-8", errors="surrogateescape") + b"\0"
    capacity = end - start
    if len(encoded) > capacity:
        fail(f"replacement path does not fit in {path}: {value!r} ({len(encoded)} > {capacity})")
    data[start:end] = b"\0" * capacity
    data[start : start + len(encoded)] = encoded


class AliasTable:
    def __init__(self, directory: pathlib.Path, reserved_names: set[str]) -> None:
        self.directory = directory
        self.reserved_names = set(reserved_names)
        self.by_target: dict[str, str] = {}

    def get(self, target_basename: str) -> str:
        existing = self.by_target.get(target_basename)
        if existing is not None:
            return existing

        index = len(self.by_target)
        while True:
            alias = f"j{index}"
            index += 1
            if alias not in self.reserved_names:
                break
        self.reserved_names.add(alias)
        self.by_target[target_basename] = alias
        return alias

    def materialize(self) -> int:
        count = 0
        for target_basename, alias in sorted(self.by_target.items(), key=lambda item: item[1]):
            source = self.directory / target_basename
            destination = self.directory / alias
            if not source.exists():
                fail(f"alias target disappeared: {source}")
            if destination.exists() or destination.is_symlink():
                fail(f"alias destination already exists: {destination}")
            # Follow Procursus soname symlinks and copy the fully patched target.
            # This makes the eventual app bundle independent of symlink handling
            # by zip/installers and lets the normal signing pass sign each alias.
            shutil.copy2(source, destination, follow_symlinks=True)
            print(f"JUICE_DYLIB_ALIAS alias={alias} target={target_basename}")
            count += 1
        return count


def patch_one(path: pathlib.Path, available: set[str], aliases: AliasTable) -> int:
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

        # LC_ID_DYLIB describes this file's identity; it is not a dependency
        # lookup path. Leave it intact. Only dependency commands need to be
        # redirected away from Procursus /var/jb paths into Juice.app/Libraries.
        if cmd in DEPENDENCY_COMMANDS:
            if cmdsize < 24:
                fail(f"short dylib load command in {path}")
            name_offset = struct.unpack_from("<I", data, offset + 8)[0]
            if name_offset < 24 or name_offset >= cmdsize:
                fail(f"invalid dylib name offset in {path}")
            start = offset + name_offset
            end = offset + cmdsize
            capacity = end - start
            old = decode_c_string(data, start, end)
            basename = pathlib.PurePosixPath(old).name

            replacement = None
            if basename in available:
                direct = f"@loader_path/{basename}"
                if encoded_length(direct) <= capacity:
                    replacement = direct
                else:
                    alias = aliases.get(basename)
                    compact = f"@loader_path/{alias}"
                    if encoded_length(compact) > capacity:
                        fail(
                            f"even compact dependency alias does not fit in {path}: "
                            f"{compact!r} ({encoded_length(compact)} > {capacity})"
                        )
                    replacement = compact

            if replacement and replacement != old:
                replace_c_string(data, start, end, replacement, path)
                changed += 1
                print(f"JUICE_DYLIB_REWRITE file={path.name} old={old} new={replacement}")

        offset += cmdsize

    if changed:
        path.write_bytes(data)
    return changed


def materialize_symlinks(directory: pathlib.Path, entries: list[pathlib.Path]) -> int:
    links: list[tuple[pathlib.Path, pathlib.Path]] = []
    directory_resolved = directory.resolve()
    for entry in entries:
        if not entry.is_symlink():
            continue
        try:
            target = entry.resolve(strict=True)
        except FileNotFoundError:
            fail(f"dangling bundled dylib symlink: {entry}")
        if target.parent != directory_resolved:
            fail(f"bundled dylib symlink escapes its directory: {entry} -> {target}")
        if not target.is_file():
            fail(f"bundled dylib symlink target is not a file: {entry} -> {target}")
        links.append((entry, target))

    for entry, target in sorted(links):
        entry.unlink()
        shutil.copy2(target, entry)
        print(f"JUICE_DYLIB_SYMLINK_COPY name={entry.name} target={target.name}")
    return len(links)


def main(directory: pathlib.Path) -> None:
    if not directory.is_dir():
        fail(f"not a directory: {directory}")

    entries = list(directory.iterdir())
    available = {entry.name for entry in entries if entry.exists() or entry.is_symlink()}
    # Capture the original real files before aliases are created. Aliases are
    # materialized afterwards from these already-patched files.
    files = [entry for entry in entries if entry.is_file() and not entry.is_symlink()]
    aliases = AliasTable(directory, available)
    patched_files = 0
    rewritten_commands = 0
    for path in sorted(files):
        count = patch_one(path, available, aliases)
        if count:
            patched_files += 1
            rewritten_commands += count

    symlink_count = materialize_symlinks(directory, entries)
    alias_count = aliases.materialize()
    print(
        f"JUICE_BUNDLED_DYLIB_PATHS_OK path={directory} "
        f"files={patched_files} rewrites={rewritten_commands} "
        f"symlinks={symlink_count} aliases={alias_count}"
    )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} LIBRARIES_DIR")
    main(pathlib.Path(sys.argv[1]))
