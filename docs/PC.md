# 墨芯使用說明

## 安裝

從[墨芯發布頁](https://github.com/unknownnumbers/rime-stellae/releases/latest)選擇同一版本的所需檔案, 以下 `VERSION` 代表發布版本:

- `stellae-VERSION-installer.exe`: 墨芯前端與完整方案整合安裝器.
- `stellae-VERSION-schemes.zip`: 完整方案, 用於已有的墨芯安裝.
- `stellae-VERSION-official-weasel-schemes.zip`: 官方 Weasel 用的墨芯方案, 依[手動安裝與合併說明](../schemes/docs/official-weasel.md)使用.
- `stellae-VERSION-source.zip`: 對應的前端、引擎與方案來源.

前端版本為 `0.17.4.61052`, 整合安裝包使用 x64 服務與引擎, 並提供 32-bit 應用所需的 TSF/IME 客戶端. 兩種應用共用同一服務, 安裝包不含獨立 Win32 後端. 官方 Weasel 方案 ZIP 使用官方前端與引擎, 不需要替換 DLL.

整合包附完整墨芯方案. 新裝預設 SC 輸出, 中文橫排 5 項、英文直排 6 項, 保留 TC/SC 切換. 中文、英文、日語、固定音節、查字與工具見[完整方案說明](../schemes/docs/PC.md); 官方 Weasel 的設定與能力見[官方適配版說明](../schemes/docs/official-weasel.md).

## 更新與詞彙模組

升級保留用戶自訂和學習資料. 自訂檔案可能覆蓋新版共享預設, 請按衝突報告對照合併. 共享資源依安裝清單更新及卸載, 未知或已修改檔案保留.

如需另加方案, 開啟用戶資料夾並依方案說明放入檔案, 再執行重新部署. 數學、物理、電腦及詩詞詞彙以可選 DLC 添加. 將完整模組放入用戶資料夾中的 `stellae_dlc/<id>/` 後重新部署; 卸載時刪除對應模組目錄並重新部署. 已有個人學習保留. 詳見[DLC 安裝與來源](../schemes/docs/dlc-sources.md).

## 候選窗字體

Windows 10 1607 或更新版本會隨墨芯離線安裝 Noto Sans CJK Regular 字體合集. 首裝時選 SC 或 TC, 候選窗會預設使用相應字體. 可另外將 Jigmo2/3 罕字後備字體安裝到 Windows.

在開始功能表開啟 **墨芯設定**, 於外觀設定選取 TC、HK 或 SC. 單獨修改字體會重新載入候選窗外觀並保留草稿. 升級保留字體選擇.

[構建](BUILD.md) | [來源](SOURCES.md) | [授權](../THIRD_PARTY_NOTICES.md)
