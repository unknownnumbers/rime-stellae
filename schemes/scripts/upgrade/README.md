# Offline scheme data upgrade

These tools migrate previous scheme data using the frontend already installed on the computer. They do not install a frontend or change its keyboard handling. Keep a full backup of the user directory before upgrading.

The Stellae integrated installer runs the corresponding upgrade steps. Use the manual sequence below with the official Weasel scheme ZIP. The tools live outside `payload/` and `FreshUserProfile/`; do not copy them into the runtime profile.

## Data mappings

| Previous name | Current name |
| --- | --- |
| `luna_pinyin.userdb` | `cn_stellae.userdb` |
| `pc_english.userdb` | `en_intelligence.userdb` |
| `jp_family.userdb` | `jp_kanji.userdb` |
| `rymcp_dlc/<module>` | `stellae_dlc/<module>` |

Learning migration works on offline copies through the installed engine's LevelDb API. Only the embedded database name changes. Record keys, commit counts, dynamic values, timestamps and other metadata are checked for equality. The original databases remain available until the new configuration deploys successfully, then move to an archive outside the runtime profile. These tools do not recalculate learning weights or merge conflicting databases.

DLC migration changes the namespace in generated dictionary headers and updates the corresponding file-manifest checksums. Dictionary bodies, English catalogs, prepared binary indexes, source records and original notices retain their bytes. Unknown modules are left in place. This is a one-time offline operation, not an input-time check or index rebuild.

## Official Weasel manual sequence

Close settings and exit Weasel before beginning. Keep it stopped while preparing, merging and deploying. Do not type through that frontend during these steps. Set the program and user paths to the official installation and the profile being upgraded. Run the commands from this directory in Windows PowerShell 5.1 or PowerShell 7.

```powershell
$ErrorActionPreference = 'Stop'
$program = 'WEASEL_PROGRAM_DIRECTORY'
$user = Join-Path $env:APPDATA 'Rime'
$work = Join-Path $env:LOCALAPPDATA ('Rime/scheme-upgrades/manual-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $work
$learning = @{UserDirectory=$user; EngineDirectory=$program; Frontend='Weasel'; CompiledAppearanceName='weasel'; WorkDirectory=(Join-Path $work 'learning')}
$modules = @{UserDirectory=$user; StateFile=(Join-Path $work 'modules.json'); AppearanceConfigId='weasel'}
& ./LearningStore.ps1 -Action Preflight @learning
& ./DlcNamespace.ps1 -Action Preflight @modules
& ./LearningStore.ps1 -Action Prepare @learning
& ./DlcNamespace.ps1 -Action Prepare @modules
& ./LearningStore.ps1 -Action Apply @learning
& ./DlcNamespace.ps1 -Action Apply @modules
```

Next, merge the new ZIP's `payload/` and `samples/` into the backed-up profile as described in the [official scheme guide](../../docs/official-weasel.md). Keep personal settings and other installed schemes. Update the schema list to the current `cn_stellae` and `jp_stellae` entries where appropriate, and merge the current Lua entrypoint. The appearance file remains `weasel.custom.yaml`. Review explicit old `user_dict` settings before using the new learning names.

Deploy with the official program, then finalize the data migration while the background server remains stopped:

```powershell
$deployment = Start-Process -FilePath (Join-Path $program 'WeaselDeployer.exe') -ArgumentList '/deploy' -WindowStyle Hidden -Wait -PassThru
if ($deployment.ExitCode -ne 0) { throw 'Deployment failed; keep both original and prepared data for recovery.' }
$deployment.Dispose()
& ./LearningStore.ps1 -Action Finalize @learning
& ./DlcNamespace.ps1 -Action Finalize @modules
& (Join-Path $program 'WeaselServer.exe')
```

If a step fails, stop there and preserve the work directory and original data. Differing old and new databases or module directories require an explicit merge. Do not delete one to bypass the check. If a personal configuration or script still refers to an old name, finalization conservatively retains that original data and reports the reference for review. New profiles and profiles already using the current names need no data migration.

Before finalization, the `Rollback` action can remove only the unchanged copies created by these tools. Keep the frontend stopped and retain the work directory. Modified data or retired originals require manual recovery from the verified archives; rollback does not replace them.

```powershell
& ./LearningStore.ps1 -Action Rollback @learning
& ./DlcNamespace.ps1 -Action Rollback @modules
```

All supplied data examples and tests are synthetic. The tools do not upload profile contents or learning data.
