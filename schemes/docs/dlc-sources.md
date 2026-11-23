<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
# 可選詞表的來源與重建

四個獨立 DLC 包提供數學、物理、電腦及詩詞詞彙. 通用基座可單獨使用. 每個 ZIP 包含完整的 `rymcp_dlc/<id>/` 目錄、資料清單、來源紀錄及原授權通知.

| 包 | 中文詞條 | English 身份 | 範圍 |
| --- | ---: | ---: | --- |
| `math` | 17179 | 23388 | CC-CEDICT 領域詞及廣泛數學主題的公開標籤 |
| `physics` | 18174 | 24557 | CC-CEDICT 領域詞及廣泛物理主題的公開標籤 |
| `computer` | 680 | 345 | CC-CEDICT 的電腦、程式設計及網路領域詞 |
| `poetry` | 2885455 | 0 | 固定來源的全量唐詩、宋詩、宋詞及完整配套選集 |

上表為 2026.11.14.2 的去重結果. English 身份可有大小寫及帶變音符號的顯示別名, 對應資料列數在數學包為 24575、物理包為 24966. 各包的精確詞條數、略過計數、ZIP 大小及 SHA-256 記錄在構建產物 `out/dlc/modules/build-report.json` 及包內 `SOURCE.json`. 生成詞表及讀音標注採 CC BY-SA 4.0, 第三方來源保留各自授權及通知.

## 固定來源

來源原件保存在 [`dlc/sources`](../dlc/sources). [來源鎖定清單](../dlc/sources/catalog-source-lock.json) 記錄檔案大小及 SHA-256, 構建前逐一核對. 構建使用隨附的固定資料及讀音軟體, 可離線執行.

### 詩詞

