# Build

Frontend, engines and input schemes are maintained in this repository. Fixed public upstream sources, patches and SDK inputs are recorded in `native/source-manifest.json`. Common scheme inputs are in `schemes/config/pc`, with the official Weasel profile generated from the same source. Product defaults are grouped under `stellae/`, Lua logic under language and function directories, and generated Lua indexes under `lua/data/`. See [source layout and migration](../schemes/docs/STRUCTURE.md). Run the following source checks from the repository root with Python 3.12 and PowerShell 7.2 or newer:

```powershell
python -m pip install PyYAML==6.0.2
python licenses/build_index.py --check
python scripts/verify_release.py --require-yaml
python -m unittest discover -s native/tests/package -p 'test_*.py'
./scripts/native/Test-Inventory.ps1
```

The integrated package recipe is `scripts/package/Build-Bundle.ps1`. It runs on a disposable Windows CI runner, verifies `installer/bundle-inputs.json`, extracts the pinned frontend and shared resources, builds the complete Stellae scheme from `schemes/`, indexes the actual payload and builds the NSIS installer. The same scheme source also produces the standalone Stellae and official Weasel ZIPs. See the [scheme build guide](../schemes/docs/BUILD.md) for profile derivation, public data and optional DLC.

Run `.github/workflows/bundle.yml` through its `workflow_dispatch` entry to build the integrated installer. The default package requires x64 Windows and has one x64 N01 engine, one server and one deployer. Both x64 and x86 TSF/IME clients connect to that service; the x86 DLL and IME support 32-bit applications. The x86 setup and bundled utility programs are also retained where required. The package contains no independent Win32 server, deployer or engine.

The workflow uses pinned librime C API headers and published engine export tables. `installer/bundle-inputs.json` declares `nativeEngines.x64` and `nativeFrontend.clientOnlyArchitectures`. Source preparation, binary staging, provenance checks, NSIS input selection and final installer extraction all check the same architecture roles. The x64 N01 runtime uses full garbage collection when a Lua translation is released.

For the version recorded in `installer/bundle-inputs.json`, the release contains `stellae-VERSION-installer.exe`, `stellae-VERSION-source.zip`, `stellae-VERSION-schemes.zip` and `stellae-VERSION-official-weasel-schemes.zip`. The source archive includes the frontend patch, original frontend sources, assembled engine sources, scheme sources and fixed input records.

Validation checks both client architectures, source and image hashes, the extracted installer, fresh installation, installed-profile readiness and upgrades. A controlled 32-bit COM host exercises TSF callbacks and real IPC against the single x64 N01 service. Installed-profile tests exercise that engine. Upgrade checks cover synthetic learning, custom configuration, DLC and the former flat source layout. The appearance test checks that the rendered font changes while the same draft and session remain active. `native/tests/installer/Test-FontInstallerE2E.ps1` additionally accepts a previous font installer for migration testing.

`scripts/native/Prepare-Sources.ps1` creates a fresh upstream checkout and applies the selected frontend or engine patches. `Build-FrontendOverlay.ps1`, `Build-Engine.ps1` and `scripts/package/Build-Bundle.ps1` are the matching build entry points used by the workflow. Their inputs and outputs belong in fresh build directories.

`Build-FrontendOverlay.ps1 -Architecture x86` builds compatibility clients by default. Historical dual-runtime validation remains available only through the opt-in `native.yml` workflow and the explicit `-LegacyDualRuntime` recipes. Those retained R5 fixtures describe earlier releases, rather than the default package.

`schemes/scripts/schemes/Prepare-ValidationEngines.ps1` prepares x64 runtimes by default. Its `-LegacyWin32` switch explicitly selects the historical Win32 fixture. The integrated workflow uses `-Source official` for official-profile validation and the freshly built N01 artifact for Stellae validation. Only runtime and shared-data members are extracted; server and deployer images are excluded from this validation input.

The installer updates shared files according to recorded ownership. `installer/migrations/source-layout.json` identifies byte-exact former public YAML/Lua copies in an existing user profile. Unchanged copies can be retired so the current shared profile supplies the new layout. Modified custom files stay in place and are reported in `scheme-status.json`. If a previous Lua entrypoint or module was modified, the previous Lua source group is retained until it is merged. Unknown files, DLC and learning databases are outside that source migration. See the [merge guide](../schemes/docs/STRUCTURE.md).

Source snapshots and pinned upstream inputs belong in the repository. Derived profiles and package archives are rebuildable outputs. Rime's `build/` directory is a runtime cache; custom files, DLC and learning databases in the user profile are personal data. Build and package scripts read explicit source inputs and fresh output directories, without importing an installed profile.

After a reviewed source change, update the file license index with `python licenses/build_index.py`, then record the source snapshot with `python scripts/verify_release.py --write-manifest --date YYYY-MM-DD`. Installer and scheme archives must be built from the same reviewed source commit.

[Source inputs](SOURCES.md) | [User guide](PC.md)



Stellae uses the frontend configuration ID `stellae`. Its base appearance file is `stellae.yaml`, and native levers reads and saves user overrides in `stellae.custom.yaml`. The official Weasel scheme adapter retains its native `weasel` ID and `weasel.custom.yaml`. Installer preflight checks the previous Stellae appearance file before replacing the frontend; migration preserves its contents and requires a manual merge when old and new files differ.


## Static appearance previews

The appearance dialog uses the upstream static PNG preview mechanism. Each of the six bundled themes has a candidate-window preview. A separate, neutral font preview compares Default (Microsoft YaHei), SC, TC and HK using the same Unicode sample. The selected font highlights its row. Theme and font previews update independently; browsing does not deploy a scheme.

To regenerate these assets on Windows, use Pillow 13.0.0, the pinned Noto Sans CJK 2.004 Regular collection, and Microsoft YaHei from Windows:

```powershell
python scripts/fonts/Generate-ThemePreview.py --theme schemes/config/pc/stellae/appearance.yaml --collection PATH_TO_NotoSansCJK-Regular.ttc --default-font C:/Windows/Fonts/msyh.ttc --output-directory schemes/config/pc/preview
```

The generator checks the collection hash and each face name. Only the rendered PNG files are included in the scheme.
