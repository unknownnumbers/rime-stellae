# Corresponding sources

The frontend remains `0.17.4.61052`. The original frontend installer and complete corresponding source archive are pinned by `installer/bundle-inputs.json`, using the retained `v0.17.4.61052` release.

The integrated package adds the fixed RymCp source profile using the commit, archive URL and SHA256 recorded in `installer/bundle-inputs.json`. Scheme sources and their original notices are at [RymCp](https://github.com/unknownnumbers/RymCp-IME).

The integrated source archive includes the frontend base source archive, current bundle-project source, both assembled runtime source archives, the exact scheme source archive and the input manifest. Native upstream versions, patches, assets and hashes are recorded in `native/source-manifest.json`.

The x64 and Win32 TSF, IME and server images are built from the current frontend patch. The installed N01 x64 and R5 Win32 engines are rebuilt from the pinned runtime sources. Scheme version and package version are recorded separately from the frontend version. Original notices are retained in `licenses/` and the payload license index.

[Build](BUILD.md) | [License summary](../THIRD_PARTY_NOTICES.md)
