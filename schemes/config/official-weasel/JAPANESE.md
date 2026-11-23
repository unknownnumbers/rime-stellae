# 日語

平假名、片假名、漢字及 romaji 輸入, 另有 q/x/v 查詢模式.

小寫碼輸出平假名, 大寫碼輸出片假名. 小假名前加 x, 例如 `xa`、`XA`、`xtsu`、`XTSU`. `xX` 提供整段小假名查詢. `q`/`qQ` 查詢詞形, `v`/`vV` 使用中文拼音查詢日本漢字及讀音.

`Ctrl+E` 選擇日語方案, `Ctrl+R` 返回中文/英文方案. 具體拼寫由隨附產生器及 `japanese-q-canonical.json` 定義.

早期設計借鑒 [Sela 的日語方案](https://github.com/Selaube/rime-jp_sela).

假名基底可由 `tools/generate-japanese-base.py` 生成, 並以 `tools/validate-japanese-base.py` 檢查. q 資料的固定來源及重建方式見 [q 來源](../../docs/sources/jp-q-sources.md); v 資料見 [v 來源](../../docs/sources/jp-v-sources.md).
