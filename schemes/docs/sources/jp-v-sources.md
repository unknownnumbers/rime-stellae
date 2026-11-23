# 日語v查詢: 官方來源與字種邊界

This package uses the KANJIDIC2 and JMdict dictionary files. These files are the property of the Electronic Dictionary Research and Development Group (EDRDG) and James William Breen, and are used in conformance with the Group's licence. Derived EDRDG dictionary data is distributed under [CC BY-SA4.0](../../licenses/CC-BY-SA-4.0.txt); the [licence statement](../../licenses/EDRDG-licence.html), [KANJIDIC](../../licenses/KANJIDIC_Project.html) and [JMdict](../../licenses/JMdict-EDICT_Dictionary_Project.html) project documentation accompany this package.

| 來源 | 用途與固定資料 |
| --- | --- |
| [KANJIDIC2](https://www.edrdg.org/kanjidic/kanjidic2.xml.gz) | database2026-292、建立日期2026-10-19; 13,108種JIS X0208/0212/0213漢字的音訓/等級 |
| [文化廳常用漢字音訓索引](https://www.bunka.go.jp/kokugo_nihongo/sisaku/joho/joho/kijun/naikaku/kanji/joyokanjisakuin/index.html) | 2,136種常用字的事實性音訓及362種括列舊字對應; 沒有複製字形圖片/頁面設計 |
| [JMdict](https://www.edrdg.org/pub/Nihongo/JMdict_e.gz) | 2026-10-19; 實際完整整詞表記與假名讀音, 受`re_restr`/`re_nokanji`限制 |
| [Unihan17.0.0](https://www.unicode.org/Public/17.0.0/ucd/Unihan.zip) | 中文多音、日本來源、相容分解/variant證據; [Unicode License V3](../../licenses/Unicode-3.0.txt) |
| [OpenCC日本字形表](https://github.com/BYVoid/OpenCC/blob/master/data/dictionary/JPShinjitaiCharacters.txt) 及[1.1.9 JPVariants](https://github.com/BYVoid/OpenCC/blob/ver.1.1.9/data/dictionary/JPVariants.txt) | 只在明列對應時判字形類別, 不由字形生成讀音; [Apache-2.0](../../licenses/OpenCC-LICENSE.txt) |

主集合為KANJIDIC2. 另有28種相容字種, 歷史流程由舊v表提出, 再以Unihan的明確JMJ日本來源核實; 公開版把字種及官方欄位依據明列於`config/pc/jp-v-compatibility.json`, 不需要原Sela表作再生輸入. 讀音來自上述官方資料, 並非從Sela原讀音表複製.

常用字及括列舊字依文化廳表列音訓, 先訓後音; 表外字取KANJIDIC的ja_kun/ja_on, 沒有匯入nanori、SKIP或其他特殊檢索碼. 字種有來源不代表每條音訓都是現代高頻讀法. 去除讀音中的送假名點與詞綴連字符, 保留來源分組; Unicode正式canonical equivalent才可補相容字讀音, 不任意抄舊新字讀音.

中文查詢碼取Unihan明列多音, `ü/u:`轉v, 詞碼保存音節邊界; schema逐音節相容`ing/eng`, 不因此加入任意模糊音. 整詞只取JMdict實際完整表記及讀音, 不逐字拼出人造整詞音. 整詞缺失時回報未收錄, 沒有以單字音掩蓋缺失.

固定v字典487,029行: 18,488條單字多音碼、468,541條詞碼. 字種13,136種, 12,850種有中文碼; 整詞134,030種完整表記, 其中130,740種多字詞. 10種多字表記因某字缺中文音而沒有查詢碼, 其整詞資訊仍保留. 大表數量不代表任意整句日語轉換能力.

資料更新時從上述官方來源取得新版本、保存日期/hash, 按相同常用/表外字及完整詞限制再生, 核對字種來源、音訓分組及整詞集合, 再重建索引. EDRDG通知、資料日期與更新入口應隨新版本保留; 不能只更新來源標籤而不重做資料驗證.
