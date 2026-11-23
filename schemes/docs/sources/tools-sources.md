# 計算器、Unicode及取字工具

工具參考[iDvel/rime-ice固定版本](https://github.com/iDvel/rime-ice/tree/da1fbe602e38f26db846fa10120ee64c2b0324c0)`da1fbe602e38f26db846fa10120ee64c2b0324c0`, 工具Lua依[GPLv3](../../licenses/tools-Ice-GPL-3.0.txt) 提供.

- 計算器詞彙/行為參考`lua/calc_translator.lua`: ChaosAlphard, 貢獻者DeepChirp. 本工程採顯式算式parser, 不執行使用者輸入的Lua源碼.
- 取字參考`lua/select_character.lua`: 原由BlindingDark/rime-lua-select-character提供, 後由Ice貢獻者改編. 本工程依segment邊界及漢字範圍取字, 保留原始餘碼.
- Unicode查詢參考`lua/unicode.lua`的確切碼點及再加一位十六進位行為; 本工程補scalar/控制字檢查及僅確切命中的不可見字元名稱.

`tool_unicode_data.lua`由Unicode17.0.0的`UnicodeData.txt`、`DerivedCoreProperties.txt`、`PropList.txt`生成, 來源為[官方UCD](https://www.unicode.org/Public/17.0.0/ucd/), 依[Unicode License V3](../../licenses/Unicode-3.0.txt). 資料通知與工具GPL範圍分開; 保留程式原頭註與原貢獻者署名.
