# Rime Stellae / 墨芯

> 本專案由人類與 AI 協作產生. 部分 AI 提出的內容可能尚未經人工審核. 若有錯誤或疏漏, 敬請見諒.

[English (en)](README.en.md) | [Traditional Chinese (zh-TC)](README.md) | [Simplified Chinese (zh-SC)](README.zh-SC.md)

墨芯提供 Windows 的 Rime 前端與配套輸入方案. 前端提供 TSF 輸入、候選介面、方案部署與配置管理; 方案支援中文、英文、日語及查字工具. 可選擇前端與完整方案整合包, 或供官方 Weasel 使用的獨立方案 ZIP. 數學、物理、電腦及詩詞詞彙可透過 DLC 添加.

## 安裝與使用

- [墨芯前端與完整方案安裝器](https://github.com/unknownnumbers/rime-stellae/releases/download/v2026.11.26.1/stellae-2026.11.26.1-installer.exe).
- [墨芯完整方案 ZIP](https://github.com/unknownnumbers/rime-stellae/releases/download/v2026.11.26.1/stellae-2026.11.26.1-schemes.zip), 用於已有的墨芯安裝.
- [官方 Weasel 方案 ZIP](https://github.com/unknownnumbers/rime-stellae/releases/download/v2026.11.26.1/stellae-2026.11.26.1-official-weasel-schemes.zip), 依[安裝與合併說明](schemes/docs/official-weasel.md)使用.
- 支援 64-bit Windows, 並附 32-bit 應用相容元件.
- 前端版本為 `0.17.4.61052`. 本輪整合包及方案版本為 `2026.11.26.1`.
- 整合方案新裝預設 SC 輸出, 中文橫排 5 項、英文直排 6 項, 保留 TC/SC 切換.
- 安裝器附 Noto Sans CJK Regular 字體合集. 首裝選 SC 或 TC 會設定相應的候選窗字體. 可在墨芯外觀設定切換 TC、HK、SC, 升級保留已選字體. [候選窗字體說明](docs/PC.md#候選窗字體)
- 配套方案的英文模式使用藍色 En 狀態圖標.
- `Ctrl+Space` 取消未上屏草稿並切換紅色 A 與原有中文或英文模式. 已安裝的舊版數學 DLC 可由整合安裝器補齊英文拼寫糾錯索引.
- 墨芯外觀自訂使用 `stellae.custom.yaml`, 官方 Weasel 使用 `weasel.custom.yaml`. 安裝器原樣遷移墨芯舊外觀檔案; 若新舊檔案內容不同, 先合併再升級.
- 升級保留用戶自訂與學習資料. 同名自訂遮蔽方案預設時, 依[使用說明](docs/PC.md)核對與合併.

[完整方案功能](schemes/docs/PC.md) | [可選詞彙與 DLC](schemes/docs/dlc-sources.md) | [構建](docs/BUILD.md) | [來源](docs/SOURCES.md) | [待辦](TODO.md)

前端、完整方案及官方 Weasel 適配版源碼均在本倉庫維護. 共用方案來源位於 `schemes/config/pc`, 官方適配版由同一來源生成. ARM64、實體鍵盤及各 Windows 宿主的完整驗收仍依已記錄的驗證範圍逐項進行.

原創程式、配置、測試及資產採 GPL-3.0-only, 原創說明文字採 CC BY-SA 4.0. 第三方元件保留原授權及通知, 見[來源與授權](THIRD_PARTY_NOTICES.md).
