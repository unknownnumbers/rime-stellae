# Stellae schemes

> This project is created through human-AI collaboration. Some AI-proposed content may not yet have been reviewed by a human. Please excuse any errors or omissions.

[English (en)](README.en.md) | [Traditional Chinese (zh-TC)](README.md) | [Simplified Chinese (zh-SC)](README.zh-SC.md)

Stellae provides Chinese, English and Japanese input schemes for the Stellae frontend and a compatible scheme package for official Weasel.

## Available features

- Chinese full spelling, abbreviations, existing correction rules, composition and local learning, with TC/SC output switching. Use `;` to lock the preceding complete syllable, and `"` to confirm complete spelling across the preceding draft. Examples include `xiao;sr`, `woxiang"` and `wenti"s`.
- From key 8, both profiles use ordinary sentence composition when the caret is at the end of a draft that can only be split into single-letter initials.
- English words, completion, correction, case handling and existing acronym expansions.
- Character lookup, Unicode input and calculation run on demand.
- Both profiles provide hiragana, katakana, kanji, romaji, q/x/v queries and fixed mixed phrases.
- The official Weasel profile uses native word completion, six vertical candidates and non-inline composition.
- The default uses general vocabulary. Separate DLC modules provide broad math and physics vocabulary, computing terms, and the complete Tang poetry, Song poetry and Song ci collections in the pinned source snapshot, together with companion anthologies.

A fresh Stellae profile defaults to SC output, five horizontal Chinese candidates and six vertical English candidates. Existing user learning and customization remain part of the normal profile workflow. The Stellae frontend provides a blue En status icon for English mode. Both Shift keys switch Chinese and English within the Chinese scheme; red A retains the frontend native input state.

## Installation

- [Stellae frontend and scheme installer](https://github.com/unknownnumbers/rime-stellae/releases).
- [Official Weasel scheme ZIP](https://github.com/unknownnumbers/rime-stellae/releases/latest).
- [Stellae profile guide](docs/PC.md), [official profile installation and merging](docs/official-weasel.md), and [DLC sources](docs/dlc-sources.md).

The common maintained source is [config/pc](config/pc). [config/official-weasel](config/official-weasel) is generated from it with explicit engine capability settings. After editing the common source, run `python scripts/rebuild_profiles.py --refresh-official` and verify the result with `--check`. Back up matching configuration files before merging into an existing user directory, and retain user dictionaries.

The 2026.11.14.2 poetry DLC requires scheme base 2026.11.14.2 or later. Catalogs are generated from the repository's fixed source inputs and build scripts; module ZIPs are available in Releases. Readings and text variants use automated processing with bounded checks and have not been reviewed line by line. See [DLC sources and limitations](docs/dlc-sources.md).

Math, physics and computing DLCs include prebuilt English spelling correction indexes. Update older modules before redeploying.

## Development and planned work

[Build](docs/BUILD.md) | [Sources and reconstruction scope](docs/sources/README.md) | [TODO](TODO.md)

Original code and configuration use GPL-3.0-only. Original explanatory prose uses CC BY-SA 4.0. Third-party data and notices retain their own terms; see the [license index](THIRD_PARTY_NOTICES.md).