詩詞固定於 [chinese-poetry commit b8594f81a89752241442f2ce267d6f66f96704ee](https://github.com/chinese-poetry/chinese-poetry/tree/b8594f81a89752241442f2ce267d6f66f96704ee). 三個主資料集完整遍歷該版本的 335 份 JSON, 共 332905 筆詩作記錄.

| 來源封存檔 | 詩作記錄 | 原始 JSON 檔 |
| --- | ---: | ---: |
| `poetry/tang-poems.zip` | 57607 | 58 |
| `poetry/song-poems.zip` | 254248 | 255 |
| `poetry/song-ci.zip` | 21050 | 22 |

`poetry/companion-anthologies.zip` 另保留完整《唐詩三百首》、《宋詞三百首》、水墨唐詩、蒙學唐詩及《千家詩》資料, 展開分組後共 1368 筆詩作記錄. 配套選集會與主資料重合, 也能提供不同流傳文本. 所有集合採相同抽取規則, 生成候選按詞文及編碼去重.

[主資料清單](../dlc/sources/poetry/source-manifest.json) 與 [配套選集清單](../dlc/sources/poetry/variant-source-manifest.json) 記錄來源路徑、固定 URL、大小、SHA-256 及 Git blob SHA-1. 壓縮檔內原始 bytes 及 [MIT 通知](../dlc/sources/poetry/LICENSE) 保持原樣.

### 數學、物理及電腦

CC-CEDICT 固定快照為 2026-11-13T04:51:32Z, 共 125412 條, 原始檔 SHA-256 為 `3199822e3cb14dfd13b4c80374cefb6d02e579e92f39e5ac7e6a7fa702fae739`. 生成器遍歷完整詞典, 按英文釋義中的括號領域標記抽取數學、物理及電腦詞條, 電腦包略過 internet slang 標記. 中文保留來源 TC 頭詞及拼音; English 僅保留移除括號註釋後整段符合 `[A-Za-z]+` 的單詞.

數學及物理包另使用 [science 固定快照](../dlc/sources/science/science-source-manifest.json). 選取範圍為 Wikipedia 數學及物理主題項目評估根分類下的完整普通條目等級, 包括列表、初稿及未評估條目. 固定快照分別記錄 28242 及 24559 篇條目, 並保存對應 Wikidata 實體的中文、English 及通用名稱和別名. 每個實體保留取得時的版本及修改時間, 原始成功 API 回應另行封存.

這些資料只含條目標題、標籤、別名及來源中介資料, 不包含百科正文. 中文移除尾端消歧義標記, 合併漢字間的名稱分隔符後核對讀音. English 依固定規則分詞, 使用 lowercase ASCII 身份, 來源大小寫及變音符號保留為顯示別名. Wikipedia 來源保留 CC BY-SA 4.0, Wikidata 來源保留 CC0 1.0 通知.

### 讀音與字形資源

讀音使用隨附的 [pypinyin 0.55.0](../dlc/sources/readings/pypinyin-source.json), 字形處理使用 [OpenCC 1.1.9 固定詞典](../dlc/sources/readings/opencc/source.json). 遇到原字缺音時, 依固定欄位及來源順序使用 [Unihan 17.0.0](../dlc/sources/readings/unihan-source.json) 的可編碼讀音. 合法音節集合由公開 Luna 主詞表抽取, 保存在 `allowed-syllables.txt`. 各來源的原通知隨附.

## 抽取、異文與讀音

全部新增詞條使用固定權重 `100`. 同包按 canonical code 及詞文去重. 與基座或其他包重合的身份不累加初始詞頻, 本地學習仍由原生用戶詞庫管理.

詩詞清理按整首作品處理括號註釋, 保留明確的單字方括號字形, 並按句讀產生至少兩字的分句. 可以明確逐字對齊的顯式異文會生成附加候選. 註釋中無法對齊的內容不當作詩句, 缺字佔位符、未知組字描述及無法解析的括號會隔離受影響分句, 不以任意刪字拼出新句. 可能兼作詩文的用語保留核查標記, 不因含有異文術語就一律刪除.

讀音使用詞組匹配、有限語境規則及原字回退, 再檢查逐字對齊與合法音節. 輸出編碼不含聲調, `ü`、`u:` 統一寫成 `v`. 句末語法啟發式、字形轉換、異文及無法編碼的分句均保留處理計數. 所有清理、標注及去重規則公開在 `scripts/data/`.

全量來源不代表每句都能產生候選. 不完整原文、罕見字讀音、多音字、古今音差異及文本異文仍可能造成遺漏或誤讀. 自動核驗及固定樣例回歸已納入構建流程, 尚未逐句人工審校, 也不以此宣告校勘定本.

## 重建

在專案根目錄執行:

```sh
python scripts/build_dlc.py
```

展開目錄預設輸出至 `out/dlc/modules/rymcp_dlc/`, ZIP 輸出至 `out/dlc/`. 可使用 `--output` 及 `--archive-dir` 指定新的輸出目錄. `out/dlc/modules/build-report.json` 記錄全部包的構建結果. Git 追蹤固定來源、清單及程式, 展開詞表及生成 ZIP 留在構建輸出目錄.

ZIP 採固定檔案次序、時間戳及 Deflate 壓縮. 固定來源及工具環境可重複產生相同輸出. 本版詩詞 ZIP 為 50619272 bytes (約 48.3 MiB), 解壓後模組檔案合計 135072658 bytes (約 128.8 MiB), 原生編譯表另計. 下載包、解壓資料及編譯後原生表的大小分別以發布附件、構建報告及原生驗證結果為準.

## 安裝、更新與卸載

2026.11.14.2 的詩詞包使用 format 2, 需要 2026.11.14.2 或更新的方案基座. 先更新基座, 再解壓所需 ZIP 至 Rime 用戶資料夾, 使資料位於 `rymcp_dlc/<id>/`, 然後重新部署.

每包的 `manifest.tsv` 記錄資料、來源及授權檔案. 模組 ZIP 在構建時核對清單和檔案. 保留完整模組目錄, 更新模組後重新部署.

卸載時刪除該包的完整目錄, 再重新部署. 原生編譯快取可以保留, 不會使已卸載的靜態詞表繼續啟用. 個人學習庫繼續保留, 已學習的詞或與其他來源共用的字詞仍可能出現.

## 分片與載入

詩詞的 `words.dict.yaml` 只含啟用表頭, 內容分別儲存在 `words_00.dict.yaml` 至 `words_31.dict.yaml` 共 32 個分片, 不再重複附帶一份完整大表. 分片按 canonical code、詞文全域嚴格排序後連續等分. format 2 清單以 `cn-layout` 及 `cn-rows` 記錄布局及總列數.

中文模組在部署時交給 Rime 編譯, 日常輸入讀取已編譯詞表. 數學、物理及電腦模組的 `english_index/` 存放預生成的英文拼寫糾錯索引. 舊模組的英文精確匹配仍可用, 更新模組可補齊拼寫糾錯索引.

格式回歸涵蓋兩種清單格式、分片完整性、更新、刪除、重裝、原生編碼及詞文逐條比對、表容量及合成學習保留, 見 [構建與驗證](BUILD.md).

生成器程式碼採 GPL-3.0-only. 本說明採 CC BY-SA 4.0. 第三方來源保留各自原授權及通知.
