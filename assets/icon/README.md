# Star core product icon

`star-core.svg` is the editable geometric source. `star-core.ico` contains individually rendered frames at 16, 20, 24, 32, 48, 64, 128 and 256 pixels. The product uses this icon in `resource/weasel.ico` and `WeaselSetup/WeaselSetup.ico`.

The star recalls stellae, with a central point and dark background. The icon uses geometry only. Existing input-state icons retain their upstream sources.

Run `python generate.py --output <directory>` with Python 3 and Pillow to generate the SVG, ICO and a frame manifest in a separate directory. The renderer uses no installed fonts. Pillow versions may produce different PNG compression bytes; the release uses the checked-in ICO hash.

Original project icon assets and their generator use GPL-3.0-only. This explanatory text uses CC BY-SA 4.0.
