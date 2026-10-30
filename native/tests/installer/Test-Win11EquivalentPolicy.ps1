#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$HelperFile,
  [Parameter(Mandatory)][string]$SnapshotFile,
  [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or -not [Environment]::Is64BitProcess -or $PSVersionTable.PSEdition -ne 'Desktop'){throw 'Run only in Windows PowerShell 5.1 on a disposable x64 GitHub Windows runner'}
$HelperFile=(Resolve-Path -LiteralPath $HelperFile).Path
$SnapshotFile=(Resolve-Path -LiteralPath $SnapshotFile).Path
$null=New-Item -ItemType Directory -Path $OutputDirectory -Force
$OutputDirectory=(Resolve-Path -LiteralPath $OutputDirectory).Path
$powershell=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$clsid='{0230F8DE-23D2-4E61-B45B-B6DB84E71145}'
$selected='0C04:{0230F8DE-23D2-4E61-B45B-B6DB84E71145}{73E8015B-B517-45EE-8584-38C01CEDD224}'
$fallbacks=@('0C04:00000409','0C04:00000C04')
$report=[ordered]@{Passed=$false;Scope='Real Windows APIs reproduce the observed Win11 wrong-group plus two added-layout fields on a disposable runner; not an actual Win11 OS claim';PowerShellVersion=[string]$PSVersionTable.PSVersion;Checks=@();Cases=@();Error=$null}

