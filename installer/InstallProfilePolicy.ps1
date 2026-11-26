#Requires -Version 5.1
[CmdletBinding()]
param(
  [Parameter(Mandatory)][ValidateSet('Capture','Finalize')][string]$Action,
  [Parameter(Mandatory)][string]$StateFile,
  [ValidateRange(-1,1)][int]$Hant=-1
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
trap {
  if($env:GITHUB_ACTIONS -eq 'true' -and $env:STELLAE_INSTALLER_POLICY_TRACE -eq '1' -and $env:GITHUB_WORKSPACE){
    $folder=Join-Path $env:GITHUB_WORKSPACE 'policy-diagnostics'
    $null=New-Item -ItemType Directory -Path $folder -Force
    [ordered]@{Action=$Action;Error=$_.Exception.Message;Position=$_.InvocationInfo.PositionMessage;ExceptionType=$_.Exception.GetType().FullName}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $folder ($Action+'-error.json')) -Encoding UTF8
  }
  break
}
. (Join-Path $PSScriptRoot 'NativeProfileSnapshot.ps1') -LibraryOnly
$ownClass='{0230F8DE-23D2-4E61-B45B-B6DB84E71145}'
$ownProfile='{73E8015B-B517-45EE-8584-38C01CEDD224}'
function Read-KeyboardValues([string]$Subkey) {
  $key=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Keyboard Layout\'+$Subkey)
  $rows=@()
  if($key){try{$rows=@(foreach($name in $key.GetValueNames()){[ordered]@{Name=$name;Value=[string]$key.GetValue($name) }})}finally{$key.Dispose()}}
  return $rows
}
function Get-DefaultTip {
  $override=Get-WinDefaultInputMethodOverride
  if($override){return [string]$override.InputMethodTip}
  return ''
}
function Test-SameLanguageList($Wanted,$Actual) {
  if($Wanted.Count -ne $Actual.Count){return $false}
  for($index=0;$index -lt $Wanted.Count;$index++){
    $entry=$Wanted[$index];$other=$Actual[$index]
    if($entry.LanguageTag -ne $other.LanguageTag -or
       ($entry.InputMethodTips -join ';') -ne ($other.InputMethodTips -join ';') -or
       $entry.Spellchecking -ne $other.Spellchecking -or $entry.Handwriting -ne $other.Handwriting){return $false}
  }
  return $true
}
if($Action -eq 'Capture') {
  [ordered]@{
    SchemaVersion=1;Before=(Get-StellaeNativeProfileSnapshot);DefaultTip=(Get-DefaultTip)
    Preload=@(Read-KeyboardValues 'Preload');Substitutes=@(Read-KeyboardValues 'Substitutes')
  }|ConvertTo-Json -Depth 12|Set-Content -LiteralPath $StateFile -Encoding UTF8
  exit 0
}
$state=Get-Content -LiteralPath $StateFile -Raw|ConvertFrom-Json
if($Hant -lt 0) {
  $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,[Microsoft.Win32.RegistryView]::Registry32)
  try{$key=$base.OpenSubKey('Software\RimeStellae');if(-not $key){throw 'The installed Stellae preference is missing'};try{$Hant=[int]$key.GetValue('Hant',-1)}finally{$key.Dispose()}}finally{$base.Dispose()}
}
if($Hant -notin @(0,1)){throw 'The installed Stellae profile is unknown'}
$lang=if($Hant){'0C04'}else{'0804'}
$tag=if($Hant){'zh-Hant-HK'}else{'zh-Hans-CN'}
$aliases=if($Hant){@('zh-Hant-HK','zh-HK')}else{@('zh-Hans-CN','zh-CN')}
$selected=$lang+':'+$ownClass+$ownProfile
$before=$state.Before
$desired=New-WinUserLanguageList 'en-US'
$desired.Clear()
$target=$null
foreach($row in @($before.Languages)) {
  $entryList=New-WinUserLanguageList $row.LanguageTag
  $entry=$entryList[0]
  $entry.InputMethodTips.Clear()
  $targetGroup=$entry.LanguageTag -in $aliases -and $null -eq $target
  if($targetGroup){$target=$entry}
  foreach($tip in $row.Tips){
    if($tip -notmatch [regex]::Escape($ownClass)){$entry.InputMethodTips.Add([string]$tip)}
    elseif($targetGroup -and $selected -notin $entry.InputMethodTips){$entry.InputMethodTips.Add($selected)}
  }
  # Drop only a former group made empty by moving this product's own TIP.
  if($row.Tips.Count -gt 0 -and $entry.InputMethodTips.Count -eq 0){continue}
  $entry.Spellchecking=[bool]$row.Spellchecking
  $entry.Handwriting=[bool]$row.Handwriting
  $desired.Add($entry)
}
if(-not $target){
  $entryList=New-WinUserLanguageList $tag
  $target=$entryList[0]
  $target.InputMethodTips.Clear()
  $desired.Add($target)
}
if($selected -notin $target.InputMethodTips){$target.InputMethodTips.Add($selected)}
if(-not (Test-SameLanguageList $desired (Get-WinUserLanguageList))){
  Set-WinUserLanguageList -LanguageList $desired -Force
}
$defaultTip=if($state.DefaultTip -match [regex]::Escape($ownClass)){$selected}else{[string]$state.DefaultTip}
if($defaultTip -ne (Get-DefaultTip)){
  if($defaultTip){Set-WinDefaultInputMethodOverride -InputTip $defaultTip}
  else{Set-WinDefaultInputMethodOverride}
}
if(-not ('StellaeInstallerPolicy.Native' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace StellaeInstallerPolicy {
  public static class Native {
    [DllImport("input.dll",CharSet=CharSet.Unicode,ExactSpelling=true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    [return:MarshalAs(UnmanagedType.Bool)]
    public static extern bool InstallLayoutOrTip(string id,uint flags);
    [DllImport("user32.dll")]
    [return:MarshalAs(UnmanagedType.Bool)]
    public static extern bool UnloadKeyboardLayout(IntPtr layout);
  }
}
'@
}
$expected=@($before.Enabled|Where-Object {$_.Id -notmatch [regex]::Escape($ownClass)}|ForEach-Object {$_.Id})+@($selected)
$affectedLanguages=@(@($lang)+@($before.Enabled|Where-Object {$_.Id -match [regex]::Escape($ownClass)}|ForEach-Object {$_.Language})|Sort-Object -Unique)
$current=Get-StellaeNativeProfileSnapshot
foreach($tip in $expected){
  if($tip -notin @($current.Enabled.Id) -and -not [StellaeInstallerPolicy.Native]::InstallLayoutOrTip($tip,0)){throw "Could not preserve input profile: $tip"}
}
$current=Get-StellaeNativeProfileSnapshot
$disabled=@()
foreach($row in @($current.Enabled|Where-Object {$_.Id -notin $expected})) {
  $rowLanguage=[string]$row.Language
  if($row.Type -eq 1 -and $rowLanguage -in @('0404','0804','0C04') -and $row.Id -eq ($rowLanguage+':'+$ownClass+$ownProfile)){
    if(-not [StellaeInstallerPolicy.Native]::InstallLayoutOrTip($row.Id,1)){throw "Could not remove the previous Stellae input profile: $($row.Id)"}
    continue
  }
  $match=[regex]::Match($row.Id,('^'+$rowLanguage+':(0000[0-9A-Fa-f]{4})$'),[Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if($row.Type -ne 2 -or $rowLanguage -notin $affectedLanguages -or -not $match.Success){continue}
  $klid=$match.Groups[1].Value
  $layout=([uint64][Convert]::ToUInt32($klid,16) -shl 16) -bor [uint64][Convert]::ToUInt32($rowLanguage,16)
  $dependent=@($current.Dependencies|Where-Object {([Convert]::ToUInt64($_.Layout,16) -band [uint64]4294967295) -eq $layout})
  if(-not $current.QueriesComplete -or $dependent.Count){throw "A newly added layout has an unresolved dependency: $($row.Id)"}
  if(-not [StellaeInstallerPolicy.Native]::InstallLayoutOrTip($row.Id,0x80)){throw "Could not disable new fallback layout: $($row.Id)"}
  # Windows 11 can also leave a new language-to-layout alias in Preload.
  # Remove only an alias absent in the capture and matching this new layout.
  $alias=('0000'+$rowLanguage).ToLowerInvariant()
  if(-not @($state.Substitutes|Where-Object {$_.Name -eq $alias}).Count) {
    $sub=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Keyboard Layout\Substitutes',$true)
    $pre=[Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Keyboard Layout\Preload',$true)
    try{
      if($sub -and [string]$sub.GetValue($alias) -eq $klid) {
        if($pre){foreach($name in $pre.GetValueNames()){
          if([string]$pre.GetValue($name) -eq $alias -and -not @($state.Preload|Where-Object {$_.Value -eq $alias}).Count){$pre.DeleteValue($name)}
        }}
        $sub.DeleteValue($alias)
      }
    }finally{if($pre){$pre.Dispose()};if($sub){$sub.Dispose()}}
  }
  $null=[StellaeInstallerPolicy.Native]::UnloadKeyboardLayout([IntPtr]::new([long]$layout))
  $disabled+=$row.Id
}
$after=Get-StellaeNativeProfileSnapshot
$actual=@($after.Enabled.Id)
$missing=@($expected|Where-Object {$_ -notin $actual})
$extra=@($actual|Where-Object {$_ -notin $expected})
if($missing.Count -or $extra.Count){throw "Input profiles differ. Missing=[$($missing -join ', ')] Extra=[$($extra -join ', ')]"}
if(-not (Test-SameLanguageList $desired (Get-WinUserLanguageList))){throw 'Windows language options or input group placement were not retained'}
[ordered]@{Passed=$true;SelectedTip=$selected;DisabledNewLayouts=$disabled;After=$after}|ConvertTo-Json -Depth 12|Set-Content -LiteralPath ($StateFile+'.result.json') -Encoding UTF8
