# TC compact詞模型

來源為[lotem/rime-octagram-data release20260712](https://github.com/lotem/rime-octagram-data/releases/tag/20260712), tag指向`8ceef1b42eb77e86501382a52e85c309c0f2f04c`. 模型未修改, Luna仍是TC主字典.

| 欄位 | 固定值 |
| --- | --- |
| asset | `zh-hant-t-essay-bgw-compact.gram` |
| asset ID | `474090370` |
| 大小 | `41,415,724` bytes |
| SHA256 | `0488ebd6688f900a39200f2b794f2f99bcbf1e8fc27280ae4a2324b08b1559c1` |
| 授權 | [LGPLv3](../../licenses/luna-compact-model-LGPL-3.0.txt) 及[GPLv3](../../LICENSE); 上游原作者署名保留 |

官方release的digest與本工程固定副本實算一致. 上游[固定README](https://github.com/lotem/rime-octagram-data/blob/8ceef1b42eb77e86501382a52e85c309c0f2f04c/README.md) 指向[固定LGPL](https://github.com/lotem/rime-octagram-data/blob/8ceef1b42eb77e86501382a52e85c309c0f2f04c/LICENSE). 如構建流程下載該asset, 必須校驗大小與SHA256, 不能僅依檔名取得浮動版本.

grammar參數參考[Ice固定recipe](https://github.com/iDvel/rime-ice/blob/21291c76f51257b4e09d50a6f578df24fcd0cb80/others/recipes/grammar.recipe.yaml), 保留原graph width與context政策. 上游檔名中的`hant`是原資源識別碼, 公開敘述使用TC.