if(-not ('StellaeWin11PolicyFixture.Layouts' -as [type])) {
  Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
namespace StellaeWin11PolicyFixture {
  public static class Layouts {
    [DllImport("input.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool InstallLayoutOrTip(string profile, uint flags);
  }
}
'@
}

function Check([string]$Name,[bool]$Condition,$Detail=$null) {
  $report.Checks+=@([ordered]@{Name=$Name;Passed=$Condition;Detail=$Detail})
  if(-not $Condition){throw "Check failed: $Name"}
  Write-Host "PASS $Name"
}
function Invoke-Child([string]$Script,[string]$Arguments) {
  $command='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$Script+'" '+$Arguments
  $p=Start-Process -FilePath $powershell -ArgumentList $command -PassThru -WindowStyle Hidden
  try {
    if(-not $p.WaitForExit(60000)){throw 'Fixture child process timed out'}
    if($p.ExitCode -ne 0){throw "Fixture child failed: $Script ($($p.ExitCode))"}
  } finally {$p.Dispose()}
}
function Read-Snapshot([string]$Stage) {
  $file=Join-Path $OutputDirectory ($Stage+'.json')
  Invoke-Child $SnapshotFile ('-OutputFile "'+$file+'"')
  Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
}
function Invoke-Policy([string]$Action,[string]$StateFile) {
  Invoke-Child $HelperFile ('-Action '+$Action+' -StateFile "'+$StateFile+'" -Hant 1')
}
function Ids($Snapshot) {
  @($Snapshot.Enabled | ForEach-Object {$_.Id.ToUpperInvariant()} | Sort-Object -Unique)
}
function ForeignPairs($Snapshot) {
  @(foreach($language in $Snapshot.Languages) {
    foreach($tip in $language.Tips) {
      if($tip -notmatch [regex]::Escape($clsid)){([string]$language.LanguageTag)+'|'+([string]$tip).ToUpperInvariant()}
    }
  })
}
function Set-FixtureLanguages($Before,[switch]$WrongGroup,[switch]$AddExistingHkUs) {
  $rows=[Collections.Generic.List[object]]::new()
  foreach($language in $Before.Languages) {
    $tips=@($language.Tips | Where-Object {$_ -notmatch [regex]::Escape($clsid)})
    if($tips.Count){$rows.Add([pscustomobject]@{Tag=[string]$language.LanguageTag;Tips=$tips;Spellchecking=[bool]$language.Spellchecking;Handwriting=[bool]$language.Handwriting})}
  }
  $tag=if($WrongGroup){'zh-Hant-TW'}else{'zh-Hant-HK'}
  $target=@($rows | Where-Object {$_.Tag -eq $tag})
  if($target.Count){$target[0].Tips=@($target[0].Tips)+@($selected)}
  else {$rows.Add([pscustomobject]@{Tag=$tag;Tips=@($selected);Spellchecking=$true;Handwriting=$true})}
  if($AddExistingHkUs) {
    $hk=@($rows | Where-Object {$_.Tag -eq 'zh-Hant-HK'})
    if($hk.Count){$hk[0].Tips=@($hk[0].Tips)+@($fallbacks[0])}
    else {$rows.Add([pscustomobject]@{Tag='zh-Hant-HK';Tips=@($fallbacks[0]);Spellchecking=$true;Handwriting=$true})}
  }
  $list=New-WinUserLanguageList $rows[0].Tag
  for($i=1;$i -lt $rows.Count;$i++){$list.Add($rows[$i].Tag)}
  for($i=0;$i -lt $rows.Count;$i++) {
    $list[$i].InputMethodTips.Clear()
    foreach($tip in $rows[$i].Tips){$list[$i].InputMethodTips.Add([string]$tip)}
    $list[$i].Spellchecking=$rows[$i].Spellchecking
    $list[$i].Handwriting=$rows[$i].Handwriting
  }
  Set-WinUserLanguageList -LanguageList $list -Force
}

try {
  $initial=Read-Snapshot 'initial-correct-state'
  Check 'Initial selected HK TIP is enabled' ($selected -in @(Ids $initial))
  Check 'Initial HK group contains selected TIP' (@($initial.Languages | Where-Object {$_.LanguageTag -in @('zh-Hant-HK','zh-HK') -and $selected -in $_.Tips}).Count -gt 0)
  Check 'Fresh fixture has neither added fallback' (@($fallbacks | Where-Object {$_ -in @(Ids $initial)}).Count -eq 0)
  foreach($name in @('both-fallbacks-new','preexisting-HK-US-preserved')) {
    if($name -eq 'preexisting-HK-US-preserved') {
      Set-FixtureLanguages $initial -AddExistingHkUs
      if(-not [StellaeWin11PolicyFixture.Layouts]::InstallLayoutOrTip($fallbacks[0],0)){throw 'Could not establish the existing HK-US fixture'}
    }
    $before=Read-Snapshot ($name+'-before')
    if($name -eq 'preexisting-HK-US-preserved') {
      Check "$name HK-US exists before capture" ($fallbacks[0] -in @(Ids $before))
      Check "$name native HK layout is not preexisting" ($fallbacks[1] -notin @(Ids $before))
    }
    $stateFile=Join-Path $OutputDirectory ($name+'-policy-state.json')
    Invoke-Policy 'Capture' $stateFile
    Set-FixtureLanguages $before -WrongGroup
    foreach($id in $fallbacks) {
      if(-not [StellaeWin11PolicyFixture.Layouts]::InstallLayoutOrTip($id,0)){throw "Could not establish the observed layout fixture: $id"}
    }
    $wrong=Read-Snapshot ($name+'-emulated-Win11-state')
    $wrongGroupReached=(@($wrong.Languages | Where-Object {$_.LanguageTag -in @('zh-Hant-TW','zh-TW') -and $selected -in $_.Tips}).Count -gt 0)
    $requireWrongGroup=($name -eq 'both-fallbacks-new')
    # Case A covers repair of the observed wrong group. With a preexisting
    # HK-US keyboard, Windows may keep the selected TIP in HK by itself.
    # Case B covers protection of that keyboard and removal of the new one.
    if($requireWrongGroup){Check "$name wrong group reached" $wrongGroupReached}
    Check "$name two native fallbacks reached" (@($fallbacks | Where-Object {$_ -notin @(Ids $wrong)}).Count -eq 0)
    Invoke-Policy 'Finalize' $stateFile
    $after=Read-Snapshot ($name+'-after')
    $expected=@(Ids $before)
    $actual=@(Ids $after)
    $missing=@($expected | Where-Object {$_ -notin $actual})
    $extra=@($actual | Where-Object {$_ -notin $expected})
    Check "$name exact enabled profiles restored" ($missing.Count -eq 0 -and $extra.Count -eq 0) ([ordered]@{Missing=$missing;Extra=$extra})
    $foreignAfter=@(ForeignPairs $after)
    $missingPairs=@(ForeignPairs $before | Where-Object {$_ -notin $foreignAfter})
    Check "$name original other-language groups retained" ($missingPairs.Count -eq 0) $missingPairs
    Check "$name selected HK group repaired" (@($after.Languages | Where-Object {$_.LanguageTag -in @('zh-Hant-HK','zh-HK') -and $selected -in $_.Tips}).Count -gt 0)
    $report.Cases+=@([ordered]@{Name=$name;WrongGroupRequired=$requireWrongGroup;WrongGroupObserved=$wrongGroupReached;Before=$before;Emulated=$wrong;After=$after;Passed=$true})
  }
  $report.Passed=$true
} catch {$report.Error=$_.ToString();throw}
finally {$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $OutputDirectory 'win11-equivalent-policy-result.json') -Encoding UTF8}
