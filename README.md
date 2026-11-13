# Rime Stellae / 墨芯

> 本專案由人類與 AI 協作產生. 部分 AI 提出的內容可能尚未經人工審核. 若有錯誤或疏漏, 敬請見諒.

[English (en)](README.en.md) | [Traditional Chinese (zh-TC)](README.md) | [Simplified Chinese (zh-SC)](README.zh-SC.md)

墨芯是 Windows 的 Rime 前端, 提供 TSF 輸入、候選介面、方案部署與配置管理. 整合安裝器附通用 RymCp 方案, 可另安裝數學、物理、電腦及詩詞 DLC.

## 安裝與使用

- 從 [Releases](https://github.com/unknownnumbers/rime-stellae/releases) 取得安裝器.
- 支援 x64 與 Win32, 包括 x64 Windows 的 32-bit 應用.
- 前端版本為 `0.17.4.61052`. 方案與整合包另記版本.
- 整合方案新裝預設 SC 輸出, 中文橫排 5 項、智能英文直排 6 項, 保留 TC/SC 切換.
- 升級保留用戶自訂與學習資料. 同名自訂遮蔽方案預設時, 依 [使用說明](docs/PC.md) 核對與合併.

[方案源碼及官方 Weasel 方案](https://github.com/unknownnumbers/RymCp-IME) | [構建](docs/BUILD.md) | [來源](docs/SOURCES.md) | [待辦](TODO.md)

本倉庫交付前端與整合安裝器. 方案功能、可選詞彙及鄉音復健的後續工作見 RymCp 專案. ARM64、實體鍵盤及各 Windows 宿主的完整驗收仍依已記錄的驗證範圍逐項進行.

原創程式、配置、測試及資產採 GPL-3.0-only, 原創說明文字採 CC BY-SA 4.0. 第三方元件保留原授權及通知, 見 [來源與授權](THIRD_PARTY_NOTICES.md).
