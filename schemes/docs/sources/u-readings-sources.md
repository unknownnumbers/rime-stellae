# uU讀音附註資料

`u_readings.tsv`來自Unicode Consortium的[Unihan17.0.0官方archive](https://www.unicode.org/Public/17.0.0/ucd/Unihan.zip) 中`Unihan_Readings.txt`, 依[Unicode License V3](../../licenses/Unicode-3.0.txt). 欄位含義見[UAX38](https://www.unicode.org/reports/tr38/).

讀取順序為`kMandarin`, 再補`kHanyuPinyin`、`kXHC1983`. 移除來源定位metadata、正規化NFC、保留來源欄位順序並去除確切重複. 多讀音以` / `分開; 不按部件、字形或輸入碼猜音, 也不選定語境音.

顯示時以NFD取國語聲調記號: 一聲->1、二聲->2、三聲->3/4、四聲->5/6; `ü`->`v`. 未標聲調的讀音不加數字, 其他附加符號如`ê`保留, 再正規化NFC及去重. 例如`nǚ→nv3/4`、`gāo→gao1`、`qù→qu5/6`、`ńg→ng2`. 這是本工程選擇的顯示映射, 並非推定的歷史陰陽調/八調分類.

資料包括這三欄有讀音的字, 即使它不在拆字表; 不是現代常用國語的完整字典. 來源沒有讀音時明示缺失, 例如本版本`𬧱 U+2C9F1`與`𨋴 U+282F4`不從部件讀音補造. 標準`ing/eng`拼寫與輸入層相容規則分開.
