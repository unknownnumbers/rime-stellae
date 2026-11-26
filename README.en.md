# Rime Stellae

> This project is created through human-AI collaboration. Some AI-proposed content may not yet have been reviewed by a human. Please excuse any errors or omissions.

[English (en)](README.en.md) | [Traditional Chinese (zh-TC)](README.md) | [Simplified Chinese (zh-SC)](README.zh-SC.md)

Stellae provides a Windows Rime frontend and input schemes. The frontend handles TSF input, the candidate interface, scheme deployment and configuration; the schemes support Chinese, English, Japanese and character lookup. Install the frontend with the complete scheme, or use the standalone scheme ZIP with official Weasel. Optional DLC modules add math, physics, computing and poetry vocabulary.

## Installation and use

- [Stellae frontend and complete scheme installer](https://github.com/unknownnumbers/rime-stellae/releases/download/v2026.11.27.3/stellae-2026.11.27.3-installer.exe).
- [Complete Stellae scheme ZIP](https://github.com/unknownnumbers/rime-stellae/releases/download/v2026.11.27.3/stellae-2026.11.27.1-schemes.zip), for an existing Stellae installation.
- [Official Weasel scheme ZIP](https://github.com/unknownnumbers/rime-stellae/releases/download/v2026.11.27.3/stellae-2026.11.27.3-official-weasel-schemes.zip), with [installation and merge instructions](schemes/docs/official-weasel.md).
- Supports 64-bit Windows, with compatibility clients for 32-bit applications.
- The frontend is version `0.17.4.61052`. The installer is version `2026.11.27.3` and includes the `2026.11.27.1` base scheme.
- A fresh profile defaults to SC output, five horizontal Chinese candidates and six vertical English candidates, with TC/SC switching.
- The installer includes the Noto Sans CJK Regular collection. The SC or TC selection sets the initial candidate font. Use Stellae's appearance settings to switch among TC, HK and SC. Upgrades retain your font choice. [Candidate font guide](docs/PC.md#候選窗字體)
- The bundled scheme uses a blue En status icon for English mode.
- `Ctrl+Space` cancels the pending draft and switches between red A and the preceding Chinese or English mode. The integrated installer can add the English spelling correction index to an existing older math DLC.
- Stellae appearance overrides use `stellae.custom.yaml`; official Weasel keeps `weasel.custom.yaml`. The installer migrates the previous Stellae file without rewriting its contents. Merge differing old and new files before upgrading.
- Upgrades preserve user customization and learning. Check and merge conflicting custom files using the [user guide](docs/PC.md).

[Complete scheme features](schemes/docs/PC.md) | [Optional vocabulary and DLC](schemes/docs/dlc-sources.md) | [Build](docs/BUILD.md) | [Sources](docs/SOURCES.md) | [TODO](TODO.md)

Frontend, complete scheme and official Weasel profile sources are maintained in this repository. The common scheme source is `schemes/config/pc`; the official profile is derived from it. ARM64, physical-keyboard acceptance and complete Windows-host coverage remain subject to the recorded validation scope.

Original code, configuration, tests and assets use GPL-3.0-only. Original explanatory prose uses CC BY-SA 4.0. Third-party components retain their original licenses and notices; see [sources and licensing](THIRD_PARTY_NOTICES.md).
