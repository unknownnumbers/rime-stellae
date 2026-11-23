# Official Weasel profile sources

`config/official-weasel` is generated from `config/pc` and `config/profiles.json`, adapting the shared Chinese, English and Japanese sources to official Weasel 0.17.4 and its x64 librime 1.13.1 runtime.

The profile retains character lookup, fixed mixed phrases and native word completion. The profile retains existing Chinese spelling, correction, composition and native learning, and the English recall index, completion, case handling and native word learning. Candidate layout and installation samples use the official frontend interfaces.

The general dictionaries and reproducible data generation are documented in [base sources](base-dictionaries.md). [English forms](english-extensions-sources.md), [case evidence](english-case-forms-sources.md), [compact model](luna-compact-model-sources.md) and [OpenCC resources](shared-config-sources.md) retain their component notices. Optional vocabulary uses the shared [DLC source recipe](../dlc-sources.md).

Original adaptation code is GPL-3.0-only. Character lookup uses the [component dictionaries and upstream stroke data](radical-stroke-sources.md) plus [Unihan readings](u-readings-sources.md). Unicode input and calculation retain their [upstream attribution](tools-sources.md). `profile-manifest.json` records supplied profile files and source hashes. The tests use fresh synthetic directories and fixed inputs; see [Build](../BUILD.md).
