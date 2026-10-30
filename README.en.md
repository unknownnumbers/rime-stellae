# Rime Stellae / 墨芯

[English (en)](README.en.md) | [Traditional Chinese (zh-TC)](README.md) | [Simplified Chinese (zh-SC)](README.zh-SC.md)

> This project is created through human-AI collaboration. Some AI-proposed content may not yet have been reviewed by a human. Please excuse any errors or omissions.

Rime Stellae is a Windows Rime frontend based on Weasel. This repository provides the source, build entry points, tests and installer for 0.17.4.61052. It can coexist with official Weasel.

## Features

- Separate product identity, program directory, service and user data directory.
- Native changes to TSF key pairing, candidate UI, text commits and focus handling.
- Event markers identify synthetic Caps events. Temporary numeric diagnostics are disabled in release builds.
- Installation and upgrades preserve existing input methods, the selected registration and user data.
- Color selection, deployment, dictionary management and tools for manually installing Rime schemas.

## Install and use

Download the installer from [GitHub Releases](https://github.com/unknownnumbers/rime-stellae/releases). No input schemas or dictionaries are preinstalled; add a schema and redeploy after installation.

The default user data directory is `%APPDATA%\RimeStellae`. The notification area menu provides access to the user folder, schema installation and redeployment. See the [user guide](docs/PC.md).

| Component | Published content |
| --- | --- |
| Frontend | TSF, Server, Deployer, Setup and classic IME 0.17.4.61052 |
| Architectures | x64 and Win32 |
| x64 engine | N01, step-only Lua GC |
| Win32 engine | R5 |
| Shared resources | Frontend appearance and color previews, an empty schema list, standard OpenCC, key binding and punctuation resources |

The engines are pinned separately for each architecture. See the [build guide](docs/BUILD.md) and [source inventory](docs/SOURCES.md). Current public validation primarily uses Windows hosted CI. ARM64 is outside the current release scope. Historical classic IME upgrade paths and focus switching or occasional first-key behavior in some host applications need further validation.

## Development and TODO

Source and binary packages include source inventories and third-party notices. See the [build guide](docs/BUILD.md) and [TODO](TODO.md). An automatic update feed has not been configured.

## Licensing and acknowledgments

Original project code, configuration, tests, icons and modifications use [GPL-3.0-only](LICENSE). Original explanatory text uses [CC BY-SA 4.0](licenses/CC-BY-SA-4.0.txt). Third-party portions retain their own terms and credits; see [licensing and sources](THIRD_PARTY_NOTICES.md).

Thanks to [Rime](https://github.com/rime), [Weasel](https://github.com/rime/weasel) and their contributors, and the authors of the engine, plugins and build dependencies.
