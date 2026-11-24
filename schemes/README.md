# 墨芯方案

> 本專案由人類與 AI 協作產生. 部分 AI 提出的內容可能尚未經人工審核. 若有錯誤或疏漏, 敬請見諒.

[English (en)](README.en.md) | [Traditional Chinese (zh-TC)](README.md) | [Simplified Chinese (zh-SC)](README.zh-SC.md)

墨芯提供中文、英文及日語輸入方案, 包含墨芯前端用方案及官方 Weasel 相容方案.

## 現有功能

- 中文全拼、縮寫、既有容錯、組句及本地學習, 支援 TC/SC 輸出切換. 使用 `;` 固定前一個完整音節, 使用 `"` 確認其左側整段完整拼寫. 例如 `xiao;sr`、`woxiang"` 和 `wenti"s`.
- 游標位於草稿末端時, 兩套方案從第 8 鍵起以普通組句處理整段只能按單字母切分的簡拼.
- 英文的完整詞、補全、容錯、大小寫與既有縮寫展開.
- 查字、Unicode 及計算工具按輸入模式調用.
- 兩套方案均提供平假名、片假名、漢字、romaji、q/x/v 查詢模式.
- 官方 Weasel 方案使用原生整詞補全, 固定直排 6 項、非內嵌.
- 預設使用通用詞庫. 數學、物理、電腦及詩詞詞彙可透過獨立 DLC 安裝. 數學及物理包涵蓋廣泛學科詞彙, 詩詞包收錄固定來源的全量唐詩、宋詩、宋詞及配套選集.

墨芯完整方案新裝預設 SC 輸出, 中文橫排 5 項、英文直排 6 項. 兩套方案保留既有學習及自訂配置的使用方式. 墨芯前端的英文模式使用藍色 En 狀態圖標. 中文方案的左右 Shift 在中文與英文間切換, 紅 A 保留前端的原生輸入狀態.

## 安裝

- [墨芯前端與方案安裝器](https://github.com/unknownnumbers/rime-stellae/releases).
- [官方 Weasel 方案 ZIP](https://github.com/unknownnumbers/rime-stellae/releases/latest).
- [完整方案使用說明](docs/PC.md)、[官方方案安裝及合併](docs/official-weasel.md)、[DLC 來源](docs/dlc-sources.md).

共用維護源位於 [config/pc](config/pc), [config/official-weasel](config/official-weasel) 由同一源碼及明確的引擎設定生成. 修改共用源後使用 `python scripts/rebuild_profiles.py --refresh-official`, 並以 `--check` 核對派生結果. 安裝到已有資料夾時, 先備份同名配置並依說明合併, 保留用戶詞庫.

2026.11.14.2 詩詞 DLC 需要 2026.11.14.2 或更新的方案基座. 詞表由倉庫中的固定來源及構建程式生成, 可直接下載 Release 的模組 ZIP. 讀音與異文採自動處理及有限校核, 尚未逐句審校, 詳見 [DLC 來源與限制](docs/dlc-sources.md).

數學、物理與電腦 DLC 隨包提供英文拼寫糾錯索引. 已有舊包時可更新對應模組後重新部署.

## 開發與待辦

[構建說明](docs/BUILD.md) | [來源及再建範圍](docs/sources/README.md) | [待辦](TODO.md)

原創程式與配置採 GPL-3.0-only, 原創說明文字採 CC BY-SA 4.0. 第三方資料及原通知保留各自授權, 見 [授權索引](THIRD_PARTY_NOTICES.md).
