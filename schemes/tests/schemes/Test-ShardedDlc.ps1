# SPDX-License-Identifier: GPL-3.0-only
param(
 [Parameter(Mandatory=$true)][string]$EngineDll,
 [Parameter(Mandatory=$true)][string]$OutputDirectory,
 [int]$StressRows=100000
)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$out=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path -LiteralPath $out){throw 'Use a fresh synthetic output directory.'}
if($StressRows -lt 32 -or $StressRows -gt 1000000){throw 'The fixed stress range is 32 to 1000000 records.'}
$user=Join-Path $out 'user';$shared=Join-Path $out 'shared';$logs=Join-Path $out 'logs'
foreach($path in @($user,$shared,$logs,(Join-Path $user 'build'),(Join-Path $user 'lua'))){[void][IO.Directory]::CreateDirectory($path)}
$utf8=[Text.UTF8Encoding]::new($false)
function Write-Text([string]$path,[string]$text){[void][IO.Directory]::CreateDirectory((Split-Path $path -Parent));[IO.File]::WriteAllText($path,$text,$utf8)}
function Adler32([byte[]]$bytes){[long]$a=1;[long]$b=0;foreach($v in $bytes){$a=($a+$v)%65521;$b=($b+$a)%65521};return ('{0:x8}' -f ($b*65536+$a))}
function Write-Catalog([string]$directory,[int]$rows){
 [void][IO.Directory]::CreateDirectory($directory)
 $master="---`nname: rymcp_dlc/poetry/words`nversion: 'fixture'`nsort: by_weight`nuse_preset_vocabulary: false`npatch:`n  __include: rymcp_dlc/poetry/words_00.dict:/activation`n...`n"
 Write-Text (Join-Path $directory 'words.dict.yaml') $master
 $names=@('words.dict.yaml')
 for($index=0;$index -lt 32;$index++){
  $suffix='{0:d2}' -f $index;$name='words_'+$suffix+'.dict.yaml';$names+=$name
  $activation=if($index -lt 31){"activation:`n  __include: rymcp_dlc/poetry/words_$('{0:d2}' -f ($index+1)).dict:/activation`n"}else{"activation:`n  translator/packs/+:`n"+((0..31|ForEach-Object {'    - rymcp_dlc_poetry_{0:d2}' -f $_}) -join "`n")+"`n"}
  $builder=[Text.StringBuilder]::new()
  [void]$builder.Append("---`nname: rymcp_dlc/poetry/words_$suffix`nversion: 'fixture'`nsort: by_weight`nuse_preset_vocabulary: false`n$activation...`n")
  $start=[int][Math]::Floor($rows*$index/32.0);$end=[int][Math]::Floor($rows*($index+1)/32.0)
  for($row=$start;$row -lt $end;$row++){[void]$builder.Append(('FixedFixture{0:d8}' -f $row)+"`ta a a`t100`n")}
  Write-Text (Join-Path $directory $name) $builder.ToString()
 }
 $manifest="format`t2`nid`tpoetry`nrevision`tfixture`nlanguages`tcn`ncn-layout`tshards`ncn-rows`t$rows`n"
 foreach($name in $names){$bytes=[IO.File]::ReadAllBytes((Join-Path $directory $name));$manifest+="file`t$name`t$($bytes.Length)`t$(Adler32 $bytes)`n"}
 Write-Text (Join-Path $directory 'manifest.tsv') $manifest
}
Write-Catalog (Join-Path $user 'rymcp_dlc/poetry') 32
Write-Catalog (Join-Path $user 'stress') $StressRows
Write-Text (Join-Path $user 'stress-rows.txt') ([string]$StressRows)
Copy-Item -LiteralPath (Join-Path $repo 'config/pc/lua/rymcp_dlc.lua') -Destination (Join-Path $user 'lua/rymcp_dlc.lua')
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/sharded_dlc_test.lua') -Destination (Join-Path $user 'lua/sharded_dlc_test.lua')
Write-Text (Join-Path $user 'rime.lua') "sharded_dlc_test = require('sharded_dlc_test')`n"
Write-Text (Join-Path $user 'default.yaml') "config_version: '1'`nschema_list:`n  - schema: sharded_dlc_test`n"
Write-Text (Join-Path $user 'sharded_dlc_test.schema.yaml') @'
schema:
  schema_id: sharded_dlc_test
  name: Fixed synthetic sharded catalog
  version: '1'
engine:
  processors: [lua_processor@sharded_dlc_test]
  segmentors: [fallback_segmentor]
  translators: [echo_translator]
'@
$dll=[IO.Path]::GetFullPath($EngineDll);$env:PATH=(Split-Path $dll -Parent)+';'+$env:PATH
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $repo 'tests/RimeProbe.cs'),$utf8).Replace('__RIME_ENGINE_DLL__',$dll))
$traits=[RimeProbe+Traits]::new();$traits.data_size=[Runtime.InteropServices.Marshal]::SizeOf($traits)-4
foreach($pair in @(@('user_data_dir',$user),@('shared_data_dir',$shared),@('prebuilt_data_dir',(Join-Path $user 'build')),@('staging_dir',(Join-Path $user 'build')),@('log_dir',$logs),@('app_name','rime.sharded_dlc_fixed_tests'))){$traits.($pair[0])=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($pair[1])}
$traits.min_log_level=2;$session=[UIntPtr]::Zero
try{
 [RimeProbe]::RimeSetup([ref]$traits);[RimeProbe]::RimeInitialize([ref]$traits);[RimeProbe]::RimeDeployerInitialize([ref]$traits)
 if(-not [RimeProbe]::RimeDeployWorkspace()){throw 'Fixed test schema compilation failed.'}
 $session=[RimeProbe]::RimeCreateSession()
 if(-not [RimeProbe]::RimeSelectSchema($session,'sharded_dlc_test')){throw 'Fixed test schema unavailable.'}
 $json=[RimeProbe]::Property($session,'sharded_dlc_result')
 if(-not $json){throw 'Fixed sharded catalog checks did not run.'}
 $result=$json|ConvertFrom-Json
 $result|Add-Member -NotePropertyName SyntheticOnly -NotePropertyValue $true
 $result|Add-Member -NotePropertyName PeakWorkingSet -NotePropertyValue ([Diagnostics.Process]::GetCurrentProcess().PeakWorkingSet64)
 [IO.File]::WriteAllText((Join-Path $out 'results.json'),($result|ConvertTo-Json -Depth 8),$utf8)
 if(-not $result.Passed -or @($result.Checks|Where-Object {-not $_.Passed}).Count){throw 'Fixed sharded catalog assertions failed.'}
 [pscustomobject]@{Passed=$true;Checks=$result.Checks.Count;StressRows=$result.StressRows;StreamSeconds=$result.StreamSeconds;LuaPeakDeltaKiB=$result.LuaPeakDeltaKiB}|ConvertTo-Json
}finally{if($session -ne [UIntPtr]::Zero){[void][RimeProbe]::RimeDestroySession($session)};[RimeProbe]::RimeFinalize()}
