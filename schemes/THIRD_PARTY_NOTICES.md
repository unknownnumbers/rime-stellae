# Sources and licenses

Original program code, configuration, generators, tests and original mapping expressions are GPL-3.0-only within the contributors' rights. Original explanatory prose is CC BY-SA 4.0. Third-party works retain their own licenses and attribution.

The machine-readable [file index](licenses/file-licenses.json) covers every source file. [Original notice records](licenses/third-party-source-manifest.json) pin retained notices by their original bytes and hashes.

- Chinese Luna and essay data: original Rime authors and component notices, including LGPL-3.0. See [base sources](docs/sources/base-dictionaries.md).
- Compact model: fixed upstream release and original LGPL-3.0 notice. See [model sources](docs/sources/luna-compact-model-sources.md).
- English frequency data: SymSpell with its Google Books Ngram and SCOWL component notices. See [English sources](docs/sources/english-core-sources.md).
- English forms: fixed Ice source under GPL-3.0, and SCOWL case evidence under its original composite terms. See [forms](docs/sources/english-extensions-sources.md).
- Japanese data: JMdict, KANJIDIC2, Unihan and the separately documented grammar and reference sources. See [q](docs/sources/jp-q-sources.md) and [v](docs/sources/jp-v-sources.md).
- Radical, stroke, Unicode and OpenCC resources retain their original notices. See the [source index](docs/sources/README.md).
- Optional vocabulary modules retain their declared data licenses. See [DLC sources](docs/dlc-sources.md).
- Native frontend and engine sources retain upstream licensing and complete patches. See [native components](docs/sources/native-components.md).

Generator licensing does not replace the licensing of source data or generated data. Fixed source conversion and original corpus reconstruction are different scopes, recorded in the source documentation.

## Optional vocabulary sources

The complete Tang poem, Song poem and Song ci snapshots and companion anthologies retain the original chinese-poetry MIT notice. Generated catalogs and reading annotations use CC BY-SA 4.0.

The build-time reading inputs are pypinyin 0.55.0 under MIT, fixed OpenCC dictionaries under Apache-2.0, and Unicode Unihan 17.0.0 under Unicode-3.0. Original notices and checksums accompany the source snapshots.

The mathematics and physics modules combine CC-CEDICT with broad public subject classifications from Wikipedia contributors under CC BY-SA 4.0 and labels and aliases from Wikidata contributors under CC0. Exact source revisions and original API responses are retained. Article bodies are not included.

The optional native-table validation dependency marisa-trie is used in CI and is not bundled with the input method. Its Python wrapper uses MIT and its bundled libmarisa retains its original BSD 2-clause/LGPL terms.
