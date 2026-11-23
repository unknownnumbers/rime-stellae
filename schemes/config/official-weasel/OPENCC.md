# OpenCC 資源與輸出

本方案的 `opencc/mdx_t2s.json` 使用相對檔名. 同一目錄附有官方 Weasel 0.17.4 資料包的 `TSCharacters.ocd2`、`TSPhrases.ocd2` 及本工程明列的 `mdx_words.txt`, 可隨方案一同部署.

`Ctrl+Shift+F` 切換 TC/SC 輸出. 輸出字形與前端介面語言分開設定. 小型字形規則的範圍見[來源說明](../../docs/sources/mdx-orthography-sources.md), OpenCC 資料保留 [Apache-2.0 通知](licenses/OpenCC-LICENSE.txt).

需要改用其他位置的共用 OpenCC 資源時, 可手動產生該安裝使用的 JSON:

```powershell
python config/pc/tools/make-opencc-config.py --shared-dir <shared-data> --output out/local-mdx_t2s.json
```

工具會檢查所需詞典, 在新的輸出檔記錄實際資源位置. 預設隨附的相對檔名配置可直接使用, 詳細檔案來源及校驗見[共用資源說明](../../docs/sources/shared-config-sources.md).
