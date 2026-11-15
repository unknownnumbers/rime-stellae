#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build the original En status artwork without fonts or external libraries."""

import argparse
import binascii
import hashlib
import json
from pathlib import Path
import struct
import zlib


ROOT = Path(__file__).resolve().parent
SIZES = (16, 20, 24, 32, 48, 64, 128, 256)
INK = (37, 99, 235, 255)
FACE = (255, 255, 255, 255)
SVG = b'''<?xml version="1.0" encoding="UTF-8"?>
<!-- SPDX-License-Identifier: GPL-3.0-only -->
<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32" role="img" aria-label="En">
  <rect x="1" y="1" width="30" height="30" fill="#2563eb"/>
  <rect x="2.5" y="2.5" width="27" height="27" fill="#ffffff"/>
  <path fill="#2563eb" d="M5 7H15V10H8V14H14V17H8V22H15V25H5Z"/>
  <path fill="#2563eb" d="M18 12H21V13.5C22 12.2 23.5 11.6 25 12.1C27 12.7 28 14.2 28 17V25H25V17.5C25 15.5 24.5 15 23.3 15C21.8 15 21 16.2 21 18V25H18Z"/>
</svg>
'''


def cubic(start, control1, control2, end, steps=32):
    result = []
    for step in range(1, steps + 1):
        t = step / steps
        u = 1.0 - t
        result.append(tuple(u ** 3 * start[i] + 3 * u * u * t * control1[i]
                            + 3 * u * t * t * control2[i] + t ** 3 * end[i]
                            for i in (0, 1)))
    return result


def letter_paths():
    capital_e = [(5, 7), (15, 7), (15, 10), (8, 10), (8, 14),
                 (14, 14), (14, 17), (8, 17), (8, 22), (15, 22),
                 (15, 25), (5, 25)]
    lower_n = [(18, 12), (21, 12), (21, 13.5)]
    lower_n += cubic((21, 13.5), (22, 12.2), (23.5, 11.6), (25, 12.1))
    lower_n += cubic((25, 12.1), (27, 12.7), (28, 14.2), (28, 17))
    lower_n += [(28, 25), (25, 25), (25, 17.5)]
    lower_n += cubic((25, 17.5), (25, 15.5), (24.5, 15), (23.3, 15))
    lower_n += cubic((23.3, 15), (21.8, 15), (21, 16.2), (21, 18))
    lower_n += [(21, 25), (18, 25)]
    return capital_e, lower_n


def paint_polygon(buffer, width, polygon, color, scale):
    points = [(x * scale, y * scale) for x, y in polygon]
    low = max(0, int(min(y for _, y in points)))
    high = min(width, int(max(y for _, y in points) + 1))
    pixel = bytes(color)
    for y in range(low, high):
        scan = y + 0.5
        intersections = []
        for index, (x1, y1) in enumerate(points):
            x2, y2 = points[(index + 1) % len(points)]
            if (y1 <= scan < y2) or (y2 <= scan < y1):
                intersections.append(x1 + (scan - y1) * (x2 - x1) / (y2 - y1))
        intersections.sort()
        for left, right in zip(intersections[::2], intersections[1::2]):
            first = max(0, int(left + 0.5))
            last = min(width, int(right + 0.5))
            start = 4 * (y * width + first)
            buffer[start:start + 4 * (last - first)] = pixel * (last - first)


