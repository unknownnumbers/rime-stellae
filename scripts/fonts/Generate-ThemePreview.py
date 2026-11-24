"""Render independent candidate-window and regional-font preview resources.

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
THEME_IDS = (
    'reference_gray', 'stellae_sakura', 'stellae_lavender',
    'stellae_night', 'stellae_crimson', 'stellae_mono',
)
FACES = {'SC': 2, 'TC': 3, 'HK': 4}
COLLECTION_SHA256 = 'b76b0433203017ca80401b2ee0dd69350349871c4b19d504c34dbdd80541690a'


def theme_color(text, name, surface=(255, 255, 255)):
    match = re.search(r'^      ' + re.escape(name) + r':\s*0x([0-9a-fA-F]{8})', text, re.M)
    if not match:
        raise ValueError('Missing theme color: ' + name)
    abgr = int(match[1], 16)
    alpha = (abgr >> 24) & 255
    return tuple(round(background + (((abgr >> shift) & 255) - background) * alpha / 255)
                 for background, shift in zip(surface, (0, 8, 16)))


def load_themes(path):
    text = path.read_text(encoding='utf-8-sig')
    match = re.search(r'(?ms)^  preset_color_schemes:\r?\n(.*?)(?=^  [^ \r\n]|\Z)', text)
    if not match:
        raise ValueError('Use the curated preset_color_schemes map.')
    themes = {}
    for item in re.finditer(r'(?ms)^    ([a-z0-9_]+):\r?\n(.*?)(?=^    [^ \r\n]|\Z)', match[1]):
        body = item[2]
        background = theme_color(body, 'back_color')
        themes[item[1]] = {'back_color': background}
        for key in (
            'border_color', 'text_color', 'candidate_text_color', 'label_color',
            'hilited_candidate_text_color', 'hilited_label_color',
            'hilited_candidate_back_color',
        ):
            themes[item[1]][key] = theme_color(body, key, background)
    if tuple(themes) != THEME_IDS:
        raise ValueError('The reviewed theme map must contain exactly six ordered themes.')
    return themes


def load_fonts(collection, default_font):
    with collection.open('rb') as stream:
        if file_digest(stream, 'sha256').hexdigest() != COLLECTION_SHA256:
            raise ValueError('Use the pinned Noto Sans CJK 2.004 Regular collection.')
    fonts = {'Default': ImageFont.truetype(str(default_font), 24, index=0)}
    if fonts['Default'].getname()[0] != 'Microsoft YaHei':
        raise ValueError('The Default preview uses the Windows Microsoft YaHei baseline.')
    for name, index in FACES.items():
        font = ImageFont.truetype(str(collection), 24, index=index)
        if font.getname()[0] != 'Noto Sans CJK ' + name:
            raise ValueError('Unexpected collection face: ' + name)
        fonts[name] = font
    return fonts


def render_fonts(fonts, label_font, selected):
    image = Image.new('RGB', (348, 150), 'white')
    draw = ImageDraw.Draw(image)
    draw.rectangle((8, 8, 339, 141), fill='#F5F6F8', outline='#D1D6DE')
    draw.text((20, 11), 'Default / SC / TC / HK', font=label_font, fill='#343E4D')
    for index, (name, font) in enumerate(fonts.items()):
        top = 29 + index * 27
        color = '#263D5B' if name == selected else '#404750'
        if name == selected:
            draw.rectangle((11, top, 336, top + 26), fill='#E0E9F5')
            draw.rectangle((12, top + 3, 15, top + 23), fill=color)
        draw.text((21, top + 5), name, font=label_font, fill=color)
        for column, character in enumerate(SAMPLE):
            draw.text((91 + column * 38, top + 22), character, font=font, fill=color, anchor='ls')
    return image


def render_theme(theme, default_font):
    image = Image.new('RGB', (348, 190), 'white')
    draw = ImageDraw.Draw(image)
    chinese = ImageFont.truetype(str(default_font), 18, index=0)
    english = ImageFont.truetype(str(default_font), 13, index=0)
    label = ImageFont.truetype(str(default_font), 11, index=0)
    caption = ImageFont.truetype(str(default_font), 13, index=0)
    bg, border = theme['back_color'], theme['border_color']
    draw.rounded_rectangle((8, 8, 339, 61), radius=8, fill=bg, outline=border)
    draw.text((17, 11), 'moxin|', font=english, fill=theme['text_color'])
    for index, word in enumerate(('墨芯', '墨心', '默心', '莫新', '莫心')):
        left = 15 + index * 64
        if index == 0:
            draw.rectangle((left - 2, 32, left + 57, 55), fill=theme['hilited_candidate_back_color'])
        text_color = theme['hilited_candidate_text_color' if index == 0 else 'candidate_text_color']
        label_color = theme['hilited_label_color' if index == 0 else 'label_color']
        draw.text((left, 38), str(index + 1) + '.', font=label, fill=label_color)
        draw.text((left + 15, 33), word, font=chinese, fill=text_color)
    draw.rounded_rectangle((8, 67, 167, 183), radius=8, fill=bg, outline=border)
    draw.text((17, 70), 'st|', font=english, fill=theme['text_color'])
    for index, word in enumerate(('stellae', 'style', 'studio', 'state', 'story', 'still')):
        top = 89 + index * 15
        if index == 0:
            draw.rectangle((15, top, 159, top + 15), fill=theme['hilited_candidate_back_color'])
        text_color = theme['hilited_candidate_text_color' if index == 0 else 'candidate_text_color']
        label_color = theme['hilited_label_color' if index == 0 else 'label_color']
        draw.text((17, top + 3), str(index + 1) + '.', font=label, fill=label_color)
        draw.text((34, top), word, font=english, fill=text_color)
    draw.text((184, 80), 'Chinese / 5', font=caption, fill='#555B66')
    draw.text((184, 103), 'English / 6', font=caption, fill='#555B66')
    return image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--theme', type=Path, required=True)
    parser.add_argument('--collection', type=Path, required=True)
    parser.add_argument('--default-font', type=Path, required=True)
    parser.add_argument('--output-directory', type=Path, required=True)
    args = parser.parse_args()
    fonts = load_fonts(args.collection, args.default_font)
    label = ImageFont.truetype(str(args.default_font), 12, index=0)
    themes = load_themes(args.theme)
    args.output_directory.mkdir(parents=True, exist_ok=True)
    files = []
    for identifier, theme in themes.items():
        output = args.output_directory / ('color_scheme_' + identifier + '.png')
        render_theme(theme, args.default_font).save(output, optimize=False, compress_level=9)
        files.append(output.name)
    for selected in (None, *fonts):
        suffix = '' if selected is None else '_' + selected.lower()
        output = args.output_directory / ('candidate_font' + suffix + '.png')
        render_fonts(fonts, label, selected).save(output, optimize=False, compress_level=9)
        files.append(output.name)
    print(json.dumps({'files': files, 'sample': SAMPLE, 'pillow': pillow_version,
                      'fontFaces': {name: font.getname()[0] for name, font in fonts.items()}},
                     ensure_ascii=True))


if __name__ == '__main__':
    main()
