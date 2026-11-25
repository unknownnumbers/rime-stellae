# SPDX-License-Identifier: GPL-3.0-only
param(
  [Parameter(Mandatory)][ValidateSet('Before','After')][string]$Phase,
  [Parameter(Mandatory)][string]$SchemeSource,
  [Parameter(Mandatory)][string]$OutputDirectory,
  [string]$Baseline
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or -not [Environment]::Is64BitProcess){throw 'Use a fresh hosted x64 CI installation'}
$program=Join-Path $env:ProgramFiles 'RimeStellae'
$user=Join-Path $env:APPDATA 'RimeStellae'
if(Get-Process StellaeServer -ErrorAction SilentlyContinue){throw 'Stop the synthetic frontend before native learning checks'}
if(Test-Path -LiteralPath $OutputDirectory){throw 'Use a new native proof directory'}
$out=[IO.Path]::GetFullPath($OutputDirectory)
$null=New-Item -ItemType Directory -Path $out
$dll=Join-Path $program 'rime.dll'
$source=Get-Content -LiteralPath (Join-Path $SchemeSource 'tests/RimeProbe.cs') -Raw
Add-Type -TypeDefinition $source.Replace('__RIME_ENGINE_DLL__',$dll)
$env:PATH=$program+';'+$env:PATH
$report=[ordered]@{passed=$false;phase=$Phase;syntheticFixtureOnly=$true;deploymentInvoked=$false;checks=@();stores=@{}}
$session=[UIntPtr]::Zero
$initialized=$false
$traits=[RimeProbe+Traits]::new()
$traits.data_size=[Runtime.InteropServices.Marshal]::SizeOf($traits)-4
$traits.min_log_level=2
foreach($row in @{shared_data_dir=(Join-Path $program 'data');user_data_dir=$user;prebuilt_data_dir=(Join-Path $user 'build');staging_dir=(Join-Path $user 'build');log_dir=$out;app_name='rime.public_upgrade_learning'}.GetEnumerator()){
  $traits.($row.Key)=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($row.Value)
}
$routes=@(
  @{kind='cn';schema=$(if($Phase -eq 'Before'){'pc_research'}else{'cn_stellae'});store=$(if($Phase -eq 'Before'){'luna_pinyin'}else{'cn_stellae'});raw='nihao';text=([string][char]0x4f60+[char]0x597d);english=0},
  @{kind='en';schema=$(if($Phase -eq 'Before'){'pc_research'}else{'cn_stellae'});store=$(if($Phase -eq 'Before'){'pc_english'}else{'en_intelligence'});raw='hello';text='hello';english=1},
  @{kind='jp';schema=$(if($Phase -eq 'Before'){'jp_sela'}else{'jp_stellae'});store=$(if($Phase -eq 'Before'){'jp_family'}else{'jp_kanji'});raw='vwo';text=([string][char]0x6211);english=0}
)
function Check([string]$Name,[bool]$Passed){$report.checks+=@([ordered]@{name=$Name;passed=$Passed});if(-not $Passed){throw $Name}}
function Export-Stores([string]$Label){
  $stores=@{}
  foreach($route in $routes){
    $file=Join-Path $out ($Label+'-'+$route.store+'.tsv')
    Check ($Label+' exports '+$route.store) ([RimeProbe]::ExportUserDict($route.store,$file) -gt 0)
    $rows=@(Get-Content -LiteralPath $file -Encoding UTF8 | Where-Object {$_ -and -not $_.StartsWith('#')} | Sort-Object)
    $selected=@($rows | Where-Object {$_.Split("`t")[0] -ceq $route.text})
    Check ($Label+' includes genuine '+$route.kind+' learning') ($selected.Count -gt 0)
    $count=0
    foreach($line in $selected){$count+=[int]$line.Split("`t")[2]}
    $stores[$route.kind]=[ordered]@{name=$route.store;records=$rows;selectedCount=$count}
  }
  return $stores
}
try{
  [RimeProbe]::RimeSetup([ref]$traits)
  [RimeProbe]::RimeInitialize([ref]$traits)
  $initialized=$true
  if($Phase -eq 'After'){
    $before=Get-Content -LiteralPath $Baseline -Raw|ConvertFrom-Json
    $migrated=Export-Stores 'migrated-before-session'
    foreach($route in $routes){
      $expected=@($before.stores.($route.kind).records)
      Check ('Exact learning records preserved for '+$route.kind) (($expected|ConvertTo-Json -Compress) -ceq ($migrated[$route.kind].records|ConvertTo-Json -Compress))
    }
    $report.migratedBeforeAnySession=$migrated
  }
  $session=[RimeProbe]::RimeCreateSession()
  Check 'Installed native session opens' ($session -ne [UIntPtr]::Zero)
  foreach($route in $routes){
    Check ('Installed schema selects '+$route.schema) ([bool][RimeProbe]::RimeSelectSchema($session,$route.schema))
    [RimeProbe]::RimeSetOption($session,'probe_options_ready',1)
    [RimeProbe]::RimeSetOption($session,'ascii_mode',0)
    [RimeProbe]::RimeSetOption($session,'research_english',$route.english)
    [RimeProbe]::RimeSetOption($session,'simplification',1)
    $repeat=if($Phase -eq 'Before'){3}else{1}
    for($i=0;$i -lt $repeat;$i++){
      [RimeProbe]::RimeClearComposition($session)
      foreach($char in $route.raw.ToCharArray()){
        [RimeProbe]::RimeProcessKey($session,[int]$char,0)|Out-Null
        [RimeProbe]::RimeProcessKey($session,[int]$char,0x40000000)|Out-Null
      }
      $choices=@([RimeProbe]::Snapshot($session,1000).Candidates)
      $index=[Array]::IndexOf($choices,$route.text)
      Check ('Genuine '+$route.kind+' candidate '+$i) ($index -ge 0)
      Check ('Select genuine '+$route.kind+' candidate '+$i) ([bool][RimeProbe]::SelectCandidate($session,$index))
      Check ('Commit genuine '+$route.kind+' candidate '+$i) ([RimeProbe]::ReadCommit($session) -ceq $route.text)
    }
  }
  [RimeProbe]::RimeClearComposition($session)
  [RimeProbe]::RimeDestroySession($session)|Out-Null
  $session=[UIntPtr]::Zero
  $report.stores=Export-Stores 'learned'
  if($Phase -eq 'After'){
    foreach($route in $routes){Check ('Continued learning reconnects '+$route.store) ($report.stores[$route.kind].selectedCount -gt $before.stores.($route.kind).selectedCount)}
  }
  $report.passed=$true
}finally{
  if($session -ne [UIntPtr]::Zero){[RimeProbe]::RimeClearComposition($session);[RimeProbe]::RimeDestroySession($session)|Out-Null}
  if($initialized){[RimeProbe]::RimeFinalize()}
  $report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $out 'result.json') -Encoding UTF8
}
Write-Output ('PASS public upgrade native learning '+$Phase+': '+$report.checks.Count)
