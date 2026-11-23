# Corresponding sources

The frontend remains `0.17.4.61052`. The original frontend installer and complete corresponding source archive are pinned by `installer/bundle-inputs.json`, using the retained `v0.17.4.61052` release as fixed build inputs.

Current frontend, complete Stellae scheme and official Weasel profile sources are maintained in this repository. Common scheme inputs are in `schemes/config/pc`; `schemes/config/official-weasel` is derived from them. The scheme source records and original third-party notices are retained under [scheme sources](../schemes/docs/sources/README.md) and `schemes/licenses/`.

The integrated source archive includes the frontend base source archive, current project source, both assembled runtime source archives, exact scheme sources and the input manifest. Native upstream versions, patches, assets and hashes are recorded in `native/source-manifest.json`. Scheme dictionaries, models and optional vocabulary retain their pinned source records under `schemes/sources/`, `schemes/config/pc/` and `schemes/dlc/`.

The x64 and Win32 TSF, IME and server images are built from the current frontend patch. The installed N01 x64 and R5 Win32 engines are rebuilt from the pinned runtime sources. Scheme version and package version are recorded separately from the frontend version. Original notices are retained in `licenses/`, `schemes/licenses/` and the payload license index.

[Build](BUILD.md) | [License summary](../THIRD_PARTY_NOTICES.md)
