# SPDX-License-Identifier: GPL-3.0-only
param(
  [Parameter(Mandatory)][string]$EngineDirectory,
  [Parameter(Mandatory)][string]$OutputDirectory,
  [string]$FixtureUser,
  [ValidateSet('before','after')][string]$ProbePhase='before'
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$helper=Join-Path $repo 'schemes/scripts/upgrade/LearningStore.ps1'
$engine=[IO.Path]::GetFullPath($EngineDirectory)
. $helper -LibraryOnly
$out=[IO.Path]::GetFullPath($OutputDirectory)
$utf8=[Text.UTF8Encoding]::new($false)
$word=([string][char]0x5b78)+[char]0x7fd2
function Write-Fixture([string]$Path,[string]$Text){$null=[IO.Directory]::CreateDirectory((Split-Path $Path -Parent));[IO.File]::WriteAllText($Path,$Text,$utf8)}
function Query-Fixture([UIntPtr]$Session,[string]$Raw){
  [RimeProbe]::RimeClearComposition($Session)
  foreach($key in $Raw.ToCharArray()){[RimeProbe]::RimeProcessKey($Session,[int]$key,0)|Out-Null}
  return [RimeProbe]::Snapshot($Session,50)
}
if($FixtureUser){
  $user=[IO.Path]::GetFullPath($FixtureUser)
  if(-not $user.StartsWith($out+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Probe only a test-owned synthetic directory.'}
  $probeSource=[IO.File]::ReadAllText((Join-Path $repo 'schemes/tests/RimeProbe.cs'))
  Add-Type -TypeDefinition $probeSource.Replace('__RIME_ENGINE_DLL__',(Join-Path $engine 'rime.dll'))
  $env:PATH=$engine+';'+$env:PATH
  $baseWord=([string][char]0x660e)+[char]0x6708
  Write-Fixture (Join-Path $user 'learning_fixture.dict.yaml') ("---`nname: learning_fixture`nversion: '1'`nsort: by_weight`nuse_preset_vocabulary: false`n...`n"+$baseWord+"`tming yue`t1`n")
  $list="schema_list:`n"
  for($index=0;$index -lt 3;$index++){
    $store=if($ProbePhase -eq 'before'){$script:LearningMappings[$index].oldName}else{$script:LearningMappings[$index].newName}
    $schema='learning_fixture_'+$index
    $list+='  - schema: '+$schema+"`n"
    Write-Fixture (Join-Path $user ($schema+'.schema.yaml')) @"
schema:
  schema_id: $schema
  name: Synthetic learning fixture
  version: '1'
engine:
  processors: [speller, selector, navigator, express_editor]
  segmentors: [abc_segmentor]
  translators: [script_translator]
speller:
  alphabet: abcdefghijklmnopqrstuvwxyz
  delimiter: " '"
  algebra:
    - "abbrev/^([a-z]).+`$/`$1/"
translator:
  dictionary: learning_fixture
  user_dict: $store
  enable_user_dict: true
  enable_completion: true
  enable_sentence: false
"@
  }
  Write-Fixture (Join-Path $user 'default.yaml') $list
  $null=[IO.Directory]::CreateDirectory((Join-Path $user 'build'))
  $null=[IO.Directory]::CreateDirectory((Join-Path $user 'probe-logs'))
  $traits=New-Object RimeProbe+Traits
  $traits.data_size=[Runtime.InteropServices.Marshal]::SizeOf($traits)-4
  $allocated=@()
  foreach($pair in @(@('shared_data_dir',$user),@('user_data_dir',$user),@('prebuilt_data_dir',(Join-Path $user 'build')),@('staging_dir',(Join-Path $user 'build')),@('log_dir',(Join-Path $user 'probe-logs')),@('app_name','rime.synthetic_learning_migration'))){
    $pointer=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($pair[1]);$allocated+=@($pointer);$traits.($pair[0])=$pointer
  }
  $traits.min_log_level=2
  $session=[UIntPtr]::Zero
  $checks=@()
  try{
    [RimeProbe]::RimeSetup([ref]$traits);[RimeProbe]::RimeDeployerInitialize([ref]$traits)
    if(-not [RimeProbe]::RimeDeployWorkspace()){throw 'Synthetic learning schema deployment failed.'}
    [RimeProbe]::RimeInitialize([ref]$traits)
    $session=[RimeProbe]::RimeCreateSession()
    if($session -eq [UIntPtr]::Zero){throw 'Synthetic learning session was not created.'}
    for($index=0;$index -lt 3;$index++){
      if(-not [RimeProbe]::RimeSelectSchema($session,('learning_fixture_'+$index))){throw 'Synthetic learning schema selection failed.'}
      $snapshot=Query-Fixture $session 'mingy'
      if($snapshot.Candidates -cnotcontains $word){throw ('The learned completion is unavailable in '+$ProbePhase+' store '+$index)}
      if($ProbePhase -eq 'before'){
        $position=[Array]::IndexOf([string[]]$snapshot.Candidates,$word)
        if(-not [RimeProbe]::SelectCandidate($session,$position)){throw 'The genuine synthetic learned candidate could not be selected.'}
        if([RimeProbe]::ReadCommit($session) -cne $word){throw 'Synthetic learned candidate commit differs.'}
      }
      $checks+=@([ordered]@{index=$index;learnedCompletionAvailable=$true;genuineCommitPerformed=($ProbePhase -eq 'before')})
    }
  }finally{
    if($session -ne [UIntPtr]::Zero){[RimeProbe]::RimeDestroySession($session)|Out-Null}
    [RimeProbe]::RimeFinalize()
    foreach($pointer in $allocated){[Runtime.InteropServices.Marshal]::FreeHGlobal($pointer)}
  }
  Learning-Json (Join-Path $out ('genuine-'+$ProbePhase+'.json')) ([ordered]@{passed=$true;syntheticFixtureOnly=$true;phase=$ProbePhase;checks=$checks})
  return
}
if(Test-Path -LiteralPath $out){throw 'Choose a new synthetic learning test directory.'}
$null=[IO.Directory]::CreateDirectory($out)
$checks=@()
function Check([string]$Name,[bool]$Passed){$script:checks+=@([ordered]@{name=$Name;passed=$Passed});if(-not $Passed){throw ('Learning migration test failed: '+$Name)}}
function Run-Helper([string]$ActionName,[string]$User,[string]$Work,[string]$Label){
  & $helper -Action $ActionName -UserDirectory $User -EngineDirectory $engine -WorkDirectory $Work -BackupDirectory (Join-Path $out 'archives') -ReportFile (Join-Path $out ($Label+'.json'))|Out-Null
}
function Seed([string]$User){
  foreach($name in @('logs','empty','build')){$null=[IO.Directory]::CreateDirectory((Join-Path $User $name))}
  $lua="local names={'luna_pinyin','pc_english','jp_family'}`nfor _,name in ipairs(names) do`n local db=assert(LevelDb(name)); assert(db:open())`n"
  $lua+=" assert(db:update('ming yue `t"+$word+"','c=17 d=9.125 t=101'))`n"
  $lua+=" assert(db:update('fixture deleted `tFixtureDeleted','c=-5 d=0.125 t=7'))`n assert(db:update('fixture variant `tFixtureVariant','c=3 d=1.23456789 t=33'))`n assert(db:update('\1/tick','137'))`n assert(db:update('\1/custom_fixture_metadata','preserve-me'))`n assert(db:close())`nend`n"
  $scriptPath=Join-Path $User 'rime.lua'
  try{Write-Fixture $scriptPath $lua;Learning-RunLua $engine $User}finally{if(Test-Path -LiteralPath $scriptPath){Remove-Item -LiteralPath $scriptPath}}
  foreach($mapping in $script:LearningMappings){if(-not (Test-Path -LiteralPath (Join-Path $User ($mapping.oldName+'.userdb/CURRENT')))){throw 'The native synthetic seed failed.'}}
}
function Probe([string]$User,[string]$Phase){
  $exe=(Get-Process -Id $PID).Path
  & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $PSCommandPath -EngineDirectory $engine -OutputDirectory $out -FixtureUser $User -ProbePhase $Phase
  if($LASTEXITCODE){throw ('Genuine learning completion probe failed: '+$Phase)}
}
$hashFixture=Join-Path $out 'sha256-fixture.txt'
Write-Fixture $hashFixture 'abc'
$withoutHashCmdlet=& {
  function Get-FileHash {throw 'Get-FileHash is unavailable in this regression scope'}
  Learning-Hash $hashFixture
}
Check 'learning SHA256 works without Get-FileHash' ($withoutHashCmdlet -ceq 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
$fresh=Join-Path $out 'fresh-user';$null=[IO.Directory]::CreateDirectory($fresh)
Run-Helper Preflight $fresh (Join-Path $out 'fresh-work') fresh
Check 'fresh install needs no learning migration' (-not (Get-Content -LiteralPath (Join-Path $out 'fresh.json') -Raw|ConvertFrom-Json).needsMigration)
Check 'fresh install has no required marker' (-not (Test-Path -LiteralPath (Join-Path $out 'fresh-work/required.flag')))
$user=Join-Path $out 'upgrade-user';Seed $user
Probe $user before
$original=@{}
foreach($mapping in $script:LearningMappings){$original[$mapping.oldName]=@(Learning-Tree (Join-Path $user ($mapping.oldName+'.userdb')) '')}
$work=Join-Path $out 'upgrade-work'
Run-Helper Preflight $user $work upgrade-preflight
Check 'all three legacy mappings require migration' ((Get-Content -LiteralPath (Join-Path $out 'upgrade-preflight.json') -Raw|ConvertFrom-Json).mappings.Count -eq 3)
Run-Helper Prepare $user $work upgrade-prepare
Run-Helper Apply $user $work upgrade-apply
foreach($mapping in $script:LearningMappings){Check ('original '+$mapping.oldName+' remains byte exact before deployment') (Learning-SameTree $original[$mapping.oldName] @(Learning-Tree (Join-Path $user ($mapping.oldName+'.userdb')) ''))}
$failed=$false
try{Run-Helper Finalize $user $work finalize-before-deploy}catch{$failed=$true}
Check 'finalize requires successful new deployment' $failed
Write-Fixture (Join-Path $user 'build/stellae.yaml') "config_version: synthetic`n"
# Probe source schemas are synthetic, remove obsolete generated defaults before
# checking references; only currently effective fixture schemas are relevant.
Write-Fixture (Join-Path $user 'build/default.yaml') "schema_list: []`n"
Run-Helper Finalize $user $work upgrade-finalize
foreach($mapping in $script:LearningMappings){
  Check ('old '+$mapping.oldName+' leaves runtime only after deployment') (-not (Test-Path -LiteralPath (Join-Path $user ($mapping.oldName+'.userdb'))))
  Check ('new '+$mapping.newName+' exists') (Test-Path -LiteralPath (Join-Path $user ($mapping.newName+'.userdb')) -PathType Container)
}
Probe $user after
Run-Helper Preflight $user (Join-Path $out 'repeat-work') repeat
Check 'repeat upgrade needs no migration' (-not (Get-Content -LiteralPath (Join-Path $out 'repeat.json') -Raw|ConvertFrom-Json).needsMigration)
$conflict=Join-Path $out 'conflict-user';Seed $conflict
$null=[IO.Directory]::CreateDirectory((Join-Path $conflict 'cn_stellae.userdb'))
$failed=$false;try{Run-Helper Preflight $conflict (Join-Path $out 'conflict-work') conflict}catch{$failed=$true}
Check 'old plus new conflict is rejected without deleting either' ($failed -and (Test-Path -LiteralPath (Join-Path $conflict 'luna_pinyin.userdb/CURRENT')) -and (Test-Path -LiteralPath (Join-Path $conflict 'cn_stellae.userdb')))
$rollback=Join-Path $out 'rollback-user';Seed $rollback
$rollbackWork=Join-Path $out 'rollback-work'
Run-Helper Prepare $rollback $rollbackWork rollback-prepare
Run-Helper Apply $rollback $rollbackWork rollback-apply
Run-Helper Rollback $rollback $rollbackWork rollback
Check 'failed deployment can discard only unchanged new copies' ((Test-Path -LiteralPath (Join-Path $rollback 'luna_pinyin.userdb/CURRENT')) -and -not (Test-Path -LiteralPath (Join-Path $rollback 'cn_stellae.userdb')))
$manual=Join-Path $out 'manual-user';Seed $manual
$manualWork=Join-Path $out 'manual-work'
Run-Helper Prepare $manual $manualWork manual-prepare
Run-Helper Apply $manual $manualWork manual-apply
Write-Fixture (Join-Path $manual 'cn_stellae.custom.yaml') "patch:`n  translator/user_dict: luna_pinyin`n"
Write-Fixture (Join-Path $manual 'build/stellae.yaml') "config_version: synthetic`n"
Run-Helper Finalize $manual $manualWork manual-finalize
Check 'explicit legacy user reference retains its original learning store' ((Test-Path -LiteralPath (Join-Path $manual 'luna_pinyin.userdb/CURRENT')) -and @((Get-Content -LiteralPath (Join-Path $out 'manual-finalize.json') -Raw|ConvertFrom-Json).manualMerge).Count -eq 1)
$result=[ordered]@{passed=$true;syntheticFixtureOnly=$true;actualLearningRead=$false;checks=$checks;genuineLearningCompletionsBeforeAndAfter=$true}
Learning-Json (Join-Path $out 'result.json') $result
Write-Output ($result|ConvertTo-Json -Depth 7)
