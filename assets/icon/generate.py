# SPDX-License-Identifier: GPL-3.0-only
"""Render the star core product icon without using system fonts."""
import argparse
import hashlib
import json
from pathlib import Path

from PIL import Image, ImageDraw

SIZES = (16, 20, 24, 32, 48, 64, 128, 256)
BG = '#172839'
WHITE = '#F5FAFF'
ACCENT = '#77C7EE'
SVG = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">'
       f'<rect x="1" y="1" width="30" height="30" rx="6" fill="{BG}"/>'
       f'<path d="M16 5L19.3 12.7L27 16L19.3 19.3L16 27L12.7 19.3L5 16L12.7 12.7Z" fill="{WHITE}"/>'
       f'<circle cx="16" cy="16" r="2.2" fill="{ACCENT}"/></svg>\n')


def render(size):
    scale = 8
    image = Image.new('RGBA', (32 * scale, 32 * scale))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((scale, scale, 31 * scale, 31 * scale),
                           radius=6 * scale, fill=BG)
    points = [(16, 5), (19.3, 12.7), (27, 16), (19.3, 19.3),
              (16, 27), (12.7, 19.3), (5, 16), (12.7, 12.7)]
    draw.polygon([(x * scale, y * scale) for x, y in points], fill=WHITE)
    draw.ellipse((13.8 * scale, 13.8 * scale, 18.2 * scale, 18.2 * scale), fill=ACCENT)
    return image.resize((size, size), Image.Resampling.LANCZOS)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / 'star-core.svg').write_text(SVG, encoding='utf-8', newline='\n')
    frames = [render(size) for size in SIZES]
    target = args.output / 'star-core.ico'
    frames[-1].save(target, format='ICO', sizes=[(n, n) for n in SIZES],
                    append_images=frames[:-1])
    with Image.open(target) as icon:
        actual = sorted(icon.ico.sizes())
        if actual != [(n, n) for n in SIZES]:
            raise RuntimeError('Unexpected ICO frames')
        for dimensions in actual:
            if icon.ico.getimage(dimensions).size != dimensions:
                raise RuntimeError('Unreadable ICO frame')
    manifest = {'file': target.name, 'sizes': [list(size) for size in actual],
                'sha256': hashlib.sha256(target.read_bytes()).hexdigest()}
    (args.output / 'frames.json').write_text(json.dumps(manifest, indent=2) + '\n',
                                            encoding='utf-8', newline='\n')
    print(json.dumps(manifest))


if __name__ == '__main__':
    main()
