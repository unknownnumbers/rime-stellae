# License texts and source records

[THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) defines project and third-party licensing scope. [file-licenses.json](file-licenses.json) covers repository files. [package-sources.json](package-sources.json) defines source mappings used to generate a per-file index for the installer payload.

[third-party-source-manifest.json](third-party-source-manifest.json) records the URL, extraction scope, byte length, SHA256 and Git blob hash of every retained original notice. These original texts are preserved without formatting edits.

- `native-dependencies/` contains notices from the pinned native build inputs.
- `supplement/` contains engine, plugin and bundled Lua notices.
- `package/` contains the manual package tools, shared configuration, CA data and installer runtime notices.
- `CC-BY-SA-4.0.txt` applies to the project's original explanatory text.

Run `python licenses/build_index.py` after changing the source-tree file inventory. Use `--check` to verify that the index is current and original notice bytes are intact. Generated package files require their own hash and source checks.
