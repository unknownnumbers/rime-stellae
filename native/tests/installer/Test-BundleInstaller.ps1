# SPDX-License-Identifier: GPL-3.0-only
#Requires -Version 7.2
param(
  [Parameter(Mandatory)][string]$PackageDirectory,
  [Parameter(Mandatory)][string]$SchemeSource,
  [Parameter(Mandatory)][string]$OutputDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or -not [Environment]::Is64BitProcess){throw 'Use a disposable x64 hosted runner'}
if(Test-Path -LiteralPath $OutputDirectory){throw 'Use a new synthetic fixture directory'}
$null=New-Item -ItemType Directory -Path $OutputDirectory
$out=(Resolve-Path -LiteralPath $OutputDirectory).Path
$env:STELLAE_BUNDLE_TEST_TRACE=Join-Path $out 'bundle-runtime.log'
$package=(Resolve-Path -LiteralPath $PackageDirectory).Path
$inputs=Get-Content -LiteralPath (Join-Path $package 'stage/output/bundle-inputs.json') -Raw|ConvertFrom-Json
$installer=Join-Path $package ('release/stellae-rymcp-'+$inputs.bundleVersion+'-installer.exe')
$checks=@()
function Check([string]$Name,[bool]$Passed){$script:checks+=@([ordered]@{name=$Name;passed=$Passed});if(-not $Passed){throw $Name};Write-Output ('PASS '+$Name)}
function Run([string]$File,[string]$Arguments){
  $process=Start-Process -FilePath $File -ArgumentList $Arguments -PassThru -WindowStyle Hidden
  try{
    if(-not $process.WaitForExit(900000)){throw 'Installer fixture timed out'}
    if($process.ExitCode -notin @(0,3010)){
      $program=Join-Path $env:ProgramFiles 'RimeStellae'
      $expected=@('BundleData.ps1','data/default.yaml','data/rime.lua','data/pc_research.schema.yaml','data/jp_sela.schema.yaml','data/stellae-managed-files.json','scheme-status.json')
      $files=@(foreach($name in $expected){
        $path=Join-Path $program $name
        $present=Test-Path -LiteralPath $path -PathType Leaf
        $hash=$null
        if($present){try{$hash=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant()}catch{}}
        [ordered]@{path=$name;present=$present;sha256=$hash}
      })
      $helper=$null
      $status=Join-Path $program 'scheme-status.json'
      if(Test-Path -LiteralPath $status){
        try{
          $value=Get-Content -LiteralPath $status -Raw|ConvertFrom-Json
          if($value.PSObject.Properties['stage'] -and $value.stage -eq 'shared-helper'){$helper=[ordered]@{stage=$value.stage;errorType=$value.errorType;hresult=$value.hresult;sourceLine=$value.sourceLine}}
        }catch{}
      }
      [ordered]@{passed=$false;program=[IO.Path]::GetFileName($File);exitCode=$process.ExitCode;expectedFiles=$files;helperFailure=$helper}|ConvertTo-Json -Depth 7|Set-Content -LiteralPath (Join-Path $out 'process-failure.json') -Encoding UTF8
      throw ('Installer fixture process failed: '+[IO.Path]::GetFileName($File)+' exit '+$process.ExitCode)
    }
  }finally{$process.Dispose()}
}
function Snapshot([string]$Name){
  $path=Join-Path $out ($Name+'.json')
  & "$env:WINDIR/System32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'NativeProfileSnapshot.ps1') -OutputFile $path|Out-Null
  if($LASTEXITCODE){throw 'Windows profile capture failed'}
  return Get-Content -LiteralPath $path -Raw|ConvertFrom-Json
}
function Stop-Stellae([string]$Root){
  Run (Join-Path $Root 'StellaeServer.exe') '/quit'
  $limit=[DateTime]::UtcNow.AddSeconds(15)
  while((Get-Process StellaeServer -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $limit){Start-Sleep -Milliseconds 100}
  if(Get-Process StellaeServer -ErrorAction SilentlyContinue){throw 'Synthetic service remained running'}
}
$api=Join-Path $out 'rime_api.h'
$headerPreflight=@'
import io,json,pathlib,re,sys,zipfile
source,out=pathlib.Path(sys.argv[1]),pathlib.Path(sys.argv[2])
checks=[('rime_api.h','rime_api_t',['setup','initialize','deployer_initialize','finalize','create_session','get_status','process_key','get_commit','find_module']),('rime_levers_api.h','rime_levers_api_t',['export_user_dict'])]
results=[]
with zipfile.ZipFile(source) as outer:
    with zipfile.ZipFile(io.BytesIO(outer.read('engine-r5-x64-source.zip'))) as inner:
        for name,structure,required in checks:
            raw=inner.read('src/'+name)
            body=raw.decode('utf-8-sig').split('typedef struct RIME_FLAVORED('+structure+') {',1)[1].split('}',1)[0]
            body=re.sub(r'/\*.*?\*/|//[^\n]*','',body,flags=re.S)
            names=re.findall(r'\(\s*\*\s*(\w+)\s*\)',body)
            if not all(key in names for key in required):raise RuntimeError('Required fixture API fields are absent')
            (out/name).write_bytes(raw)
            results.append({'header':name,'fields':len(names),'requiredFieldsPresent':True})
print(json.dumps({'headerPreflightPassed':True,'headers':results}))
'@
& python -c $headerPreflight (Join-Path $package 'inputs/frontend-61052-source.zip') $out
if($LASTEXITCODE){throw 'Fixed source API headers or fixture API structures are invalid'}
Run (Join-Path $package 'inputs/official-weasel-0.17.4.exe') '/S'
$before=Snapshot 'before-bundle'
$foreign=@($before.Enabled.Id)
$officialRoot=(Get-ItemProperty 'HKLM:/Software/WOW6432Node/Rime/Weasel').WeaselRoot
$officialHash=(Get-FileHash -LiteralPath (Join-Path $officialRoot 'WeaselServer.exe')).Hash
$officialPids=@(Get-Process WeaselServer -ErrorAction SilentlyContinue|Select-Object -ExpandProperty Id|Sort-Object)
$root=Join-Path $env:ProgramFiles 'RimeStellae'
$shared=Join-Path $root 'data'
$user=Join-Path $env:APPDATA 'RimeStellae'
Run (Join-Path $package 'inputs/frontend-61052.exe') '/S'
Stop-Stellae $root
Check 'Bare installation has no bundle ownership manifest' (-not (Test-Path -LiteralPath (Join-Path $shared 'stellae-managed-files.json')))
$bareDefaultHash=(Get-FileHash -LiteralPath (Join-Path $shared 'default.yaml')).Hash
$bareUser=Join-Path $user 'bare-user-sentinel.txt'
[IO.File]::WriteAllText($bareUser,'synthetic user file retained from bare installation')
[IO.File]::WriteAllText((Join-Path $user 'weasel.custom.yaml'),"patch:`n  style/font_point: 17`n")
$bareUserConfigHash=(Get-FileHash -LiteralPath (Join-Path $user 'weasel.custom.yaml')).Hash
Add-Content -LiteralPath (Join-Path $shared 'symbols.yaml') -Value '# synthetic shared modification retained from bare installation'
$bareSymbolsHash=(Get-FileHash -LiteralPath (Join-Path $shared 'symbols.yaml')).Hash
$null=New-Item -ItemType Directory -Path (Join-Path $shared 'unmanaged') -Force
[IO.File]::WriteAllText((Join-Path $shared 'unmanaged/bare-keep.txt'),'synthetic unknown nested file retained from bare installation')
Run $installer '/S'
$after=Snapshot 'after-bundle'
Check 'Existing official input profiles preserved' (@($foreign|Where-Object {$_ -notin @($after.Enabled.Id)}).Count -eq 0)
Check 'Bundled schemas installed in shared data' ((Test-Path -LiteralPath (Join-Path $shared 'pc_research.schema.yaml')) -and (Test-Path -LiteralPath (Join-Path $shared 'jp_sela.schema.yaml')))
Check 'Bare empty shared default replaced by full bundle default' ((Get-FileHash -LiteralPath (Join-Path $shared 'default.yaml')).Hash -cne $bareDefaultHash -and (Get-FileHash -LiteralPath (Join-Path $shared 'default.yaml')).Hash -ceq (Get-FileHash -LiteralPath (Join-Path $package 'stage/output/shared-payload/data/default.yaml')).Hash)
Check 'Bare user sentinel preserved by migration' ((Get-Content -LiteralPath $bareUser -Raw) -ceq 'synthetic user file retained from bare installation')
Check 'Bare user UI customization preserved by migration' ((Get-FileHash -LiteralPath (Join-Path $user 'weasel.custom.yaml')).Hash -ceq $bareUserConfigHash)
Check 'Bare modified shared file preserved by migration' ((Get-FileHash -LiteralPath (Join-Path $shared 'symbols.yaml')).Hash -ceq $bareSymbolsHash)
Check 'Bare unknown shared nested file preserved by migration' ((Get-Content -LiteralPath (Join-Path $shared 'unmanaged/bare-keep.txt') -Raw) -ceq 'synthetic unknown nested file retained from bare installation')
$migration=Get-Content -LiteralPath (Join-Path $root 'scheme-status.json') -Raw|ConvertFrom-Json
Check 'Bare default is adopted while modified shared file is reported' ('default.yaml' -notin $migration.sharedConflicts -and 'symbols.yaml' -in $migration.sharedConflicts)
Check 'User default and UI custom files remain reported after preset rename' ('default.custom.yaml' -in $migration.userOverrides -and 'weasel.custom.yaml' -in $migration.userOverrides)
Check 'Core frontend version remains 61052' ((Get-Item -LiteralPath (Join-Path $root 'StellaeServer.exe')).VersionInfo.FileVersion -eq '0.17.4.61052')
foreach($name in @('stellae.dll','stellaex64.dll','stellae.ime','stellaex64.ime','StellaeServer.exe','StellaeDeployer.exe','StellaeSetup.exe','rime.dll')){
  Check ('Installed production bytes match pinned 61052 '+$name) ((Get-FileHash -LiteralPath (Join-Path $root $name)).Hash -ceq (Get-FileHash -LiteralPath (Join-Path $package ('stage/output/'+$name))).Hash)
}
Stop-Stellae $root
$hostExe=(Get-Process -Id $PID).Path
& $hostExe -NoProfile -File (Join-Path $PSScriptRoot 'Test-InstalledBundleReady.ps1') -EngineDll (Join-Path $root 'rime.dll') -SharedData $shared -UserData $user -SchemeSource $SchemeSource -OutputDirectory (Join-Path $out 'installed-ready')
if($LASTEXITCODE){throw 'The actual installed user profile is not ready without redeployment'}
Check 'Actual installed user input works without test redeployment' ((Get-Content -LiteralPath (Join-Path $out 'installed-ready/result.json') -Raw|ConvertFrom-Json).passed)
& $hostExe -NoProfile -File (Join-Path $PSScriptRoot 'Test-BundleShared.ps1') -EngineDll (Join-Path $root 'rime.dll') -SharedData $shared -SchemeSource $SchemeSource -OutputDirectory (Join-Path $out 'shared-x64')
if($LASTEXITCODE){throw 'Installed shared N01 validation failed'}
Check 'Installed shared N01 input and learning passed' ((Get-Content -LiteralPath (Join-Path $out 'shared-x64/result.json') -Raw|ConvertFrom-Json).passed)
& "$env:WINDIR/SysWOW64/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Test-BundleShared.ps1') -EngineDll (Join-Path $package 'stage/output/Win32/rime.dll') -SharedData $shared -SchemeSource $SchemeSource -OutputDirectory (Join-Path $out 'shared-win32')
if($LASTEXITCODE){throw 'Bundled Win32 R5 shared validation failed'}
Check 'Bundled Win32 R5 shared input and learning passed' ((Get-Content -LiteralPath (Join-Path $out 'shared-win32/result.json') -Raw|ConvertFrom-Json).passed)
$fixture=Join-Path $PSScriptRoot '../key-pairing/fixture'
foreach($name in @('gui_test.schema.yaml','b01_public_fixture.dict.yaml')){Copy-Item -LiteralPath (Join-Path $fixture $name) -Destination $user}
$schema=Join-Path $user 'gui_test.schema.yaml'
[IO.File]::WriteAllText($schema,([IO.File]::ReadAllText($schema)).Replace('enable_user_dict: false','enable_user_dict: true'))
[IO.File]::WriteAllText((Join-Path $user 'default.custom.yaml'),"patch:`n  schema_list:`n    - schema: gui_test`n")
[IO.File]::WriteAllText((Join-Path $user 'rime.lua'),'-- synthetic preserved user entry')
$null=New-Item -ItemType Directory -Path (Join-Path $user 'lua') -Force
[IO.File]::WriteAllText((Join-Path $user 'lua/select_hanzi.lua'),'return {} -- synthetic preserved user override')
Run (Join-Path $root 'StellaeDeployer.exe') '/deploy'
& python (Join-Path $PSScriptRoot 'Probe-InstalledEngine.py') --engine (Join-Path $root 'rime.dll') --header $api --shared $shared --user $user --report (Join-Path $out 'synthetic-before-upgrade.json')
if($LASTEXITCODE){throw 'Synthetic pre-upgrade input failed'}
& python (Join-Path $PSScriptRoot 'Export-SyntheticLearning.py') --engine (Join-Path $root 'rime.dll') --header $api --shared $shared --user $user --output (Join-Path $out 'learning-before.tsv')
if($LASTEXITCODE){throw 'Synthetic learning export failed'}
$protected=@{}
foreach($name in @('default.custom.yaml','weasel.custom.yaml','rime.lua','lua/select_hanzi.lua','bare-user-sentinel.txt')){$protected[$name]=(Get-FileHash -LiteralPath (Join-Path $user $name)).Hash}
$modified=Join-Path $shared 'lua/select_hanzi.lua'
Add-Content -LiteralPath $modified -Value '-- synthetic local shared modification'
$modifiedHash=(Get-FileHash -LiteralPath $modified).Hash
$null=New-Item -ItemType Directory -Path (Join-Path $shared 'unmanaged') -Force
[IO.File]::WriteAllText((Join-Path $shared 'unmanaged/keep.txt'),'synthetic unknown shared source')
Run $installer '/S'
Stop-Stellae $root
foreach($name in $protected.Keys){Check ('Upgrade preserves user source '+$name) ((Get-FileHash -LiteralPath (Join-Path $user $name)).Hash -ceq $protected[$name])}
Check 'Upgrade preserves modified shared source' ((Get-FileHash -LiteralPath $modified).Hash -ceq $modifiedHash)
Check 'Upgrade preserves unknown shared nested source' (Test-Path -LiteralPath (Join-Path $shared 'unmanaged/keep.txt'))
$status=Get-Content -LiteralPath (Join-Path $root 'scheme-status.json') -Raw|ConvertFrom-Json
Check 'Upgrade reports user entry and Lua overrides' ('rime.lua' -in $status.userOverrides -and 'lua/select_hanzi.lua' -in $status.userOverrides)
Check 'Upgrade reports modified shared source' ('lua/select_hanzi.lua' -in $status.sharedConflicts)
& python (Join-Path $PSScriptRoot 'Export-SyntheticLearning.py') --engine (Join-Path $root 'rime.dll') --header $api --shared $shared --user $user --output (Join-Path $out 'learning-after.tsv')
if($LASTEXITCODE){throw 'Post-upgrade synthetic export failed'}
$beforeLearning=(Get-Content -LiteralPath (Join-Path $out 'learning-before.json') -Raw|ConvertFrom-Json).records
$afterLearning=(Get-Content -LiteralPath (Join-Path $out 'learning-after.json') -Raw|ConvertFrom-Json).records
Check 'Upgrade preserves semantic synthetic learning values' (($beforeLearning|ConvertTo-Json -Compress) -ceq ($afterLearning|ConvertTo-Json -Compress))
& python (Join-Path $PSScriptRoot 'Probe-InstalledEngine.py') --engine (Join-Path $root 'rime.dll') --header $api --shared $shared --user $user --report (Join-Path $out 'synthetic-after-upgrade.json')
if($LASTEXITCODE){throw 'Post-upgrade synthetic input failed'}
$policyDirectory=Join-Path $env:RUNNER_TEMP 'profile-policy'
$null=New-Item -ItemType Directory -Path $policyDirectory -Force
$policyState=Join-Path $policyDirectory 'initial-restore-state.json'
$policyHelper=Join-Path $PSScriptRoot '../../../installer/InstallProfilePolicy.ps1'
$windowsPowerShell=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
& $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $policyHelper -Action Capture -StateFile $policyState
if($LASTEXITCODE){throw 'Could not capture the initial input state for policy fixtures'}
try{
  & $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'Test-Win11EquivalentPolicy.ps1') -HelperFile $policyHelper -SnapshotFile (Join-Path $PSScriptRoot 'NativeProfileSnapshot.ps1') -OutputDirectory $policyDirectory
  if($LASTEXITCODE){throw 'Windows input-profile policy validation failed'}
  $policyReport=Get-Content -LiteralPath (Join-Path $policyDirectory 'win11-equivalent-policy-result.json') -Raw|ConvertFrom-Json
  Check 'Windows input-profile policy assertions passed before uninstall' ([bool]$policyReport.Passed)
}finally{
  & $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $policyHelper -Action Finalize -StateFile $policyState
  if($LASTEXITCODE){throw 'Could not restore the initial input state after policy fixtures'}
}
$policyBefore=(Get-Content -LiteralPath $policyState -Raw|ConvertFrom-Json).Before
$policyAfter=Snapshot 'after-policy-restoration'
$beforeIds=@($policyBefore.Enabled.Id|ForEach-Object {$_.ToUpperInvariant()}|Sort-Object -Unique)
$afterIds=@($policyAfter.Enabled.Id|ForEach-Object {$_.ToUpperInvariant()}|Sort-Object -Unique)
Check 'Policy fixtures restore the initial enabled input profiles' (@(Compare-Object $beforeIds $afterIds).Count -eq 0)
Run (Join-Path $root 'uninstall.exe') ('/S _?='+$root)
Check 'Uninstall preserves modified shared source' ((Get-FileHash -LiteralPath $modified).Hash -ceq $modifiedHash)
Check 'Uninstall preserves unknown shared nested source' (Test-Path -LiteralPath (Join-Path $shared 'unmanaged/keep.txt'))
Check 'Uninstall preserves modified shared source from bare installation' ((Get-FileHash -LiteralPath (Join-Path $shared 'symbols.yaml')).Hash -ceq $bareSymbolsHash)
Check 'Uninstall preserves unknown nested source from bare installation' (Test-Path -LiteralPath (Join-Path $shared 'unmanaged/bare-keep.txt'))
Check 'Uninstall removes unchanged managed nested source' (-not (Test-Path -LiteralPath (Join-Path $shared 'lua/jp_query.lua')))
foreach($name in $protected.Keys){Check ('Uninstall preserves user source '+$name) ((Get-FileHash -LiteralPath (Join-Path $user $name)).Hash -ceq $protected[$name])}
Check 'Uninstall preserves synthetic learning database' (@(Get-ChildItem -LiteralPath $user -Directory|Where-Object {$_.Name -like '*.userdb'}).Count -gt 0)
Check 'Official frontend source and service preserved' ((Get-FileHash -LiteralPath (Join-Path $officialRoot 'WeaselServer.exe')).Hash -ceq $officialHash -and (($officialPids -join ',') -ceq ((@(Get-Process WeaselServer -ErrorAction SilentlyContinue|Select-Object -ExpandProperty Id|Sort-Object)) -join ',')))
[ordered]@{passed=$true;bundleVersion=$inputs.bundleVersion;frontendVersion=$inputs.frontendVersion;physicalKeyboardTested=$false;actualWindows11Tested=$false;checks=$checks}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $out 'result.json') -Encoding UTF8
