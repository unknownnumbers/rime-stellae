# Rime Stellae / 墨芯

[English (en)](README.en.md) | [Traditional Chinese (zh-TC)](README.md) | [Simplified Chinese (zh-SC)](README.zh-SC.md)

> 本專案由人類與 AI 協作產生. 部分 AI 提出的內容可能尚未經人工審核. 若有錯誤或疏漏, 敬請見諒.

Rime Stellae 是基於 Weasel 的 Windows Rime 前端. 本倉庫提供 0.17.4.61052 的源碼、構建入口、測試及安裝器, 可與官方 Weasel 並存.

## 功能

- 獨立產品身分、程式目錄、服務及使用者資料目錄.
- TSF 按鍵配對、候選介面、上屏及焦點處理的原生修改.
- Caps 補鍵以事件標記識別, 正式構建關閉臨時數值診斷.
- 安裝與升級保留既有輸入法、所選註冊項目及使用者資料.
- 配色選擇、部署、詞典管理和手動安裝 Rime 方案的工具.

## 安裝與使用

從 [GitHub Releases](https://github.com/unknownnumbers/rime-stellae/releases) 取得安裝包. 安裝包不預裝輸入方案或詞典, 安裝後需自行加入方案並重新部署.

使用者資料預設位於 `%APPDATA%\RimeStellae`. 可從通知區選單開啟使用者資料夾、安裝方案或重新部署. 詳見[使用說明](docs/PC.md).

| 元件 | 發布內容 |
| --- | --- |
| 前端 | TSF、Server、Deployer、Setup 及 classic IME 0.17.4.61052 |
| 架構 | x64 與 Win32 |
| x64 引擎 | N01, step-only Lua GC |
| Win32 引擎 | R5 |
| 共用資源 | 前端外觀與配色預覽、空方案清單、標準 OpenCC、按鍵與標點資源 |

兩種架構的引擎版本分別固定, 構建資料見[構建說明](docs/BUILD.md)與[來源索引](docs/SOURCES.md). 目前公開驗證以 Windows hosted CI 為主, ARM64 尚未列入發布範圍. classic IME 的歷史升級路徑及部分宿主的焦點切換、偶發首鍵行為仍待持續驗證.

## 開發與待辦

源碼與安裝包各自附有來源清單及第三方通知. 構建步驟見[構建說明](docs/BUILD.md), 後續工作見[TODO](TODO.md). 本項目尚未設定自動更新來源.

## 授權與致謝

本工程原創程式、配置、測試、圖標及修改採 [GPL-3.0-only](LICENSE), 原創說明文字採 [CC BY-SA 4.0](licenses/CC-BY-SA-4.0.txt). 第三方部分保留原授權及署名, 詳見[授權與來源](THIRD_PARTY_NOTICES.md).

感謝 [Rime](https://github.com/rime)、[Weasel](https://github.com/rime/weasel)及其貢獻者, 以及引擎、插件和構建依賴的作者.
