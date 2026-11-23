# 原生前端/引擎: 固定來源與授權

本頁保存 61047 組合的固定來源. 配套墨芯 61052 的完整來源、通知及構建入口見 [Rime Stellae](https://github.com/unknownnumbers/rime-stellae).

前端來源固定[rime/weasel@9cc96e20dc71b80876b12f689bb5863c76c2a7ed](https://github.com/rime/weasel/tree/9cc96e20dc71b80876b12f689bb5863c76c2a7ed), 保留[GPLv3](../../LICENSE) 與原檔署名. 本工程在此基底上的實際patch及可執行構建流程見[原生BUILD](../../native/BUILD.md); 舊版manifest不代替目前patch鏈.

本工程原生修改、構建腳本及測試的原創部分採GPL-3.0-only. 補丁中的上游原文與上下文保留原授權及署名, 包括librime、librime-lua與librime-predict的BSD-3-Clause條款. 各部分的範圍見[逐檔授權索引](../../licenses/file-licenses.json).

此 61047 組合的 Weasel 來源分為 `weasel-61047` 的 x86/x64 TSF、`weasel-server-61042` 的 x64 Server 及 `weasel-61020` 的 x86/x64 IME. 三份完整補丁各自套在上述固定官方提交, 不依序疊加. 引擎另分為 N01 x64 執行時來源與 R5 x64/x86 前端構建 SDK; 詳細 patch、架構及產物清單見[原生來源 manifest](../../native/source-manifest.json).

| 元件 | 固定commit | 保留通知 |
| --- | --- | --- |
| [librime](https://github.com/rime/librime/tree/1c23358157934bd6e6d6981f0c0164f05393b497) | `1c23358157934bd6e6d6981f0c0164f05393b497` | [BSD-3-Clause, ©2014 RIME Developers](../../licenses/supplement/librime-LICENSE.txt) |
| [librime-lua](https://github.com/hchunhui/librime-lua/tree/e3912a4b3ac2c202d89face3fef3d41eb1d7fcd6) | `e3912a4b3ac2c202d89face3fef3d41eb1d7fcd6` | [BSD-3-Clause, ©2021 librime-lua Developers](../../licenses/supplement/librime-lua-LICENSE.txt) |
| [librime-octagram](https://github.com/lotem/librime-octagram/tree/dfcc15115788c828d9dd7b4bff68067d3ce2ffb8) | `dfcc15115788c828d9dd7b4bff68067d3ce2ffb8` | [GNU GPLv3](../../licenses/supplement/librime-octagram-LICENSE.txt) |
| [librime-predict](https://github.com/rime/librime-predict/tree/920bd41ebf6f9bf6855d14fbe80212e54e749791) | `920bd41ebf6f9bf6855d14fbe80212e54e749791` | [BSD-3-Clause, ©2023 RIME Developers](../../licenses/supplement/librime-predict-LICENSE.txt) |
| [librime-lua thirdparty](https://github.com/hchunhui/librime-lua/tree/115e000c878d1170337f7ca934d7a84f68986e39) | `115e000c878d1170337f7ca934d7a84f68986e39` | [Lua5.4 MIT, ©1994-2024 Lua.org/PUC-Rio](../../licenses/supplement/Lua-5.4-MIT-NOTICE.txt) |

thirdparty與librime-lua主體來自同一repo的不同固定樹, 不能只抓主體commit而省掉內附Lua. 固定CMake入口在`thirdparty/lua5.4/lua.h`存在時編譯內附Lua5.4; 同源樹另有Lua5.3, 保存其[通知](../../licenses/supplement/Lua-5.3-MIT-NOTICE.txt) 不表示實際連結兩版.

Boost及librime的glog、leveldb、yaml-cpp、googletest、marisa-trie、OpenCC等依賴按實際構建固定來源取得, 保留其上游授權及通知. 61052 安裝器的實際依賴及通知由 Rime Stellae 的來源和安裝包清單列明.

固定下載、patch重放與CI產物校驗的範圍由BUILD記錄; 沒有承諾不同工具鏈的位元完全一致. 本工程原創構建說明採CC BY-SA4.0, 腳本與上游源碼依各自程式碼授權提供.
