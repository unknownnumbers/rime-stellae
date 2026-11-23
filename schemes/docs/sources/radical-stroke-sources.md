# 拆字與筆畫: 來源及變換

## 拆字/部件

`project_radical.dict.yaml`及配套schema源自[mirtlecn/rime-radical-pinyin](https://github.com/mirtlecn/rime-radical-pinyin/tree/87e73d7182916f3db9dbc0b6a4d18a78a775b298), 固定`87e73d7182916f3db9dbc0b6a4d18a78a775b298`, schema3.1.1、字典2026.06.18, 原字典Git blob `fcdd2e927acf52777c3969a4459068ebb8400a89`. 同次參考的Ice版本亦使用相同blob, 沒有把兩份相同來源當作獨立詞庫.

本工程只保留輸出恰為一個Unicode碼點的行: 原132,367行, 排除12項多字符單位後保留132,355行/92,539種輸出. 保留全部原code及權重、只改字典識別及單碼點範圍; 不把Unicode碼點數誤當UTF-16單元數. 這不表示全部輸出都已按漢字屬性過濾.

schema保留原碼中的部件分隔`'`作來源, 索引時逐部件相容`ing→in`、`eng→en`, 再去掉分隔符. 這是本工程輸入層變換, 不改原字形、拆分或讀音.

上游根為[GPLv3](../../licenses/radical-stroke/radical-GPL-3.0.txt). [完整原credits](../../licenses/radical-stroke/radical-source-credits.md) 列kfcd/chaizi (CC BY3.0)、CHISE ids (GPLv2 or later)、yi-bai/ids (MIT), 並說明合入henrysting添補. 原授權/署名已在[補充通知](../../licenses/supplement/README.md) 一併保存. 補充通知所固定的所見commit不能冒稱為Mirtle實際採用各上游資料的revision; 精確逐行整併版本仍未知.

## 筆畫

現用`query_strokes.tsv`從官方Weasel0.17.4附帶的`stroke.dict.yaml`版本1.1產生, 並非另有研究記錄的stroke2.0. 主表先取每字的第一CNS主碼; 補充段只為主表沒有的字取第一碼. 輸出75,064種字, 其中61種只在補充段, 最長64碼; 具體metadata見[query-strokes-source.json](query-strokes-source.json).

來源歸屬為[rime/rime-stroke](https://github.com/rime/rime-stroke), 保留[AUTHORS](../../licenses/radical-stroke/stroke-AUTHORS)、[LGPLv3](../../licenses/radical-stroke/stroke-LGPL-3.0.txt) 及[GPLv3](../../LICENSE). AUTHORS保存四季的風、雪齋、Kunki Chou、宋天及CNS11643來源/再分發說明. 安裝包1.1精確上游commit未識別.

作對照查閱的上游2.0固定`1e8fff9b9494ddec23b0cbc526bcfd8171a6fd48`, 170,386行/110,125種輸出; 這組數字不代表現用表已具該版本覆蓋.