def rgba(size):
    # Area sampling keeps small lettering clear while retaining partial alpha
    # around the outer frame. The SVG and the raster use the same coordinates.
    sampling = 4
    width = size * sampling
    scale = width / 32
    high = bytearray(width * width * 4)
    paint_polygon(high, width, [(1, 1), (31, 1), (31, 31), (1, 31)], INK, scale)
    paint_polygon(high, width, [(2.5, 2.5), (29.5, 2.5),
                               (29.5, 29.5), (2.5, 29.5)], FACE, scale)
    for polygon in letter_paths():
        paint_polygon(high, width, polygon, INK, scale)
    result = bytearray(size * size * 4)
    count = sampling * sampling
    for y in range(size):
        for x in range(size):
            offsets = [4 * ((y * sampling + dy) * width + x * sampling + dx)
                       for dy in range(sampling) for dx in range(sampling)]
            alpha = sum(high[offset + 3] for offset in offsets)
            target = 4 * (y * size + x)
            if alpha:
                for channel in range(3):
                    result[target + channel] = (sum(high[offset + channel] * high[offset + 3]
                                                   for offset in offsets) + alpha // 2) // alpha
            result[target + 3] = (alpha + count // 2) // count
    return bytes(result)


def icon_frame(size, pixels):
    # ICO uses bottom-up BGRA XOR pixels and a DWORD-aligned one-bit AND mask.
    header = struct.pack('<IiiHHIIiiII', 40, size, size * 2, 1, 32, 0,
                         size * size * 4, 0, 0, 0, 0)
    xor = bytearray()
    mask = bytearray()
    stride = ((size + 31) // 32) * 4
    for y in reversed(range(size)):
        row = bytearray(stride)
        for x in range(size):
            offset = (y * size + x) * 4
            red, green, blue, alpha = pixels[offset:offset + 4]
            xor.extend((blue, green, red, alpha))
            if not alpha:
                row[x // 8] |= 0x80 >> (x % 8)
        mask.extend(row)
    return header + xor + mask


def ico(images):
    frames = [icon_frame(size, pixels) for size, pixels in images]
    header = struct.pack('<HHH', 0, 1, len(frames))
    offset = len(header) + 16 * len(frames)
    directory = bytearray()
    for (size, _), frame in zip(images, frames):
        directory.extend(struct.pack('<BBBBHHII', size % 256, size % 256, 0, 0,
                                     1, 32, len(frame), offset))
        offset += len(frame)
    return header + directory + b''.join(frames)


def png(width, height, pixels):
    def chunk(kind, payload):
        return (struct.pack('>I', len(payload)) + kind + payload
                + struct.pack('>I', binascii.crc32(kind + payload) & 0xffffffff))
    rows = b''.join(b'\0' + pixels[y * width * 4:(y + 1) * width * 4]
                    for y in range(height))
    return (b'\x89PNG\r\n\x1a\n'
            + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
            + chunk(b'IDAT', zlib.compress(rows, 9)) + chunk(b'IEND', b''))


def preview(images):
    # Every row shows one icon at its native size and a nearest-neighbor detail.
    cell, rows = 288, len(images)
    width, height = cell * 2, cell * rows
    output = bytearray(bytes(FACE) * width * height)
    for index, (size, pixels) in enumerate(images):
        for column, factor in ((0, 1), (1, max(1, 256 // size))):
            drawn = size * factor
            left = column * cell + (cell - drawn) // 2
            top = index * cell + (cell - drawn) // 2
            for y in range(drawn):
                for x in range(drawn):
                    source = ((y // factor) * size + x // factor) * 4
                    target = ((top + y) * width + left + x) * 4
                    alpha = pixels[source + 3]
                    for channel in range(3):
                        output[target + channel] = (pixels[source + channel] * alpha
                                                    + 255 * (255 - alpha) + 127) // 255
    return png(width, height, bytes(output))


def validate_icon(blob, images):
    assert struct.unpack_from('<HHH', blob) == (0, 1, len(SIZES))
    for index, (size, pixels) in enumerate(images):
        width, height, colors, reserved, planes, bits, length, offset = struct.unpack_from(
            '<BBBBHHII', blob, 6 + index * 16)
        assert (width or 256, height or 256) == (size, size)
        assert (colors, reserved, planes, bits) == (0, 0, 1, 32)
        assert offset + length <= len(blob)
        assert struct.unpack_from('<IiiHH', blob, offset) == (40, size, size * 2, 1, 32)
        assert any(pixels[3::4]) and min(pixels[3::4]) < 255
        assert max(pixels[3::4]) == 255


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true',
                        help='Verify the checked-in SVG and ICO bytes without writing them.')
    parser.add_argument('--preview', type=Path, help='Write a private PNG contact sheet.')
    args = parser.parse_args()
    images = [(size, rgba(size)) for size in SIZES]
    outputs = {'smart-english.svg': SVG, 'smart-english.ico': ico(images)}
    validate_icon(outputs['smart-english.ico'], images)
    for name, content in outputs.items():
        path = ROOT / name
        if args.check:
            if path.read_bytes() != content:
                raise SystemExit('Generated asset differs: ' + name)
        else:
            path.write_bytes(content)
    if args.preview:
        args.preview.parent.mkdir(parents=True, exist_ok=True)
        args.preview.write_bytes(preview(images))
    print(json.dumps({'passed': True, 'sizes': SIZES, 'checked': args.check,
                      'files': {name: {'bytes': len(content),
                                       'sha256': hashlib.sha256(content).hexdigest()}
                                for name, content in outputs.items()}}, sort_keys=True))


if __name__ == '__main__':
    main()
