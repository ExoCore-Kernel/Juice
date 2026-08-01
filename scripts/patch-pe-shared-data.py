#!/usr/bin/env python3
"""Move Wine's ARM64 KUSER_SHARED_DATA pointer above iOS's 4 GiB page zero."""

import argparse
import os
import tempfile
from pathlib import Path

OLD = (0x000000007FFE0000).to_bytes(8, "little")
NEW = (0x000000017FFE0000).to_bytes(8, "little")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("pe_file", type=Path)
    parser.add_argument("--expected", type=int, default=1,
                        help="required number of old pointers (default: 1)")
    args = parser.parse_args()
    data = args.pe_file.read_bytes()
    old_count = data.count(OLD)
    new_count = data.count(NEW)

    if old_count == 0 and new_count:
        print(f"PE_SHARED_DATA_ALREADY_PATCHED file={args.pe_file} count={new_count}")
        return 0
    if old_count != args.expected:
        raise SystemExit(
            f"refusing to patch {args.pe_file}: expected {args.expected} old pointer(s), "
            f"found {old_count}; new pointer count is {new_count}"
        )

    patched = data.replace(OLD, NEW)
    descriptor, temporary = tempfile.mkstemp(prefix=args.pe_file.name + ".", dir=args.pe_file.parent)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(patched)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, args.pe_file.stat().st_mode)
        os.replace(temporary, args.pe_file)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f"PE_SHARED_DATA_PATCHED file={args.pe_file} count={old_count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
