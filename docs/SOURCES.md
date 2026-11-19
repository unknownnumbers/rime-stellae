# Corresponding sources

The frontend remains `0.17.4.61052`. The original frontend installer and complete corresponding source archive are pinned by `installer/bundle-inputs.json`, using the retained `v0.17.4.61052` release.

The integrated package adds the fixed RymCp source profile from commit `9e973a23b0e23726135b20827de8dba2b789d708`, using the scheme archive and SHA256 recorded in `installer/bundle-inputs.json`. Scheme sources and their original notices are at [RymCp](https://github.com/unknownnumbers/RymCp-IME/tree/9e973a23b0e23726135b20827de8dba2b789d708).

The integrated source archive includes the frontend base source archive, current bundle-project source, the exact scheme source archive and the input manifest. Native upstream versions, patches, assets and hashes are recorded in `native/source-manifest.json`.

The x64 and Win32 TSF, IME and server images are built from the current frontend patch. The runtime engines and remaining native installer images retain their pinned hashes. Scheme version and package version are recorded separately from the frontend version. Original notices are retained in `licenses/` and the payload license index.

[Build](BUILD.md) | [License summary](../THIRD_PARTY_NOTICES.md)
