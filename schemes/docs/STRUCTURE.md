# Scheme structure

The two profiles use one maintained implementation. `config/pc` supplies the common sources; `scripts/rebuild_profiles.py` derives the official Weasel profile through explicit frontend capability adapters. Files in `config/official-weasel` are generated from that source.

## Configuration

| Location | Responsibility |
| --- | --- |
| `default.yaml` and `stellae/defaults.yaml` | Scheme selection, shared keys and default switches |
| `cn_stellae.schema.yaml` | Chinese pipeline assembly and optional vocabulary modules |
| `jp_stellae.schema.yaml` | Japanese pipeline assembly |
| `stellae/chinese.yaml` | Chinese lookup, matching and learning settings |
| `stellae/english.yaml` | English lookup and learning settings |
| `stellae/japanese.yaml` | Kana, kanji lookup and learning settings |
| `stellae/tools.yaml` | Character lookup, calculator and Unicode tools |
| `stellae/appearance.yaml` | Candidate layout, themes and font defaults |
| `stellae/spelling.yaml` | Ordered spelling algebra maintained as an explicit input |
| `*.custom.yaml` | Personal overrides applied after product defaults |

Composition uses Rime's native [`__include` and `__patch` directives](https://github.com/rime/home/wiki/Configuration). Chinese and Japanese personal overrides are last in their schema patch lists. The shared default configuration also applies `default.custom` after the product defaults. The appearance sample includes the shared appearance defaults before its overrides.

Stellae reads and saves appearance overrides through `stellae.custom.yaml`. The official Weasel adapter keeps `weasel.custom.yaml` under its native configuration ID. The installer migrates the previous Stellae appearance file without rewriting its contents; differing old and new files require a merge before upgrading.

For example, replace the empty `patch: {}` in `cn_stellae.custom.yaml` with:

```yaml
patch:
  menu/page_size: 7
  menu/chinese_page_size: 7
```

Existing customized files need a merge rather than replacement. Keep personal settings, optional module folders and learning databases when upgrading. The installer recognizes unchanged files from the previous layout. It preserves modified files and reports cases requiring a manual merge. A modified old Lua entrypoint or module keeps its old dependency group available until that merge is complete.

## Lua

`rime.lua` assembles components through standard Lua `require`. Native entrypoint globals remain stable, including the compatibility name `official_translator`, which now points to the shared on-demand dispatcher.

| Directory | Responsibility |
| --- | --- |
| `lua/cn` | Chinese matching, fixed spelling and candidate combination |
| `lua/en` | English processing and indexed lookup |
| `lua/jp` | Japanese input, query modes and shared kanji learning |
| `lua/tools` | Character and Unicode lookup, calculator and query export |
| `lua/ui` | Candidate keys, mode filtering and candidate presentation |
| `lua/shared` | Mode coordination, on-demand dispatch and resource paths |
| `lua/data` | Fixed mapping tables and generated indexes |

The native engine continues to provide ordinary lookup, sentence construction and `Memory`. Lua supplies the existing fixed-spelling, correction, multilingual and tool behavior. Moving a module does not add a loader or change its candidate scoring or learning policy.

## Data and reconstruction

The spelling inventory and its reconstruction command are described in [`sources/spelling/README.md`](../sources/spelling/README.md). `scripts/data/rebuild_chinese_spelling.py --check` verifies the generated Chinese classifiers and neighbor-key table. The ordered spelling algebra remains a reviewed source input rather than an output attributed to an unavailable historical script.

Other fixed dictionary and model inputs retain their existing source records and licenses. See the [source index](sources/README.md). Optional mathematics, physics, computer and poetry data remains separate from the base profiles. Small root dictionary files are Rime import entries for those modules; the actual vocabulary stays in the module folders.

## Building and checking

After reviewing maintained source edits, refresh the source inventory and derive the official profile:

```console
python scripts/rebuild_profiles.py --refresh-source-manifest
python scripts/rebuild_profiles.py --refresh-official
python scripts/rebuild_profiles.py --check
```

Use `--scheme-version YYYY.MM.DD.N` with the inventory refresh when changing the scheme version. Refresh license coverage and release inventories as described in [BUILD.md](BUILD.md) before packaging. Personal configuration and learned data are not reconstruction inputs for the distributed profiles.

Current behavior checks use the source-derived profiles and actual engine APIs. Historical DLC catalog checks keep their implementation under `tests/schemes/fixtures/legacy_dlc`; they validate that historical format, not the current input initialization path. Native build and installer checks cover the x64 backend with compatibility clients for 32-bit applications. The complete legacy dual-runtime build remains an explicit opt-in path.
