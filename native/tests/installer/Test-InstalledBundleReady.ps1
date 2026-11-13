# SPDX-License-Identifier: GPL-3.0-only
param(
  [Parameter(Mandatory)][string]$EngineDll,
  [Parameter(Mandatory)][string]$SharedData,
  [Parameter(Mandatory)][string]$UserData,
  [Parameter(Mandatory)][string]$SchemeSource,
  [Parameter(Mandatory)][string]$OutputDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true'){throw 'Use a disposable hosted runner'}
$user=[IO.Path]::GetFullPath($UserData)
$expected=[IO.Path]::GetFullPath((Join-Path $env:APPDATA 'RimeStellae'))
if($user -ine $expected){throw 'Probe only the actual synthetic installation profile'}
if(Test-Path -LiteralPath $OutputDirectory){throw 'Use a new fixture result directory'}
$null=New-Item -ItemType Directory -Path $OutputDirectory
$out=[IO.Path]::GetFullPath($OutputDirectory)
$engine=[IO.Path]::GetFullPath($EngineDll)
$shared=[IO.Path]::GetFullPath($SharedData)
$report=[ordered]@{passed=$false;actualInstalledUser=$true;deploymentInvoked=$false;physicalKeyboardTested=$false;checks=@()}
$initialized=$false
$session=[UIntPtr]::Zero
$compiled=@{}
function Check([string]$Name,[bool]$Passed){
  $report.checks+=@([ordered]@{name=$Name;passed=$Passed})
  if(-not $Passed){throw ('Installed bundle readiness failed: '+$Name)}
}
function Query([string]$Raw){
  [RimeProbe]::RimeClearComposition($session)
  foreach($character in $Raw.ToCharArray()){
    $mask=if([char]::IsUpper($character)){1}else{0}
    [RimeProbe]::RimeProcessKey($session,[int]$character,$mask)|Out-Null
    [RimeProbe]::RimeProcessKey($session,[int]$character,($mask -bor 0x40000000))|Out-Null
  }
  return [RimeProbe]::Snapshot($session,250)
}
try{
  foreach($name in @('default.yaml','pc_research.schema.yaml','jp_sela.schema.yaml')){
    $path=Join-Path $user ('build/'+$name)
    Check ('installer-compiled-'+$name) (Test-Path -LiteralPath $path -PathType Leaf)
    $compiled[$name]=@{hash=(Get-FileHash -LiteralPath $path).Hash;written=(Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks}
    if($name -ne 'default.yaml'){
      $text=[IO.File]::ReadAllText($path)
      Check ('installer-complete-'+$name) ($text -match '(?m)^engine:' -and $text -match '(?m)^speller:')
    }
  }
  $defaults=[IO.File]::ReadAllText((Join-Path $user 'build/default.yaml'))
  Check 'installer-default-Chinese-entry' ($defaults -match '(?m)^\s*-\s*schema:\s*pc_research\s*$')
  Check 'installer-default-Japanese-entry' ($defaults -match '(?m)^\s*-\s*schema:\s*jp_sela\s*$')
  $api=Get-Content -LiteralPath (Join-Path $SchemeSource 'tests/RimeProbe.cs') -Raw
  Add-Type -TypeDefinition $api.Replace('__RIME_ENGINE_DLL__',$engine)
  $env:PATH=(Split-Path $engine)+';'+$env:PATH
  $traits=New-Object RimeProbe+Traits
  $traits.data_size=[Runtime.InteropServices.Marshal]::SizeOf($traits)-4
  $traits.shared_data_dir=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($shared)
  $traits.user_data_dir=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($user)
  $traits.prebuilt_data_dir=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi((Join-Path $user 'build'))
  $traits.staging_dir=$traits.prebuilt_data_dir
  $traits.log_dir=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($out)
  $traits.app_name=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi('rime.installed_bundle_ready')
  $traits.min_log_level=2
  [RimeProbe]::RimeSetup([ref]$traits)
  [RimeProbe]::RimeInitialize([ref]$traits)
  $initialized=$true
  # No deployer initialization or deployment call is made in this probe.
  $session=[RimeProbe]::RimeCreateSession()
  Check 'installed-session-created' ($session -ne [UIntPtr]::Zero)
  $buffer=New-Object byte[] 256
  Check 'installed-initial-Chinese-schema' ([bool][RimeProbe]::RimeGetCurrentSchema($session,$buffer,[UIntPtr]::new([uint32]256)) -and [Text.Encoding]::UTF8.GetString($buffer).Trim([char]0) -ceq 'pc_research')
  Check 'installed-initial-SC-output' ([RimeProbe]::RimeGetOption($session,'simplification') -eq 1)
  $state=Query 'nihao'
  $helloChinese=([string][char]0x4f60)+[char]0x597d
  Check 'installed-Chinese-candidate' ($state.Candidates -ccontains $helloChinese)
  [RimeProbe]::RimeClearComposition($session)
  [RimeProbe]::RimeSetOption($session,'research_english',1)
  $state=Query 'hello'
  Check 'installed-English-candidate' ($state.Candidates -ccontains 'hello')
  [RimeProbe]::RimeClearComposition($session)
  [RimeProbe]::RimeSetOption($session,'research_english',0)
  Check 'installed-Japanese-schema-selectable' ([bool][RimeProbe]::RimeSelectSchema($session,'jp_sela'))
  [RimeProbe]::RimeSetOption($session,'probe_options_ready',1)
  $state=Query 'qtaberu'
  $eatJapanese=([string][char]0x98df)+[char]0x3079+[char]0x308b
  Check 'installed-Japanese-candidate' ($state.Candidates -ccontains $eatJapanese)
  foreach($name in $compiled.Keys){
    $path=Join-Path $user ('build/'+$name)
    Check ('compiled-artifact-not-rewritten-'+$name) ((Get-FileHash -LiteralPath $path).Hash -ceq $compiled[$name].hash -and (Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks -eq $compiled[$name].written)
  }
  $report.passed=$true
}finally{
  if($session -ne [UIntPtr]::Zero){
    [RimeProbe]::RimeClearComposition($session)
    [RimeProbe]::RimeSelectSchema($session,'pc_research')|Out-Null
    [RimeProbe]::RimeDestroySession($session)|Out-Null
  }
  if($initialized){[RimeProbe]::RimeFinalize()}
  $report|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $out 'result.json') -Encoding UTF8
}
Write-Output ('PASS actual installed profile readiness: '+$report.checks.Count)
