#!/usr/bin/env python3
"""Shrink an arm64 iOS MH_EXECUTE __PAGEZERO so Wine WoW64 can use low VA.

Apple's iOS linker does not support -pagezero_size and emits a 4 GiB
__PAGEZERO for arm64 executables. Wine's WoW64 implementation genuinely needs
32-bit process data below 2 GiB. Juice signs the runtime after staging, so it
can safely adjust this load-command field before ldid signs the final TIPA.
"""

from __future__ import annotations

import pathlib
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
MH_EXECUTE = 0x2
LC_SEGMENT_64 = 0x19
PAGEZERO = b"__PAGEZERO"
IOS_HOST_PAGE = 0x4000


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"pagezero patch: {message}")


def patch(path: pathlib.Path) -> None:
    data = bytearray(path.read_bytes())
    if len(data) < 32:
        fail(f"{path} is too small to be Mach-O")

    magic, _cpu, _subcpu, filetype, ncmds, sizeofcmds, _flags, _reserved = struct.unpack_from(
        "<8I", data, 0
    )
    if magic != MH_MAGIC_64:
        fail(f"{path} is not a thin little-endian 64-bit Mach-O (magic=0x{magic:08x})")
    if filetype != MH_EXECUTE:
        fail(f"{path} is not MH_EXECUTE (filetype={filetype})")
    if 32 + sizeofcmds > len(data):
        fail(f"{path} has truncated load commands")

    offset = 32
    found = False
    old_size = None
    for _ in range(ncmds):
        if offset + 8 > len(data):
            fail(f"{path} has truncated load command header")
        cmd, cmdsize = struct.unpack_from("<2I", data, offset)
        if cmdsize < 8 or offset + cmdsize > len(data):
            fail(f"{path} has invalid load command size {cmdsize}")

        if cmd == LC_SEGMENT_64:
            if cmdsize < 72:
                fail(f"{path} has short LC_SEGMENT_64")
            segname = bytes(data[offset + 8 : offset + 24]).split(b"\0", 1)[0]
            if segname == PAGEZERO:
                vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<4Q", data, offset + 24)
                _maxprot, initprot = struct.unpack_from("<2i", data, offset + 56)
                if vmaddr != 0 or fileoff != 0 or filesize != 0 or initprot != 0:
                    fail(
                        f"unexpected __PAGEZERO layout in {path}: "
                        f"vmaddr=0x{vmaddr:x} vmsize=0x{vmsize:x} "
                        f"fileoff=0x{fileoff:x} filesize=0x{filesize:x} initprot={initprot}"
                    )
                old_size = vmsize
                if vmsize < IOS_HOST_PAGE:
                    fail(f"__PAGEZERO in {path} is smaller than one iOS host page")
                struct.pack_into("<Q", data, offset + 32, IOS_HOST_PAGE)
                found = True
                break
        offset += cmdsize

    if not found:
        fail(f"{path} has no __PAGEZERO segment")

    path.write_bytes(data)
    print(
        f"JUICE_WOW64_PAGEZERO_PATCHED path={path} "
        f"old=0x{old_size:x} new=0x{IOS_HOST_PAGE:x}"
    )


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} MACHO")
    patch(pathlib.Path(sys.argv[1]))
