# Base dictionary sources

The general Chinese vocabulary and preset frequencies originate from the official [Weasel 0.17.4](https://github.com/rime/weasel/releases/tag/0.17.4) data package. The unchanged inputs are committed in `sources/base/`. `source-manifest.json` records their exact bytes and SHA256 values. Luna and essay retain their original authorship and LGPL-3.0 notices.

Existing Chinese source-code integrity repairs are recorded in `sources/quality/dictionary-integrity.json`, with public reading references. The generator checks the original rows and retains existing canonical rows when removing erroneous duplicates. These repairs do not change corpus frequencies.

The English core uses [SymSpell v6.7.3](https://github.com/wolfgarbe/SymSpell/blob/2ac2df1d01c99711162c4c38a191e522ed4b29c7/SymSpell/frequency_dictionary_en_82_765.txt), commit `2ac2df1d01c99711162c4c38a191e522ed4b29c7`. Its 82,834 input rows retain their original counts, apart from the recorded malformed source-spelling exclusion. The source combines Google Books Ngram and SCOWL. Exact historical corpus slices and the full upstream filtering pipeline are not reconstructed by this repository.

English canonical forms and aliases are generated systematically from the complete fixed [Ice extension source](https://github.com/iDvel/rime-ice/blob/da1fbe602e38f26db846fa10120ee64c2b0324c0/en_dicts/en_ext.dict.yaml). The existing spelling algebra handles digits and symbols. Native word identities remain shared between aliases and core words when applicable.

Case-collision evidence uses the complete SCOWL 2020.12.07 archive, exact original-case membership in the cumulative `english`、`american` and `british` word lists through size 80. Absence is treated as unconfirmed rather than linguistically invalid. The full SCOWL notices accompany the source.

`scripts/data/rebuild_base.py` verifies fixed inputs, applies the code/spelling integrity records, generates both profiles and rebuilds their prefix-delete indexes. `sources/base-build.json` records aggregate output counts. No input behavior is inferred from frequency-table order.

The compact model is unchanged; see [model sources](luna-compact-model-sources.md). [English notices](english-core-sources.md) | [License index](../../THIRD_PARTY_NOTICES.md)
