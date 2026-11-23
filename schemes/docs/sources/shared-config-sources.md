# 共用配置與筆畫依賴

兩套方案共用以下配置與資料, 來自官方 [Weasel 0.17.4](https://github.com/rime/weasel/releases/tag/0.17.4) 資料包. 它們支援預設配置、拼音規則、筆畫反查及字形轉換, 正文與原始署名保持原樣.

| 檔案 | SHA256 |
| --- | --- |
| `config/pc/default.yaml` | `5a438c92aa7ddd749644c7c799967074634d41ace924859be2a371f29565c892` |
| `config/pc/pinyin.yaml` | `f2d291166946a848fd88e541844567415f1ed3d9c5a7477757b88aeb3a69c0ca` |
| `config/pc/stroke.schema.yaml` | `f541d4c7450370b2652ae5e4190396803504edc987f74f16718458811312f303` |
| `config/pc/stroke.dict.yaml` | `0fe1c1c0673f3564f16deb1f659a75f3ad6a43e5308165dccfb63fd94864f631` |
| `config/pc/opencc/TSCharacters.ocd2` | `85291e0173e972bbca58c848fb90b3bb41c79674cb61a75645e01bd884ad5927` |
| `config/pc/opencc/TSPhrases.ocd2` | `edafc46f5c3eca61a754c78e47117e7c73995cacd6c99aadcb8a219d7ae3e53d` |
| `config/pc/key_bindings.yaml` | `19c52d80a4bf043c16c49fdfeb58cfa4d7a9f2b94bd18c79ff2485bd7627db5f` |
| `config/pc/punctuation.yaml` | `c9e5147fda24d1a13085075df5a2e73deecb643069be3751c6d4d793ceb2de5b` |
| `config/pc/symbols.yaml` | `d3c1823f0e3bae5fb2dac338f4863a0d7164436d1ee132727ff5c4687f53601a` |
| `config/pc/opencc/s2t.json` | `919c0a6fde65555879b249588ab8c785c5e4b85704be8863361776bd48094a25` |
| `config/pc/opencc/STCharacters.ocd2` | `4c7398b4ceedf9b58b5ea77cdd911bc7807c50c7491111dc9b4073c68ad5a2bb` |
| `config/pc/opencc/STPhrases.ocd2` | `5e8d8289beacc7d4ab7baa7193ebb589f3d5a956449ed9c81ccff431ae503f6e` |

`pinyin.yaml` 來自 [rime-luna-pinyin](https://github.com/rime/rime-luna-pinyin/blob/master/pinyin.yaml), 依該工程的 [LGPLv3](https://github.com/rime/rime-luna-pinyin/blob/master/LICENSE) 提供, 保留文件中的參考連結. 隨附[授權正文](../../licenses/luna-pinyin-LGPL-3.0.txt)及 [GPLv3](../../LICENSE).

`default.yaml`、`key_bindings.yaml`、`punctuation.yaml` 和 `symbols.yaml` 來自 [rime-prelude](https://github.com/rime/rime-prelude), 依 LGPLv3 提供. 隨附[授權正文](../../licenses/shared-config/prelude-LICENSE.txt)及 [AUTHORS](../../licenses/shared-config/prelude-AUTHORS.txt), 其中記錄 Gong Chen 的來源署名. 兩份通知固定在上游提交 `95542a274915ba5496ff3260a2c71946238d4cce`, 通知版本與資料包內配置的歷史版本分開記錄.

筆畫配置及詞典來自 [rime-stroke](https://github.com/rime/rime-stroke), 詞典版本為 `1.1`, 配置版本為 `0.5`. 該工程的 [LICENSE](https://github.com/rime/rime-stroke/blob/master/LICENSE) 為 LGPLv3, [AUTHORS](https://github.com/rime/rime-stroke/blob/master/AUTHORS) 保留 CNS11643 的再分發聲明及原作者. 本倉庫隨附[授權正文](../../licenses/radical-stroke/stroke-LGPL-3.0.txt)、[AUTHORS](../../licenses/radical-stroke/stroke-AUTHORS)及 GPLv3. 主表、附表來源和原作者仍在詞典檔頭.

OpenCC 配置及 `.ocd2` 保留 [OpenCC Apache-2.0 通知](../../licenses/OpenCC-LICENSE.txt), 與官方方案的相同檔案逐位元一致. `config/pc/source-dependencies.json` 固定新增資源和隨附通知的大小與內容 hash.

官方資料包對應這些檔案的精確上游提交仍未確定. 上方內容 hash 固定本次附帶的資料, 筆畫反查衍生表的同源說明見 [query-strokes-source.json](query-strokes-source.json).
