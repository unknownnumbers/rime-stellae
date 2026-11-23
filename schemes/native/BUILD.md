# Windows 原生來源與構建

Current frontend source and installer builds are maintained in [rime-stellae](https://github.com/unknownnumbers/rime-stellae). This directory retains earlier native recipes and their pinned inputs. Current scheme generation is documented in [Build](../docs/BUILD.md).

本目錄保存 61047 原生組合的來源與構建記錄. 目前配套墨芯前端為 61052, 其完整來源、補丁、測試及構建入口見 [Rime Stellae](https://github.com/unknownnumbers/rime-stellae).

本目錄提供實際採用的完整來源差異、固定上游及可執行的來源組裝/構建腳本. 本次更新為 61047 TSF、61042 x64 Server、61020 IME、N01 x64 執行時引擎與 R5 x64/x86 構建 SDK. [公開CI](https://github.com/unknownnumbers/RymCp-IME/actions/runs/40879482063)已通過五組來源組裝、三組引擎構建、三組Weasel元件構建及兩架構按鍵配對檢查, 詳見[驗證範圍](VALIDATION.md).

## 來源與產品組合

| 來源 variant | 產物/用途 |
| --- | --- |
| `weasel-61047` | x86/x64 TSF, 來源版本 `0.17.4.61047` |
| `weasel-server-61042` | x64 Server, 來源版本 `0.17.4.61042` |
| `weasel-61020` | 保留的x86/x64 IME, 來源版本 `0.17.4.61020` |
| `engine-n01` | 保留的 N01 詞碼接點與 step-only GC 配方; 本入口只宣告 x64 |
| `engine-r5` | 前端構建SDK及受控fixture的R5引擎, x64/x86; 與N01執行時引擎分開 |

每個 Weasel variant 都從相同固定官方提交開始套自己的完整 delta. 三份 Weasel patch 不能依序疊套. N01 與 R5 的 core/Lua patch 也分別套在各自原始上游, 不互相疊加.

61047 的 TSF Test 回呼取得引擎的實際處理結果並交付回覆, 配對的 Actual 回呼只確認已完成的處理; 只有 Actual 的回呼仍可處理. 這避免把輸入法已啟用直接當作按鍵已處理, 並保留同一次按鍵不重送、不重複寫入的配對規則. 已送出而結果未知的按鍵保持 Unknown, 不自動重送.

[source-manifest.json](source-manifest.json) 記錄所有公開來源URL、提交、patch SHA256、架構和下載資產. 來源組裝固定取Weasel、librime、librime-lua、octagram、predict與Lua thirdparty; Weasel的submodules隨其固定提交初始化. 原生程式含既有日語備註排版的schema識別碼, 這不要求取得外部Sela詞典; 配置來源及日語資料另由專案來源清單說明.

## 執行Actions

在GitHub的Actions開啟 **Native source assembly and optional compilation**, 選擇Run workflow.

- `compile=false`(預設): 先核對七份 patch 的 SHA256 和 PowerShell 語法, 再以五個隔離 checkout 檢查固定來源、submodules 及完整 patch 套用. 每個 variant 只產生來源組裝報告, 沒有執行編譯器.
- `compile=true`: 來源組裝通過後, 同次 workflow 構建 R5 x64、R5 x86 和 N01 x64; R5 成功產物供後續三個 Weasel variant 使用.

整個workflow只有`contents: read`. 它使用新的hosted runner, 不讀取個人設定或學習庫, 不操作既有安裝或捕捉現場輸入. 合成測例在臨時目錄部署固定fixture, 使用runner的獨立HKCU設定並於測試後恢復. 下載官方Weasel installer只用7-Zip抽取固定共用資料, 從不執行該installer; 構建命令也沒有`installer`目標.

成功開發產物會附帶本repo的第三方通知、完整patch與構建腳本, 只作當次開發構建輸出. 它們不是獨立安裝包, 也沒有完成完整真應用輸入驗收.

## 腳本入口

需要PowerShell7及Git. 以下在repo根目錄執行; 目的資料夾必須是新位置, 腳本不會重置既有checkout:

```powershell
./scripts/native/Test-Inventory.ps1
./scripts/native/Prepare-Sources.ps1 -Variant engine-n01 -Destination ./work/engine-n01
./scripts/native/Prepare-Sources.ps1 -Variant weasel-61047 -Destination ./work/weasel-61047
./scripts/native/Prepare-Sources.ps1 -Variant weasel-server-61042 -Destination ./work/weasel-server-61042
```

`Prepare-Sources.ps1`會取得指定上游, 再由`Apply-Patches.ps1`核對commit和patch雜湊、先check後apply. 組裝結果在目的資料夾的`native-source-assembly.json`; 來源組裝成功不代表編譯成功.

若已有精確上游原始碼壓縮包, 可只做唯讀套用檢查:

```powershell
./scripts/native/Apply-Patches.ps1 -Variant weasel-61047 -SourcePath ./upstream-weasel -CheckOnly -AllowSourceArchive
```

這個檢查只證明檔案內容符合patch上下文, 沒有檢查壓縮包的Git提交身份; `AllowSourceArchive`只准與`CheckOnly`一起使用. 正式來源組裝及構建要求固定Git checkout.

Windows編譯還需要預先具備VS2022 v143、ATL/MFC x86/x64、MSBuild、CMake、Ninja與7-Zip. 腳本不安裝這些工具. Actions中的`ilammy/msvc-dev-cmd`和`microsoft/setup-msbuild`設定已有工具的環境.

引擎的實際構建入口是:

```powershell
# 在已設定適當x64或x64_x86 MSVC環境的Windows runner上:
./scripts/native/Build-Engine.ps1 -Variant engine-r5 -Architecture x64 -SourcePath ./work/engine-r5-x64 -CacheDirectory ./work/cache -OutputDirectory ./work/out/engine-r5-x64
```

每個架構使用獨立的來源組裝目錄. R5另做x86; N01使用`-Variant engine-n01 -Architecture x64`. 腳本套用相同的Ninja/MSVC設定, 編譯34項production preedit helper測例, 執行上游`build.bat test`並要求CTest成功證據, 再核對DLL架構及輸出. 官方deps壓縮包提供第三方庫的預編譯輸入; 這不是整條依賴鏈完全從原始碼重建.

Weasel 的入口是 `Build-Weasel.ps1`, 參數見 workflow. 它要求同次 workflow 的 R5 x64/x86 SDK 及相同 manifest hash, 從 Boost1.84.0 源碼編譯所需靜態庫, 再以 MSBuild 只重建各 variant 的宣告目標與 project references: 61047 的 x64/Win32 `WeaselTSF`、61042 的 x64 `WeaselServer` 及 61020 的 x64/Win32 `WeaselIME`. TSF 與 IME 使用不同的來源組裝目錄, 避開共用 PDB 路徑. 公開產物只收各 variant 宣告的 TSF、Server 或 IME, 版本按實際來源分別標示.

Weasel 另有兩架各 36 項 Shift capture/codec 及抽取產品 handler 的合成 fixture, 只允許在 hosted CI 執行. 測例不啟動已安裝的服務、不注入產品 DLL、不改個人 registry; 覆蓋範圍不含真 named-pipe、OS 按鍵排序或完整宿主文字儲存.

61047 另有 `native/tests/key-pairing/Run-KeyPairingTests.ps1`, 以同次構建的 61042 Server 及 R5 引擎執行 x64/Win32 按鍵配對檢查. 每架構分三個新程序執行 V13、V18、V19, 預期各 45、16、34 項, 合計 95 項; 涵蓋重複 Test、Actual-only、跨 context 巢狀回呼、兩種 Actual 次序及 Space 選詞. 這些數量是通過條件, 當次結果以報告為準.

```powershell
./native/tests/key-pairing/Run-KeyPairingTests.ps1 -SourceRoot ./work/weasel-61047 -ServerOutputDirectory ./work/out/weasel-server-61042 -Architecture x64
```

來源目錄須已完成對應架構的構建, 另以 `-Architecture Win32` 執行另一架構. 測例使用真實 MSCTF manager、受控 COM context 授權與引擎 IPC, 觀察產品按鍵回呼. 公開開發產物在測試插樁前凍結, 完成後還原來源與乾淨 TSF 產物. 彙總報告為 `ci-logs/key-pairing-x64.json` 及 `ci-logs/key-pairing-win32.json`, 另保留各組原始追蹤. 此範圍不含完整 ActivateEx/ACP 宿主、實體按鍵派送或特定應用的現場原因判定.

## 固定範圍與限制

七份 patch 按各自固定上游提供完整差異. 本工程原創修改與構建腳本採 GPL-3.0-only, 原創說明文字採 CC BY-SA 4.0; 第三方元件、資料及引用原文保留各自授權與署名.

Boost1.84.0的SHA256採官方發布metadata; 固定Weasel0.17.4資產的SHA256採官方GitHub release digest並與既存官方檔核對. 兩份librime1.13.1 deps的GitHub API沒有digest, 本專案於2026-10-26從官方資產URL下載後計算並固定SHA256. 下載後的位元不符時腳本停止.

- [Boost官方hash](https://archives.boost.io/release/1.84.0/source/boost_1_84_0.7z.json)
- [Weasel固定release資產metadata](https://api.github.com/repos/rime/weasel/releases/assets/260794274)
- [librime固定release](https://github.com/rime/librime/releases/tag/1.13.1)

GitHub hosted image、MSVC/Windows SDK的修訂版, 以及Actions major tags仍會變動; 腳本記錄當次compiler、toolset、manifest和產物hash. 這份流程固定主要來源與下載位元, **不宣稱二進位逐bit可重現**. 組裝通過、編譯通過、受控fixture通過和真應用驗收應分別報告.
