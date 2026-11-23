# 公開原生來源的驗證範圍

2026-10-29. 本次公開來源為 61047 TSF、61042 x64 Server、61020 IME、N01 x64 執行時引擎與 R5 x64/x86 構建 SDK. 來源組裝、原生編譯、受控測例與真實應用驗收分別記錄.

## 本次 61047 來源

[公開原生CI](https://github.com/unknownnumbers/RymCp-IME/actions/runs/40879482063)已在提交`cf885750b13e5337acb724dd2e3fcea5ede6fb5f`以`compile=true`完成, 12個工作項目全部成功. 五個variant來源組裝、R5 x64/x86及N01 x64編譯、61042 Server、61047 TSF和61020 IME構建均通過. 三組引擎各通過34項production preedit helper檢查及上游CTest, 三個Weasel variant各通過兩架構36項Shift合成檢查.

`compile=false` 核對來源組裝; `compile=true` 才啟動引擎與前端編譯, 以及 workflow 明列的受控測例. 來源組裝檢查覆蓋五個獨立 variant 及七份完整 patch. N01 只宣告 x64 執行時, R5 x64/x86 供前端構建與受控 fixture 使用.

61047按鍵配對檢查在x64及Win32各通過V13、V18、V19的45、16、34項, 每架構合計95項. 它使用真實MSCTF manager、受控COM context及同次構建的Server/R5引擎IPC. 測試後來源及乾淨產品輸出均成功還原, 報告位置及入口見[原生構建說明](BUILD.md).

N01開發產物的構建紀錄顯示MSVC版本`19.44.35229.0`. 已核對其壓縮檔、DLL雜湊、來源manifest及68份隨附授權/署名通知, 均與發布來源記錄相符.

## 已完成的歷史公開檢查

[61033 公開來源組裝](https://github.com/unknownnumbers/RymCp-IME/actions/runs/40249570384)已成功, 使用 `compile=false`. 該次結果覆蓋當時的 `weasel-61033`、`weasel-61020`、`engine-r5` 與 `engine-n01` 來源組裝, 沒有執行原生編譯器, 也不代替本次 61047 來源的檢查.

配置與日語資料的既有隔離檢查結果見[構建說明](../docs/BUILD.md). 它們驗證本工程現有規則, 不等於所有桌面應用均已驗收.

## 結果界線

原生測例使用新建立的公開 fixture, 不讀取個人學習庫或日用配置. 合成回呼與受控引擎結果只覆蓋明列的操作, 不能據此宣稱自然按鍵派送、所有宿主相容性或全部歷史測例已通過. Ctrl+Space 在不同輸入焦點間的中英狀態同步仍列於[待辦](../TODO.md).

來源公開與開發構建輸出不表示提供了可直接安裝的二進位發行包. 本工程原創說明文字採 CC BY-SA 4.0; 第三方原始碼和通知保留各自授權.
