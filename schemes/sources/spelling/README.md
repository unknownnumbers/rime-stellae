# Chinese spelling sources

`cn-syllables.txt` is the fixed, sorted canonical syllable inventory used by the
Chinese classifiers. It contains the 424 lowercase spelling codes from the
maintained original `sources/base/luna_pinyin.dict.yaml`, excluding `xx`. The
generator checks this inventory against that independent source. It also matches
the previously distributed classifier keys. No learning records are inputs.

`config/pc/stellae/spelling.yaml` is the maintained, ordered prism algebra. Its
8,513 rules include exact, reliable, normal-only, abbreviation and error channels.
The rule order is part of the input behavior. This file is a fixed source input,
not an output reconstructed from the Lua tables. Edit it deliberately when
changing spelling behavior and verify the resulting prism and candidates.

Run `python scripts/data/rebuild_chinese_spelling.py` from `schemes/` to rebuild
`config/pc/lua/data/cn_forms.lua`, `cn_extra_forms.lua` and the shared QWERTY table
`config/pc/lua/cn/cn_neighbor_keys.lua`. `--check` verifies the
distributed bytes without writing. The generator uses only the fixed inventory
and its documented bounded spelling operations. It does not require an old
research directory, a dictionary download, a deployed profile or a user database.
The original Luna source and its LGPL-3.0 notice remain under their existing
component attribution. The generator and original spelling expressions use the
project's GPL-3.0-only code terms; this explanatory text uses CC BY-SA 4.0.

The base table records full spelling (0), proper prefix (1) and one legacy error
(2). The extra table records independent feature bits for interior deletion (1),
QWERTY neighbor substitution (2) and the approved double swaps (4). Error outputs
are never fed back into error expansion. The generated frontend profiles retain
the same tables; frontend capability adapters do not change spelling data.

`config/pc/lua/cn/cn_normal_codec.lua` contains the maintained, fixed 26-letter
alphabet used by the normal-only internal channel. Its mapping and encode/decode
functions are source inputs. Keep that alphabet consistent with the ordered
normal-only rules in `stellae/spelling.yaml` when changing channel behavior.
