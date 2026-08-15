#!/usr/bin/env python3
import base64
import binascii
import os
import struct
import sys
import zlib

SIZE = 1024
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
RESOURCE_DIR = os.path.join(ROOT, "resources")


def load_b64_zlib(name):
    path = os.path.join(RESOURCE_DIR, name)
    with open(path, "rt", encoding="ascii") as handle:
        return zlib.decompress(base64.b64decode(handle.read().strip()))


ALPHA_PACKED = load_b64_zlib("AppIconMask2bit.b64")
ROW_RGB = load_b64_zlib("AppIconRows.b64")

if len(ALPHA_PACKED) != (SIZE * SIZE) // 4:
    raise SystemExit("Invalid Juice app icon mask length")
if len(ROW_RGB) != SIZE * 3:
    raise SystemExit("Invalid Juice app icon gradient length")

TARGETS = {
    "AppIcon1024x1024.png": 1024,
    "AppIcon60x60@2x.png": 120,
    "AppIcon60x60@3x.png": 180,
    "AppIcon76x76.png": 76,
    "AppIcon76x76@2x.png": 152,
    "AppIcon83.5x83.5@2x.png": 167,
}


def alpha_at(x, y):
    x = 0 if x < 0 else SIZE - 1 if x >= SIZE else x
    y = 0 if y < 0 else SIZE - 1 if y >= SIZE else y
    index = y * SIZE + x
    packed = ALPHA_PACKED[index >> 2]
    shift = (3 - (index & 3)) * 2
    return ((packed >> shift) & 3) / 3.0


def row_rgb(y):
    y = 0 if y < 0 else SIZE - 1 if y >= SIZE else y
    offset = y * 3
    return ROW_RGB[offset], ROW_RGB[offset + 1], ROW_RGB[offset + 2]


def png_chunk(kind, data):
    checksum = binascii.crc32(kind + data) & 0xFFFFFFFF
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", checksum)


def render(size):
    scanlines = []
    for out_y in range(size):
        src_y = (out_y + 0.5) * SIZE / size - 0.5
        y0 = int(src_y)
        fy = src_y - y0
        if y0 < 0:
            y0, fy = 0, 0.0
        y1 = min(SIZE - 1, y0 + 1)

        bg0 = row_rgb(y0)
        bg1 = row_rgb(y1)
        bg = tuple(bg0[c] * (1.0 - fy) + bg1[c] * fy for c in range(3))

        line = bytearray([0])  # PNG filter type 0
        for out_x in range(size):
            src_x = (out_x + 0.5) * SIZE / size - 0.5
            x0 = int(src_x)
            fx = src_x - x0
            if x0 < 0:
                x0, fx = 0, 0.0
            x1 = min(SIZE - 1, x0 + 1)

            a0 = alpha_at(x0, y0) * (1.0 - fx) + alpha_at(x1, y0) * fx
            a1 = alpha_at(x0, y1) * (1.0 - fx) + alpha_at(x1, y1) * fx
            alpha = a0 * (1.0 - fy) + a1 * fy

            for channel in range(3):
                value = int(round(bg[channel] * (1.0 - alpha) + 255.0 * alpha))
                line.append(max(0, min(255, value)))
        scanlines.append(bytes(line))

    raw = b"".join(scanlines)
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    return (
        b"\x89PNG\r\n\x1a\n"
        + png_chunk(b"IHDR", ihdr)
        + png_chunk(b"IDAT", zlib.compress(raw, 9))
        + png_chunk(b"IEND", b"")
    )


def main():
    output_dir = sys.argv[1] if len(sys.argv) > 1 else "."
    os.makedirs(output_dir, exist_ok=True)

    for name, size in TARGETS.items():
        path = os.path.join(output_dir, name)
        payload = render(size)
        with open(path, "wb") as handle:
            handle.write(payload)
        print(
            "JUICE_ICON_GENERATED "
            f"path={path} size={size}x{size} format=png-rgb8-noninterlaced bytes={len(payload)}"
        )


if __name__ == "__main__":
    main()
