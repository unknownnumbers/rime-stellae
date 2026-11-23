# q/qQ查詞資料與獨立假名基底

This package uses the JMdict dictionary file. This file is the property of the Electronic Dictionary Research and Development Group (EDRDG) and James William Breen, and is used in conformance with the Group's licence. Derived dictionary data is distributed under CC BY-SA 4.0. The [licence statement](../../licenses/EDRDG-licence.html), [CC BY-SA4.0 legal code](../../licenses/CC-BY-SA-4.0.txt) and [project documentation](../../licenses/JMdict-EDICT_Dictionary_Project.html) accompany this package.

## 官方詞資料

JMdict來源為[官方JMdict_e.gz](https://www.edrdg.org/pub/Nihongo/JMdict_e.gz), 固定來源日期2026-10-19; 壓縮檔SHA256為`e84b7515b481485fe17f79939144bfbbd545638676899849512c99959ec03c1e`. 表記/讀音依`re_restr`、`re_nokanji`、`stagk`、`stagr`配對; 詞類依sense明列POS及前段繼承. 格式見[官方DTD](https://www.edrdg.org/jmdict/jmdict_dtd_h.html).

有限詞形按國際交流基金[《教科書を作ろう》せつめい編](https://www.jpf.go.jp/j/urawa/j_rsorcs/textbook/dl/setsumei/setsumei_all.pdf) 及[て形表](https://www.kyozai.jpf.go.jp/kyozai/material/BTS00068/ja/render.do) 所述規則生成, 並標記為規則派生, 沒有冒稱JMdict逐條收錄. 一般v1/v5、行く、来る/くる、明收する的有限形式依原POS受限處理; い形容詞只生成過去/否定/否定過去/くて. 例外、過時/罕見/search-only及異常送假名等保守地只保留辭書形.

沒有可能、受身、使役、命令、意向、任意助動詞串、口語縮約或整句生成. 生成上界為辭書形加七個動詞形式, 或加四個い形容詞形式, 不遞迴套規則. 固定產物有423,663條dictionary rows、275,595種code; 來源記錄條數不等於不同詞形數.

## 公開版假名/羅馬字基底

歷史產生器曾從Selaube原假名表取得羅馬字映射. 本工程後續已有自己的假名、漢字與q/x/v規則, 不以兼容原方案為目標. 公開版由本工程按這些需求獨立編寫的`config/pc/tools/generate-japanese-base.py`生成假名表及322項`japanese-q-canonical.json`, 為現用q資料再生提供顯式來源; 原Sela schema及碼表正文沒有整檔打包. 檔名/schema ID `jp_sela`是目前模組使用的識別碼, 不代表原表沿用. 感謝[Selaube/rime-jp_sela](https://github.com/Selaube/rime-jp_sela) 提供早期設計借鑒; 未找到其整份原檔的明確再分發條款, 因此不將它改標GPL.

新假名生成程式/配置依GPLv3; JMdict衍生資料仍依CC BY-SA4.0. 公開生成器與322項inventory可獨立檢查. 本次已使用固定JMdict XML與新inventory完整重生423,663行q詞典, SHA256為`a88dbdca92805084447df214ce135402b58b1842844fcc7ffbfa8f4af1be7e05`, 與隨附詞典逐位元相同; 沒有使用原Sela詞典作再生輸入. 這項資料重生不等於真應用輸入已逐項驗收. 實際檢查與使用範圍見[日語PC說明](../../config/pc/JAPANESE.md).

完整code包含`ん`在vowel/y前的`n'`邊界、尾n/nn、促音及長音l. 呼叫端將查詢正文轉小寫, 但不改raw; 不依輸入大小寫改送假名字形. 原生helper關閉completion/sentence/user dictionary, 整合端仍拒絕無來源的sentence候選, 按匹配消耗正文, 保留尾段及既有學習身份.

## 單字讀音與字形家族

`config/pc/lua/jp_family_data.lua`的`q_codes`由[單字讀音資料](jp-v-sources.md)及現用`japanese-q-canonical.json`生成, 使用與q詞庫相同的羅馬字算法. 13,136筆字元資料中的34,245個讀音生成12,390字、38,503個查詢碼. 字形家族、別名與其他讀音欄位保持原有內容. 讀音衍生資料保留EDRDG、Unicode及OpenCC的相應來源條款, 生成程式採GPL-3.0-only.

執行`python scripts/data/rebuild_japanese_family_q.py --check`可核對隨附結果; 使用`--output <new-file>`可另存新結果, 輸出摘要記錄來源與結果的SHA256.

## 更新程序

資料更新從官方來源取得新JMdict並保存日期/SHA256, 用`python scripts/data/build_japanese_q.py --source <JMdict_e.gz> --out out/japanese-q`重建受限制的表記/讀音及有限詞形, 再核對來源限制、輸出集合及輸入消耗. 輸出目錄必須是新位置, 生成器不改隨附詞典; 可用`--expected-source-sha256`驗證固定輸入. 不能只用新假名表覆蓋一份未核對的詞庫. 新增生成結果須一併保留來源紀錄與EDRDG通知.
