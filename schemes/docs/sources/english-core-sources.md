# English core

The fixed public source is Wolf Garbe's SymSpell v6.7.3 frequency dictionary at commit `2ac2df1d01c99711162c4c38a191e522ed4b29c7`. The original 1,332,881-byte UTF-8 BOM file is preserved in `sources/base/english-frequency.txt`.

The generator accepts ASCII words with internal apostrophes or hyphens, preserves positive original counts, and applies the explicit source-spelling integrity exclusion. Dictionary rows, vocabulary and recall indexes are generated from the same input. See [base reconstruction](base-dictionaries.md).

Source notices remain separate:

- [SymSpell MIT](../../licenses/english-core/SymSpell-MIT.txt) and [pinned README](../../licenses/english-core/SymSpell-upstream-README.md).
- [Google Books attribution](../../licenses/english-core/Google-Books-CC-BY-3.0-NOTICE.txt) and [CC BY 3.0 text](../../licenses/english-core/CC-BY-3.0-legalcode.txt).
- [SCOWL full README](../../licenses/english-core/SCOWL-full-README.txt) and [copyright, sources and credits](../../licenses/english-core/SCOWL-COPYRIGHT-SOURCES-CREDITS.txt).

The source dictionary combines Google Books Ngram and SCOWL. Their exact historical versions, corpus slices and complete filtering procedure remain unspecified by that source. Reproducing this fixed dictionary conversion is distinct from rebuilding every upstream corpus.
