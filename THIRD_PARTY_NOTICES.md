# Licensing and third-party notices

Original Rime Stellae code, configuration, tests, icons and modifications are licensed under [GPL-3.0-only](LICENSE). Original explanatory text is licensed under [CC BY-SA 4.0](licenses/CC-BY-SA-4.0.txt). Third-party source, assets, data and notices retain their original terms and credits.

The [source-tree license index](licenses/file-licenses.json) records the scope for each repository file. The [package source mappings](licenses/package-sources.json) are used to produce a separate license index for actual installer payload files. Each binary package carries the corresponding notices.

| Component | Original terms | Retained notices |
| --- | --- | --- |
| Weasel frontend and original resources | GNU GPLv3, Rime and original contributors | [Weasel](licenses/native-dependencies/weasel/LICENSE.txt) |
| librime | BSD-3-Clause, RIME Developers | [librime](licenses/supplement/librime-LICENSE.txt) |
| librime-lua and bundled Lua | BSD-3-Clause and Lua MIT | [librime-lua](licenses/supplement/librime-lua-LICENSE.txt), [Lua5.4](licenses/supplement/Lua-5.4-MIT-NOTICE.txt), [Lua5.3 source-tree notice](licenses/supplement/Lua-5.3-MIT-NOTICE.txt) |
| librime-octagram | GNU GPLv3 | [Octagram](licenses/supplement/librime-octagram-LICENSE.txt) |
| librime-predict | BSD-3-Clause | [Predict](licenses/supplement/librime-predict-LICENSE.txt) |
| Native build dependencies | Their respective licenses and authors | [Original notices](licenses/native-dependencies/), [fixed sources and hashes](licenses/third-party-source-manifest.json) |
| Shared key bindings, punctuation and symbols | rime-prelude, GNU LGPLv3 | [Prelude](licenses/package/prelude-LICENSE.txt) |
| OpenCC resources | Apache-2.0 and original authors | [OpenCC license](licenses/OpenCC-LICENSE.txt), [authors](licenses/native-dependencies/opencc/AUTHORS) |
| Manual package installer | plum, GNU LGPLv3 | [plum](licenses/package/plum-LICENSE.txt) |
| curl and its statically linked dependencies | curl, LibreSSL/OpenSSL/SSLeay/ISC, MIT, BSD, zlib and MPL2 source-specific terms | [curl](licenses/package/curl-COPYING.txt), [dependency notices](licenses/package/curl-dependencies/) |
| Mozilla-derived CA and public suffix data | MPL-2.0 and retained source notices | [MPL2](licenses/package/MPL-2.0.txt), [CA source header](licenses/package/ca-bundle-SOURCE-NOTICE.txt), [suffix source header](licenses/package/curl-dependencies/public-suffix-SOURCE-NOTICE.txt) |
| 7-Zip24.05 tools | LGPL-2.1-or-later, BSD portions and the unRAR restriction | [Original composite notice](licenses/package/7zip-LICENSE.txt), [LGPL2.1](licenses/package/LGPL-2.1.txt) |
| NSIS3.11 installer runtime and compression modules | zlib/libpng, bzip2 and CPL1.0 with the upstream LZMA linking exception | [NSIS](licenses/package/NSIS-COPYING.txt) |

This product includes software developed by the OpenSSL Project for use in the OpenSSL Toolkit. (http://www.openssl.org/)

Original frontend artwork and color scheme credits remain in the upstream resources. The star core product icon is an original project asset. The build selects in-tree Lua5.4; retaining the Lua5.3 source-tree notice does not mean both versions are linked.

Source downloads, exact package inputs and reconstruction limits are recorded in [SOURCES.md](docs/SOURCES.md). Binary releases provide source archives and directions alongside the installer. Source or generator licensing does not replace the terms of underlying third-party data.
