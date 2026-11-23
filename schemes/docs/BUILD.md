# Build

Use Python 3.12. The common maintained scheme source is `config/pc`; `config/official-weasel` is a generated profile. Edit shared Lua, data and defaults only in `config/pc`. `config/profiles.json` records engine capability differences.

## Maintain and derive profiles

`config/pc/config-source-manifest.json` explicitly lists the common inputs. After changing a listed file, update its byte count and SHA-256. Add a new file only after its source and license have been recorded. `config/pc/source-dependencies.json` pins the shared prelude and OpenCC resources separately.

```sh
python scripts/rebuild_profiles.py --refresh-official
python scripts/rebuild_profiles.py --check
```

The refresh command updates the official profile from the common input manifest. It retains the official global configuration, Lua entrypoint and appearance files under `samples/` for manual merging. Unexpected files in the derived directory require review. It never rewrites the common PC inputs.

Stellae uses native matched-syllable information and dynamic Chinese/English page sizes. Official Weasel uses its native completion adapter and six vertical, non-inline candidates. Both profiles share spelling, lookup, Japanese and learning modules. Both PC Shift keys use the shared En coordinator. Stellae defines Ctrl+Space once in its default preset; its frontend cancels composition after the mode action. Official Weasel retains client ownership of Ctrl+Space. Japanese keeps its independent Shift rules.

For fresh isolated deployment, choose absent output directories:

```sh
python scripts/rebuild_profiles.py --output out/profiles --prepare-official out/official-fresh
```

The output includes `config/pc`, `config/official-weasel` and provenance manifests. Optional DLC payloads and personal data are not part of the base profiles.

## Rebuild public data

Run `python scripts/data/rebuild_base.py` to reproduce the base dictionaries and English indexes from the committed fixed inputs, then refresh the official derivation. See [base dictionary sources](sources/base-dictionaries.md).

Run `python scripts/build_dlc.py` to generate optional catalogs offline from the locked public snapshots and pinned reading dependencies. Expanded modules are written to `out/dlc/modules/rymcp_dlc/` and ZIPs to `out/dlc/`. These are generated outputs. Fixed input archives under `dlc/sources/` are source materials. See [DLC sources](dlc-sources.md).

## Validate

```sh
python scripts/rebuild_profiles.py --check
python config/pc/tools/validate-japanese-base.py --directory config/pc
python scripts/data/rebuild_japanese_family_q.py --check
python -m unittest discover -s tests/data -p "test_*.py"
python scripts/verify_release.py --require-yaml
```

Install PyYAML 6.0.2 for the YAML checks. `tests/rebuilt-profile/Test-RebuiltProfile.ps1` and adjacent `RimeProbe.cs` verify empty-workspace native deployment, mode contracts, spelling markers, completion, tools, editing, Japanese and synthetic learning. Use a separate Windows PowerShell 5.1 or PowerShell 7 process per engine, with matching process architecture:

```powershell
pwsh -NoProfile -File tests/rebuilt-profile/Test-RebuiltProfile.ps1 -Kind pc -GeneratedProfile out/profiles/config/pc -EnginePath ENGINE_DIR/rime.dll -OutputPath out/proofs/pc
pwsh -NoProfile -File tests/rebuilt-profile/Test-RebuiltProfile.ps1 -Kind official-weasel -GeneratedProfile out/official-fresh -EnginePath OFFICIAL_ENGINE_DIR/rime.dll -OutputPath out/proofs/official-weasel
```

The runner writes native binaries and fixed synthetic learning only inside the supplied fresh output profile. Engine-only tests do not replace frontend Ctrl+Space, display or physical-key acceptance. Current native regression coverage targets Stellae N01 x64 and official Weasel x64. On 32-bit Windows, Chinese whole-word completion is limited by the missing matched-syllable metadata.

Build the DLC catalogs before running `scripts/schemes/Test-DlcRuntime.ps1` with the matching engine and a fresh `-WorkRoot`. It validates the distributed tables and a bounded synthetic install, update and removal lifecycle. Native table readback uses the test-only `marisa-trie==1.3.1` binding pinned in [scheme validation workflow](../../.github/workflows/schemes.yml).

## Package

Refresh `licenses/file-licenses.json` with `python licenses/build_index.py`, then record the reviewed source snapshot with `python scripts/verify_release.py --write-manifest --require-yaml`. Run the verifier again without `--write-manifest` before packaging.

```sh
python scripts/build_scheme_packages.py --profile all --version 2026.11.24 --source-ref FULL_COMMIT_SHA --output-dir out/schemes
```

The source ref must identify the reviewed rime-stellae commit. Run this command from the schemes directory. Archives are named `stellae-VERSION-schemes.zip` and `stellae-VERSION-official-weasel-schemes.zip`. Both ZIPs include per-file license records and pinned source provenance. The latest Stellae frontend source and installer build are maintained in [rime-stellae](https://github.com/unknownnumbers/rime-stellae). The retained [native recipes](../native/BUILD.md) document earlier native source inputs. Source preparation, native compilation, runtime checks, installer validation and physical-host acceptance remain separate results.
