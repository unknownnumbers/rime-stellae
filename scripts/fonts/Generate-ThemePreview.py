"""Render static theme previews with actual regional font faces.

SPDX-License-Identifier: GPL-3.0-only
"""
from __future__ import annotations

import argparse
from hashlib import file_digest
import json
from pathlib import Path
import re

from PIL import Image, ImageDraw, ImageFont, __version__ as pillow_version


SAMPLE = '骨直令返望花'
FACES = {'SC': 2, 'TC': 3, 'HK': 4}
COLLECTION_SHA256 = 'b76b0433203017ca80401b2ee0dd69350349871c4b19d504c34dbdd80541690a'


def theme_color(text, name):
    match = re.search(r'^    ' + re.escape(name) + r':\s*0x([0-9a-fA-F]{8})', text, re.M)
    if not match:
        raise ValueError('Missing theme color: ' + name)
    abgr = int(match[1], 16)
    alpha = (abgr >> 24) & 255
    return tuple(round(255 - (255 - ((abgr >> shift) & 255)) * alpha / 255)
                 for shift in (0, 8, 16))


def load_fonts(collection, default_font):
    with collection.open('rb') as stream:
        if file_digest(stream, 'sha256').hexdigest() != COLLECTION_SHA256:
            raise ValueError('Use the pinned Noto Sans CJK 2.004 Regular collection.')
    fonts = {'Default': ImageFont.truetype(str(default_font), 36, index=0)}
    if fonts['Default'].getname()[0] != 'Microsoft YaHei':
        raise ValueError('The Default preview uses the Windows Microsoft YaHei baseline.')
    for name, index in FACES.items():
        font = ImageFont.truetype(str(collection), 36, index=index)
        if font.getname()[0] != 'Noto Sans CJK ' + name:
            raise ValueError('Unexpected collection face: ' + name)
        fonts[name] = font
    return fonts


def render(theme, fonts, label_font, selected):
    image = Image.new('RGB', (348, 236), 'white')
    draw = ImageDraw.Draw(image)
    draw.rectangle((8, 8, 339, 227), fill=theme['back_color'], outline=theme['border_color'])
    draw.text((20, 15), 'Default / SC / TC / HK', font=label_font, fill=theme['text_color'])
    for index, (name, font) in enumerate(fonts.items()):
        top = 48 + index * 43
        color = theme['hilited_candidate_text_color' if name == selected else 'candidate_text_color']
        if name == selected:
            draw.rectangle((12, top, 16, top + 35), fill=color)
        draw.text((21, top + 9), name, font=label_font, fill=color)
        for column, character in enumerate(SAMPLE):
            draw.text((91 + column * 39, top + 33), character, font=font, fill=color, anchor='ls')
    return image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--theme', type=Path, required=True)
    parser.add_argument('--collection', type=Path, required=True)
    parser.add_argument('--default-font', type=Path, required=True)
    parser.add_argument('--output-file', type=Path, required=True)
    args = parser.parse_args()
    fonts = load_fonts(args.collection, args.default_font)
    label = ImageFont.truetype(str(args.default_font), 14, index=0)
    text = args.theme.read_text(encoding='utf-8-sig')
    colors = {key: theme_color(text, key) for key in (
        'back_color', 'border_color', 'text_color', 'candidate_text_color',
        'hilited_candidate_text_color',
    )}
    args.output_file.parent.mkdir(parents=True, exist_ok=True)
    files = []
    for selected in (None, *fonts):
        suffix = '' if selected is None else '_' + selected.lower()
        output = args.output_file.with_stem(args.output_file.stem + suffix)
        render(colors, fonts, label, selected).save(output, optimize=False, compress_level=9)
        files.append(output.name)
    print(json.dumps({'files': files, 'sample': SAMPLE, 'pillow': pillow_version,
                      'fontFaces': {name: font.getname()[0] for name, font in fonts.items()}},
                     ensure_ascii=True))


if __name__ == '__main__':
    main()
