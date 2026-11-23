# SPDX-License-Identifier: GPL-3.0-only
param(
 [Parameter(Mandatory=$true)][string]$EngineDll,
 [Parameter(Mandatory=$true)][string]$SharedData,
 [Parameter(Mandatory=$true)][string]$WorkRoot
)
$ErrorActionPreference='Stop'
$repo=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$work=[IO.Path]::GetFullPath($WorkRoot)
if(Test-Path -LiteralPath $work){throw 'Use a fresh synthetic work directory.'}
$user=Join-Path $work 'empty-user'
$build=Join-Path $user 'build'
New-Item -ItemType Directory -Path $build -Force | Out-Null
'{"kind":"fixed-synthetic-profile","format":1}' | Set-Content -LiteralPath (Join-Path $user '.synthetic-profile.json') -Encoding UTF8
$dll=[IO.Path]::GetFullPath($EngineDll)
$shared=[IO.Path]::GetFullPath($SharedData)
$env:PATH=(Split-Path $dll -Parent)+';'+$env:PATH
$api=Get-Content -LiteralPath (Join-Path $repo 'tests/RimeProbe.cs') -Raw
Add-Type -TypeDefinition $api.Replace('__RIME_ENGINE_DLL__',$dll)
$traits=New-Object RimeProbe+Traits
$traits.data_size=[Runtime.InteropServices.Marshal]::SizeOf($traits)-4
$traits.shared_data_dir=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($shared)
$traits.user_data_dir=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($user)
$traits.prebuilt_data_dir=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($build)
$traits.staging_dir=$traits.prebuilt_data_dir
$traits.log_dir=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($work)
$traits.app_name=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi('rime.shared_profile_tests')
$traits.min_log_level=2
$rows=[Collections.Generic.List[object]]::new()
$s=[UIntPtr]::Zero
function Check([string]$name,[bool]$passed){
 $rows.Add([pscustomobject]@{Check=$name;Passed=$passed})
 if(-not $passed){throw ('Shared profile check failed: '+$name)}
}
function Query([string]$raw){
 [RimeProbe]::RimeClearComposition($s)
 foreach($ch in $raw.ToCharArray()){
  $mask=if([char]::IsUpper($ch)){1}else{0}
  [RimeProbe]::RimeProcessKey($s,[int]$ch,$mask)|Out-Null
  [RimeProbe]::RimeProcessKey($s,[int]$ch,($mask -bor 0x40000000))|Out-Null
 }
 return [RimeProbe]::Snapshot($s,250)
}
try{
 [RimeProbe]::RimeSetup([ref]$traits)
 [RimeProbe]::RimeInitialize([ref]$traits)
 [RimeProbe]::RimeDeployerInitialize([ref]$traits)
 Check 'deploy-workspace' ([bool][RimeProbe]::RimeDeployWorkspace())
 $compiledDefault=Join-Path $build 'default.yaml'
 Check 'compiled-default' (Test-Path -LiteralPath $compiledDefault)
 $defaultText=[IO.File]::ReadAllText($compiledDefault)
 Check 'default-Chinese-entry' ($defaultText -match '(?m)^\s*-\s*schema:\s*pc_research\s*$')
 Check 'default-Japanese-entry' ($defaultText -match '(?m)^\s*-\s*schema:\s*jp_sela\s*$')
 foreach($schema in @('stroke','english_full','mixed_full','project_radical','project_radical_parts','jp_small_lookup','jp_q_lookup','jp_v_lookup','jp_v_pc_lookup','jp_sela','pc_research')){
  [void][RimeProbe]::RimeDeploySchema((Join-Path $shared ($schema+'.schema.yaml')))
  Check ('compiled-'+$schema) (Test-Path -LiteralPath (Join-Path $build ($schema+'.schema.yaml')))
 }
 $s=[RimeProbe]::RimeCreateSession()
 $schemaBuffer=New-Object byte[] 256
 Check 'initial-Chinese-schema' ([bool][RimeProbe]::RimeGetCurrentSchema($s,$schemaBuffer,[UIntPtr]::new([uint32]256)) -and [Text.Encoding]::UTF8.GetString($schemaBuffer).Trim([char]0) -ceq 'pc_research')
 Check 'select-Chinese' ([bool][RimeProbe]::RimeSelectSchema($s,'pc_research'))
 Check 'default-SC' ([RimeProbe]::RimeGetOption($s,'simplification') -eq 1)
 $state=Query 'nihao'
 Check 'Chinese-candidate' ($state.Candidates -ccontains '你好')
 $state=Query 'wifimima'
 Check 'SC-mixed-candidate' ($state.Candidates -ccontains 'Wi-Fi 密码')
 [RimeProbe]::RimeSetOption($s,'simplification',0)
 $state=Query 'wifimima'
 Check 'TC-mixed-candidate' ($state.Candidates -ccontains 'Wi-Fi 密碼')
 $state=Query 'uUhU'
 $readingIndex=[Array]::IndexOf([string[]]$state.Candidates,'一')
 Check 'stroke-query-candidate' ($readingIndex -ge 0)
 Check 'stroke-query-reading' ($readingIndex -ge 0 -and $state.Comments[$readingIndex] -match 'yi1')
 [RimeProbe]::RimeSetOption($s,'research_english',1)
 $state=Query 'hello'
 Check 'English-candidate' ($state.Candidates -ccontains 'hello')
 [RimeProbe]::RimeClearComposition($s)
 Check 'select-Japanese' ([bool][RimeProbe]::RimeSelectSchema($s,'jp_sela'))
 [RimeProbe]::RimeSetOption($s,'probe_options_ready',1)
 $state=Query 'qtaberu'
 Check 'Japanese-candidate' ($state.Candidates -ccontains '食べる')
 [RimeProbe]::RimeClearComposition($s)
 [RimeProbe]::RimeDestroySession($s)|Out-Null
 $s=[UIntPtr]::Zero
}finally{
 if($s -ne [UIntPtr]::Zero){[RimeProbe]::RimeClearComposition($s);[RimeProbe]::RimeDestroySession($s)|Out-Null}
 [RimeProbe]::RimeFinalize()
 $rows | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $work 'shared-results.json') -Encoding UTF8
}
$hostExe=(Get-Process -Id $PID).Path
$learning=@()
foreach($scenario in @('Bracket','Mixed')){
 $testUser=Join-Path $work ($scenario.ToLowerInvariant()+'-user')
 Copy-Item -LiteralPath $user -Destination $testUser -Recurse
 $out=Join-Path $work ($scenario.ToLowerInvariant()+'-results')
 & $hostExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo ('tests/schemes/Test-'+$scenario+'Learning.ps1')) -EngineDll $dll -SharedData $shared -UserData $testUser -OutputDirectory $out
 if($LASTEXITCODE -ne 0){throw ($scenario+' learning failed with installed shared resources.')}
 $items=Get-Content -LiteralPath (Join-Path $out 'results.json') -Raw | ConvertFrom-Json
 $learning += [pscustomobject]@{Scenario=$scenario;Checks=$items.Count;Passed=$true}
}
$summary=[pscustomobject]@{Format='rymcp-shared-scheme-validation-v1';Passed=$true;SharedChecks=$rows.Count;Learning=$learning}
$summary | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $work 'validation.json') -Encoding UTF8
$summary | ConvertTo-Json -Depth 5
