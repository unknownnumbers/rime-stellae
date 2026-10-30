# SPDX-License-Identifier: GPL-3.0-only
#Requires -Version 7.2
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$OfficialInstaller,
  [Parameter(Mandatory)][string]$StellaeInstaller,
  [Parameter(Mandatory)][string]$OutputDirectory,
  [Parameter(Mandatory)][string]$ApiHeader,
  [switch]$ObserveOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or -not [Environment]::Is64BitProcess){throw 'Only run on the disposable x64 hosted Windows runner'}
$principal=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'The cloud runner must be elevated'}
$OfficialInstaller=(Resolve-Path -LiteralPath $OfficialInstaller).Path
$StellaeInstaller=(Resolve-Path -LiteralPath $StellaeInstaller).Path
$null=New-Item -ItemType Directory -Path $OutputDirectory -Force
$OutputDirectory=(Resolve-Path -LiteralPath $OutputDirectory).Path
$report=[ordered]@{Passed=$false;Scope='Finite before/after native profiles and Windows language groups: fresh HK, same HK upgrade, saved SC and TC override; no host composition claim';Checks=[Collections.Generic.List[object]]::new();Processes=[Collections.Generic.List[object]]::new()}
$report['ProfileSnapshots']=[Collections.Generic.List[object]]::new()
$report['ProfilePolicyPassed']=$true
$stellaeKey='Software\RimeStellae'
$weaselKey='Software\Rime\Weasel'
$clsid='{0230F8DE-23D2-4E61-B45B-B6DB84E71145}'
$profile='{73E8015B-B517-45EE-8584-38C01CEDD224}'
$officialClsid='{A3F4CDED-B1E9-41EE-9CA6-7B4D0DE6CB0A}'
$officialProfile='{3D02CAB6-2B8E-4781-BA20-1C9267529467}'
function Check([string]$Name,[bool]$Condition,$Detail=$null){
  $report.Checks.Add([ordered]@{Name=$Name;Passed=$Condition;Detail=$Detail})
  if(-not $Condition){throw "Check failed: $Name"}
  Write-Host "PASS $Name"
}
function Run([string]$File,[string]$Arguments,[string]$Stage){
  $isStellae=($File -ieq $StellaeInstaller -or [IO.Path]::GetFileName($File) -ieq 'StellaeSetup.exe')
  if($isStellae){$before=Read-ProfileSnapshot "$Stage-before"}
  $p=Start-Process -FilePath $File -ArgumentList $Arguments -PassThru -WindowStyle Hidden
  try{
    if(-not $p.WaitForExit(300000)){throw "Process timeout: $Stage"}
    $report.Processes.Add([ordered]@{Stage=$Stage;Exit=$p.ExitCode})
    if($p.ExitCode -notin @(0,3010)){throw "Process failed: $Stage / $($p.ExitCode)"}
    if($isStellae){
      $after=Read-ProfileSnapshot "$Stage-after"
      $hant=[int](Reg CurrentUser Registry32 $stellaeKey 'Hant')
      $policy=Compare-ProfileSnapshot $before $after $hant $Stage
      $report.ProfileSnapshots.Add($policy)
      if(-not $policy.Passed){$report.ProfilePolicyPassed=$false}
      if(-not $ObserveOnly){Check "$Stage profile additions and preservation" $policy.Passed $policy}
    }
  }finally{$p.Dispose()}
}
function Read-ProfileSnapshot([string]$Stage){
  $path=Join-Path $OutputDirectory ($Stage+'.json')
  # The Windows International module requires the Windows PowerShell host.
  $hostExe=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
  & $hostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File (Join-Path $PSScriptRoot 'NativeProfileSnapshot.ps1') -OutputFile $path | Out-Null
  if($LASTEXITCODE){throw "Native Windows profile snapshot failed: $Stage"}
  return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}
