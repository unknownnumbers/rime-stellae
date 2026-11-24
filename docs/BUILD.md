# Build

Frontend, engines and input schemes are maintained in this repository. Fixed public upstream sources, patches and SDK inputs are recorded in `native/source-manifest.json`. Common scheme inputs are in `schemes/config/pc`, with the official Weasel profile generated from the same source. Run the following source checks from the repository root with Python 3.12 and PowerShell 7.2 or newer:

```powershell
python -m pip install PyYAML==6.0.2
python licenses/build_index.py --check
python scripts/verify_release.py --require-yaml
python -m unittest discover -s native/tests/package -p 'test_*.py'
./scripts/native/Test-Inventory.ps1
```

The integrated package recipe is `scripts/package/Build-Bundle.ps1`. It runs on a disposable Windows CI runner, verifies `installer/bundle-inputs.json`, extracts the pinned frontend and shared resources, builds the complete Stellae scheme from `schemes/`, indexes the actual payload and builds the NSIS installer. The same scheme source also produces the standalone Stellae and official Weasel ZIPs. See the [scheme build guide](../schemes/docs/BUILD.md) for profile derivation, public data and optional DLC.

Run `.github/workflows/bundle.yml` through its `workflow_dispatch` entry to build the integrated installer. The workflow rebuilds TSF, legacy IME, the server and the deployer for x64 and Win32 from the complete frontend patch. It uses pinned librime C API headers and published engine export tables. It also builds the N01 x64 and R5 Win32 runtimes in the same run and verifies their hashes and architectures in the finished installer. Both runtimes use full garbage collection when a Lua translation is released.

For version `2026.11.24.1`, the release contains `stellae-2026.11.24.1-installer.exe`, `stellae-2026.11.24.1-source.zip`, `stellae-2026.11.24.1-schemes.zip` and `stellae-2026.11.24.1-official-weasel-schemes.zip`. The source archive includes the frontend patch, original frontend sources, assembled engine sources, scheme sources and fixed input records.

Validation checks both frontend architectures, source and image hashes, the extracted installer, fresh installation, installed-profile readiness and upgrades. The installed-profile tests exercise the bundled N01 and R5 runtimes. Upgrade checks cover preservation of synthetic learning and custom configuration. The appearance test checks that the rendered font changes while the same draft and session remain active. `native/tests/installer/Test-FontInstallerE2E.ps1` additionally accepts a previous font installer for migration testing.

`scripts/native/Prepare-Sources.ps1` creates a fresh upstream checkout and applies the selected frontend or engine patches. `Build-FrontendOverlay.ps1`, `Build-Engine.ps1` and `scripts/package/Build-Bundle.ps1` are the matching build entry points used by the workflow. Their inputs and outputs belong in fresh build directories.

After a reviewed source change, update the file license index with `python licenses/build_index.py`, then record the source snapshot with `python scripts/verify_release.py --write-manifest --date YYYY-MM-DD`. Installer and scheme archives must be built from the same reviewed source commit.

[Source inputs](SOURCES.md) | [User guide](PC.md)


## Static font previews

The appearance dialog uses the upstream static PNG preview mechanism. The project theme includes Default, SC, TC and HK comparison images with the same Unicode sample. The selected font highlights its row; browsing images does not deploy a scheme.

To regenerate these assets on Windows, use Pillow 13.0.0, the pinned Noto Sans CJK 2.004 Regular collection, and Microsoft YaHei from Windows:

```powershell
python scripts/fonts/Generate-ThemePreview.py --theme schemes/config/pc/weasel.custom.yaml --collection PATH_TO_NotoSansCJK-Regular.ttc --default-font C:/Windows/Fonts/msyh.ttc --output-file schemes/config/pc/preview/color_scheme_reference_gray.png
```

The generator checks the collection hash and each face name. Only the rendered PNG files are included in the scheme.
