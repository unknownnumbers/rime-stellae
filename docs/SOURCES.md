# Source inventory

The [native source manifest](../native/source-manifest.json) fixes the frontend, engine, plugin and dependency inputs. Complete project patches, build scripts, tests and installer sources are included in this repository. Release packages include a source archive and a manifest connecting the installer to its source and build inputs.

## Frontend and engines

| Component | Fixed source |
| --- | --- |
| Official Weasel base | [rime/weasel, 9cc96e20dc71b80876b12f689bb5863c76c2a7ed](https://github.com/rime/weasel/tree/9cc96e20dc71b80876b12f689bb5863c76c2a7ed) |
| librime | [1c23358157934bd6e6d6981f0c0164f05393b497](https://github.com/rime/librime/tree/1c23358157934bd6e6d6981f0c0164f05393b497) |
| librime-lua | [e3912a4b3ac2c202d89face3fef3d41eb1d7fcd6](https://github.com/hchunhui/librime-lua/tree/e3912a4b3ac2c202d89face3fef3d41eb1d7fcd6) |
| Bundled Lua source | [115e000c878d1170337f7ca934d7a84f68986e39](https://github.com/hchunhui/librime-lua/tree/115e000c878d1170337f7ca934d7a84f68986e39) |
| librime-octagram | [dfcc15115788c828d9dd7b4bff68067d3ce2ffb8](https://github.com/lotem/librime-octagram/tree/dfcc15115788c828d9dd7b4bff68067d3ce2ffb8) |
| librime-predict | [920bd41ebf6f9bf6855d14fbe80212e54e749791](https://github.com/rime/librime-predict/tree/920bd41ebf6f9bf6855d14fbe80212e54e749791) |
| Manual package installer | [rime/plum, cab9ed35289f2022b6888503750d2dfb1851dbe0](https://github.com/rime/plum/tree/cab9ed35289f2022b6888503750d2dfb1851dbe0) |

The frontend patch contains the adopted source changes through 0.17.4.61052. Installer sources are applied separately from the frontend source baseline. Both source layers and the icon assets accompany the corresponding source bundle.

N01 x64 adds native matching-code support and the step-only Lua GC policy to the retained engine changes. R5 provides the Win32 runtime and frontend build SDK. These variants retain their respective engine patches, preedit handling and Lua changes. Their plugins are built into `rime.dll`; there are no separate plugin DLLs in this package.

The Windows registration uses the existing source-defined identifiers `0C04` and `0804`, with the independent Stellae CLSID and profile GUID. These identifiers are Windows API values. They are separate from interface language and schema output settings.

## Shared package resources

The packaging script downloads the fixed [official Weasel0.17.4 installer](https://github.com/rime/weasel/releases/download/0.17.4/weasel-0.17.4.0-installer.exe), verifies the pinned hash and extracts an explicit allowlist. Per-file hashes are recorded in the generated package manifest.

- `data/weasel.yaml` and `data/preview/` supply frontend appearance and color previews. Original color scheme authors remain credited in the YAML and upstream notices.
- `data/key_bindings.yaml`, `data/punctuation.yaml` and `data/symbols.yaml` are shared rime-prelude resources under LGPLv3. Their distributed source form is preserved. The [original license](https://github.com/rime/rime-prelude/blob/95542a274915ba5496ff3260a2c71946238d4cce/LICENSE) is retained. The historical prelude commit packaged by Weasel is not asserted.
- `data/opencc/` contains standard OpenCC resources under Apache-2.0. The distribution and per-file hashes pin the consumed data; they do not establish its historical OpenCC data commit.
- The project's `default.yaml` has an empty `schema_list` and no switcher hotkeys. Scheme dictionaries, language models, essay data and product Lua are outside this package.

## Manual installation utilities

| Tool or resource | Distributed version and source |
| --- | --- |
| curl | 8.7.1_9-win32-mingw, retained from the fixed Weasel source; [upstream adoption](https://github.com/rime/weasel/commit/95fd506ad97fec167ab7f431552c3417ffaa90f0), [curl8.7.1 source](https://github.com/curl/curl/archive/refs/tags/curl-8_7_1.tar.gz) |
| curl-for-win build inputs | [revision9 source snapshot](https://github.com/curl/curl-for-win/tree/ef1b80f30fbb5b3854f25ce0b3cf2d15de60ee53), including the pinned dependency versions |
| 7-Zip | 24.05, [complete upstream source archive](https://github.com/ip7z/7zip/releases/download/24.05/7z2405-src.tar.xz) |
| NSIS | 3.11, [source archive](https://github.com/NSIS-Dev/nsis/archive/refs/tags/v311.tar.gz), [license and linking exception](https://github.com/NSIS-Dev/nsis/blob/v311/COPYING) |
| Mozilla CA data | Public CA bundle dated2024-03-11, retained from the fixed Weasel source; [conversion and source information](https://curl.se/docs/caextract.html) |

The original curl binary is identified by its Weasel Git blob. The revision9 build source records LibreSSL3.9.2, zlib1.3.1, Brotli1.1.0, Zstandard1.5.6, libpsl0.21.5, libssh2 1.11.0, nghttp2 1.62.0, nghttp3 1.3.0 and ngtcp2 1.5.0. The corresponding original license texts are retained in [curl-dependencies](../licenses/package/curl-dependencies/). This inventory does not assert a byte-identical rebuild of that upstream curl executable.

The public suffix data source used by the fixed libpsl release is available in the [libpsl0.21.5 source archive](https://github.com/rockdaboot/libpsl/releases/download/0.21.5/libpsl-0.21.5.tar.gz). Its MPL2 notice and the Chromium DAFSA code notice are retained. The CA bundle keeps its original source header.

`rime-install.bat` is retained from the fixed plum source. `rime-install-config.bat` directs the tool to Stellae's user directory. These tools download only when explicitly invoked by the user.

## Source downloads accompanying binaries

The [release page](https://github.com/unknownnumbers/rime-stellae/releases) provides the installer and corresponding source archive together, with hashes and build records. The source archive contains the assembled Stellae source, engine and plugin sources, project build/packaging scripts, tests and retained notices. Pinned dependencies and their source locations are recorded by the native source manifest and original notice records.

The unmodified `7z2405-src.tar.xz` is also provided as a source download alongside the installer. Its SHA256 is `63f341cf80b8d287c6e945519b3da0fa75553c85572a471b7fa6e68f9a90b790`. 7-Zip's original LGPL, BSD and unRAR-restriction notices remain in effect.

License and attribution snapshots are independently identified by URL, bytes, SHA256 and Git blob hash in [third-party-source-manifest.json](../licenses/third-party-source-manifest.json). Source archives and source patches have distinct roles: the complete archives provide buildable source trees, while patches identify the project's changes to the pinned upstreams.