function Compare-ProfileSnapshot($Before,$After,[int]$Hant,[string]$Stage){
  $selected=('{0}:{1}{2}' -f $(if($Hant){'0C04'}else{'0804'}),$clsid,$profile).ToUpperInvariant()
  $foreignNative=@($Before.Enabled | Where-Object {$_.Id -notmatch [regex]::Escape($clsid)} | ForEach-Object {$_.Id.ToUpperInvariant()} | Sort-Object -Unique)
  $expected=@($foreignNative)+@($selected)
  $native=@($After.Enabled | ForEach-Object {$_.Id.ToUpperInvariant()} | Sort-Object -Unique)
  $added=@($native | Where-Object {$_ -notin $expected})
  $missing=@($foreignNative | Where-Object {$_ -notin $native})
  $foreignListed=@($Before.Languages | ForEach-Object {$_.Tips} | Where-Object {$_ -notmatch [regex]::Escape($clsid)} | ForEach-Object {$_.ToUpperInvariant()} | Sort-Object -Unique)
  $listed=@($After.Languages | ForEach-Object {$_.Tips} | ForEach-Object {$_.ToUpperInvariant()} | Sort-Object -Unique)
  $missingListed=@($foreignListed | Where-Object {$_ -notin $listed})
  $newListed=@($listed | Where-Object {$_ -notin $foreignListed -and $_ -ne $selected})
  $missingGroups=@(foreach($row in $Before.Languages){
    foreach($tip in $row.Tips | Where-Object {$_ -notmatch [regex]::Escape($clsid)}){
      if(-not @($After.Languages | Where-Object {$_.LanguageTag -eq $row.LanguageTag -and $tip -in $_.Tips}).Count){
        $row.LanguageTag+':'+$tip
      }
    }
  })
  $targetTags=if($Hant){@('zh-Hant-HK','zh-HK')}else{@('zh-Hans-CN','zh-CN')}
  $group=@($After.Languages | Where-Object {$_.LanguageTag -in $targetTags -and $selected -in $_.Tips})
  return [ordered]@{
    Stage=$Stage;SelectedTip=$selected
    UnexpectedEnabled=$added;MissingPreviousEnabled=$missing
    UnexpectedListed=$newListed;MissingPreviousListed=$missingListed
    MissingPreviousGroups=$missingGroups
    SelectedEnabled=($selected -in $native);SelectedInRequestedGroup=($group.Count -gt 0)
    Passed=($added.Count -eq 0 -and $missing.Count -eq 0 -and $missingListed.Count -eq 0 -and $missingGroups.Count -eq 0 -and $newListed.Count -eq 0 -and $selected -in $native -and $group.Count -gt 0)
    Before=$Before;After=$After
  }
}
function Reg([string]$Hive,[string]$View,[string]$Key,[string]$Name=''){
  $b=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::$Hive,[Microsoft.Win32.RegistryView]::$View)
  try{$k=$b.OpenSubKey($Key);if(-not $k){return $null};try{return $k.GetValue($Name,$null)}finally{$k.Dispose()}}finally{$b.Dispose()}
}
function Wait-StellaeStopped {
  $deadline=[DateTime]::UtcNow.AddSeconds(10)
  while((Get-Process StellaeServer -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
  if(Get-Process StellaeServer -ErrorAction SilentlyContinue){throw 'Synthetic Stellae service did not stop before standalone engine access.'}
}
function Profile([string]$View,[string]$Class,[string]$Guid,[string]$Lang){
  $id='0x{0:x8}' -f [Convert]::ToUInt32($Lang,16)
  return Reg LocalMachine $View "Software\Microsoft\CTF\TIP\$Class\LanguageProfile\$id\$Guid" 'Enable'
}
function Assert-Stellae([string]$Stage,[int]$Hant){
  Check "$Stage saved Hant" ((Reg CurrentUser Registry32 $stellaeKey 'Hant') -eq $Hant)
  foreach($view in @('Registry32','Registry64')){
    Check "$Stage $view HK profile" ((Profile $view $clsid $profile '0C04') -eq $Hant)
    Check "$Stage $view SC profile" ((Profile $view $clsid $profile '0804') -eq (1-$Hant))
    Check "$Stage $view TSF version" ((Get-Item -LiteralPath (Reg LocalMachine $view "Software\Classes\CLSID\$clsid\InprocServer32")).VersionInfo.FileVersion -eq '0.17.4.61052')
  }
  $root=[string](Reg LocalMachine Registry32 $stellaeKey 'WeaselRoot')
  Check "$Stage independent program root" ($root -ieq (Join-Path $env:ProgramFiles 'RimeStellae')) $root
  Check "$Stage setup version" ((Get-Item -LiteralPath (Join-Path $root 'StellaeSetup.exe')).VersionInfo.FileVersion -eq '0.17.4.61052')
}
function Official-State {
  $root=[string](Reg LocalMachine Registry32 $weaselKey 'WeaselRoot')
  $files=@(foreach($path in @((Join-Path $root 'WeaselServer.exe'),(Join-Path $root 'WeaselSetup.exe'),"$env:WINDIR\System32\weasel.dll","$env:WINDIR\SysWOW64\weasel.dll")){
    [ordered]@{Path=$path;Hash=(Get-FileHash -LiteralPath $path).Hash}
  })
  return [ordered]@{Root=$root;Files=$files;Profile32=(Profile Registry32 $officialClsid $officialProfile '0804');Profile64=(Profile Registry64 $officialClsid $officialProfile '0804');ServerPids=@(Get-Process WeaselServer -ErrorAction SilentlyContinue|Sort-Object Id|Select-Object -ExpandProperty Id)}
}
try{
  Check 'Stellae starts uninstalled' ($null -eq (Reg LocalMachine Registry32 $stellaeKey 'WeaselRoot'))
  Check 'Stellae starts without saved Hant' ($null -eq (Reg CurrentUser Registry32 $stellaeKey 'Hant'))
  Run $OfficialInstaller '/S' 'official-SC-install'
  $deadline=[DateTime]::UtcNow.AddSeconds(5)
  while(-not (Get-Process WeaselServer -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 100}
  $officialBefore=Official-State
  Check 'Official SC installed in both views' ($officialBefore.Profile32 -eq 1 -and $officialBefore.Profile64 -eq 1)
  Check 'Official service is running' ($officialBefore.ServerPids.Count -gt 0)
  Run $StellaeInstaller '/S' 'fresh-default-TC-HK'
  Assert-Stellae 'fresh-default' 1
  $stellaeUser=Join-Path $env:APPDATA 'RimeStellae'
  $stellaeRoot=[string](Reg LocalMachine Registry32 $stellaeKey 'WeaselRoot')
  Check 'Fresh installed payload has no schemas or dictionaries' (@(Get-ChildItem -LiteralPath (Join-Path $stellaeRoot 'data') -Recurse -File | Where-Object {$_.Name -match '\.(schema|dict)\.yaml$|\.(gram|lua)$' -or $_.Name -eq 'essay.txt'}).Count -eq 0)
  Check 'Fresh empty default was compiled' (Test-Path -LiteralPath (Join-Path $stellaeUser 'build/default.yaml'))
  Run (Join-Path $stellaeRoot 'StellaeServer.exe') '/quit' 'empty-stop-before-C-API'
  Wait-StellaeStopped
  & python (Join-Path $PSScriptRoot 'Probe-InstalledEngine.py') --engine (Join-Path $stellaeRoot 'rime.dll') --header $ApiHeader --shared (Join-Path $stellaeRoot 'data') --user $stellaeUser --report (Join-Path $OutputDirectory 'installed-empty-engine.json') --empty
  if($LASTEXITCODE){throw 'Installed empty-scheme engine failed.'}
  Check 'Installed empty-scheme engine passed' ((Get-Content (Join-Path $OutputDirectory 'installed-empty-engine.json') -Raw|ConvertFrom-Json).passed)
  $fixture=Join-Path $PSScriptRoot '../key-pairing/fixture'
  foreach($file in @('gui_test.schema.yaml','b01_public_fixture.dict.yaml')){Copy-Item -LiteralPath (Join-Path $fixture $file) -Destination $stellaeUser}
  $schema=Join-Path $stellaeUser 'gui_test.schema.yaml'
  [IO.File]::WriteAllText($schema,[IO.File]::ReadAllText($schema).Replace('enable_user_dict: false','enable_user_dict: true'),[Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $stellaeUser 'default.custom.yaml'),"patch:`n  schema_list:`n    - schema: gui_test`n",[Text.UTF8Encoding]::new($false))
  Run (Join-Path $stellaeRoot 'StellaeDeployer.exe') '/deploy' 'post-install-synthetic-deploy'
  & python (Join-Path $PSScriptRoot 'Probe-InstalledEngine.py') --engine (Join-Path $stellaeRoot 'rime.dll') --header $ApiHeader --shared (Join-Path $stellaeRoot 'data') --user $stellaeUser --report (Join-Path $OutputDirectory 'installed-synthetic-engine.json')
  if($LASTEXITCODE){throw 'Installed post-addition synthetic scheme failed.'}
  Check 'Post-install synthetic input passed' ((Get-Content (Join-Path $OutputDirectory 'installed-synthetic-engine.json') -Raw|ConvertFrom-Json).passed)
  $protected=@('default.custom.yaml','gui_test.schema.yaml','b01_public_fixture.dict.yaml')
  $database=@(Get-ChildItem -LiteralPath $stellaeUser -Directory|Where-Object {$_.Name -like '*.userdb'}|ForEach-Object {Get-ChildItem -LiteralPath $_.FullName -File|Where-Object {$_.Name -cnotin @('LOG','LOG.old','LOCK')}})
  Check 'Synthetic learning database exists' ($database.Count -gt 0)
  & python (Join-Path $PSScriptRoot 'Export-SyntheticLearning.py') --engine (Join-Path $stellaeRoot 'rime.dll') --header $ApiHeader --shared (Join-Path $stellaeRoot 'data') --user $stellaeUser --output (Join-Path $OutputDirectory 'learning-before.tsv')
  if($LASTEXITCODE){throw 'Synthetic learning baseline export failed.'}
  $protectedBefore=@(foreach($name in $protected){[ordered]@{Name=$name;Sha256=(Get-FileHash -LiteralPath (Join-Path $stellaeUser $name)).Hash}})
  Run $StellaeInstaller '/S' 'same-HK-upgrade'
  Assert-Stellae 'same-HK-upgrade' 1
  $stellaeUser=Join-Path $env:APPDATA 'RimeStellae'
  $null=New-Item -ItemType Directory -Path $stellaeUser -Force
  $sentinel=Join-Path $stellaeUser 'installer-fixture.txt'
  [IO.File]::WriteAllText($sentinel,'public fixture retained across independent upgrades')
  # The explicit setup SC route establishes the existing user choice. /S must retain it.
  $stellaeRoot=[string](Reg LocalMachine Registry32 $stellaeKey 'WeaselRoot')
  Run (Join-Path $stellaeRoot 'StellaeSetup.exe') '/s' 'explicit-setup-SC'
  Assert-Stellae 'explicit-SC' 0
  Run $StellaeInstaller '/S' 'upgrade-preserves-SC'
  Assert-Stellae 'saved-SC' 0
  Run $StellaeInstaller '/S /T' 'explicit-TC-HK-override'
  Assert-Stellae 'explicit-TC-HK' 1
  foreach($entry in $protectedBefore){Check ('Upgrade retains synthetic config and learning: '+$entry.Name) ((Get-FileHash -LiteralPath (Join-Path $stellaeUser $entry.Name)).Hash -ceq $entry.Sha256)}
  Run (Join-Path $stellaeRoot 'StellaeServer.exe') '/quit' 'post-upgrade-stop-before-export'
  Wait-StellaeStopped
  & python (Join-Path $PSScriptRoot 'Export-SyntheticLearning.py') --engine (Join-Path $stellaeRoot 'rime.dll') --header $ApiHeader --shared (Join-Path $stellaeRoot 'data') --user $stellaeUser --output (Join-Path $OutputDirectory 'learning-after.tsv')
  if($LASTEXITCODE){throw 'Synthetic learning post-upgrade export failed.'}
  $learningBefore=(Get-Content (Join-Path $OutputDirectory 'learning-before.json') -Raw|ConvertFrom-Json).records
  $learningAfter=(Get-Content (Join-Path $OutputDirectory 'learning-after.json') -Raw|ConvertFrom-Json).records
  Check 'Upgrade retains exported synthetic learning values' (($learningBefore|ConvertTo-Json -Compress) -ceq ($learningAfter|ConvertTo-Json -Compress))
  & python (Join-Path $PSScriptRoot 'Probe-InstalledEngine.py') --engine (Join-Path $stellaeRoot 'rime.dll') --header $ApiHeader --shared (Join-Path $stellaeRoot 'data') --user $stellaeUser --report (Join-Path $OutputDirectory 'post-upgrade-synthetic-engine.json')
  if($LASTEXITCODE){throw 'Post-upgrade synthetic scheme could not reopen and input.'}
  Check 'Post-upgrade synthetic input passed' ((Get-Content (Join-Path $OutputDirectory 'post-upgrade-synthetic-engine.json') -Raw|ConvertFrom-Json).passed)
  Check 'User content retained'  (([IO.File]::ReadAllText($sentinel)) -ceq 'public fixture retained across independent upgrades')
  $officialAfter=Official-State
  Check 'Official program DLL profile and process preserved' (($officialBefore|ConvertTo-Json -Depth 8 -Compress) -ceq ($officialAfter|ConvertTo-Json -Depth 8 -Compress))
  $report.Passed=$true
  $report['ObservationOnly']=[bool]$ObserveOnly
}catch{
  $report['Error']=$_.ToString()
  throw
}finally{
  $report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $OutputDirectory 'installer-result.json') -Encoding UTF8
}
