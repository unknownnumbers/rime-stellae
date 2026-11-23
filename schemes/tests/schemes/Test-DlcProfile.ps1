# SPDX-License-Identifier: GPL-3.0-only
# Exact distributed catalogs and a bounded, separate lifecycle fixture.
param(
 [Parameter(Mandatory=$true)][string]$EngineDll,
 [Parameter(Mandatory=$true)][string]$ProfileRoot,
 [Parameter(Mandatory=$true)][string]$ModulesDirectory,
 [Parameter(Mandatory=$true)][string]$SharedDirectory,
 [Parameter(Mandatory=$true)][string]$OutputDirectory,
 [string]$PythonExe='python'
)
$ErrorActionPreference='Stop'
$utf8=New-Object Text.UTF8Encoding($false)
$out=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path -LiteralPath $out){throw 'Use a fresh output directory.'}
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$profileSource=[IO.Path]::GetFullPath($ProfileRoot)
$moduleSource=[IO.Path]::GetFullPath($ModulesDirectory)
$Profile=Split-Path $profileSource -Leaf
if(@(Get-ChildItem -LiteralPath $profileSource -Directory -Filter '*.userdb').Count){throw 'ProfileRoot must contain public source files without learning databases.'}
$user=Join-Path $out 'user';$shared=Join-Path $out 'shared';$logs=Join-Path $out 'logs'
foreach($dir in @($user,$shared,$logs,(Join-Path $user 'build'))){[void][IO.Directory]::CreateDirectory($dir)}
foreach($entry in Get-ChildItem -LiteralPath $profileSource -Force){Copy-Item -LiteralPath $entry.FullName -Destination $user -Recurse}
if(Test-Path -LiteralPath (Join-Path $user 'samples')){foreach($entry in Get-ChildItem -LiteralPath (Join-Path $user 'samples') -File){Copy-Item -LiteralPath $entry.FullName -Destination (Join-Path $user $entry.Name)}}
$standard=[IO.Path]::GetFullPath($SharedDirectory)
foreach($name in @('default.yaml','pinyin.yaml','grammar.yaml','key_bindings.yaml','punctuation.yaml','symbols.yaml','stroke.dict.yaml','stroke.schema.yaml')){
 $source=Join-Path $standard $name
 if(Test-Path -LiteralPath $source){Copy-Item -LiteralPath $source -Destination (Join-Path $shared $name)}
}
if(Test-Path -LiteralPath (Join-Path $standard 'opencc')){Copy-Item -LiteralPath (Join-Path $standard 'opencc') -Destination (Join-Path $shared 'opencc') -Recurse}
function Write-Text([string]$path,[string]$value){[void][IO.Directory]::CreateDirectory((Split-Path $path -Parent));[IO.File]::WriteAllText($path,$value,$utf8)}
Write-Text (Join-Path $user 'default.custom.yaml') "patch:`n  schema_list:`n    - schema: pc_research`n"
Write-Text (Join-Path $user '.synthetic-profile.json') '{"format":1,"kind":"fixed-synthetic-dlc-profile","PersonalLearningCopied":false}'
$dll=[IO.Path]::GetFullPath($EngineDll);$env:PATH=(Split-Path $dll -Parent)+';'+$env:PATH
Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $repo 'tests/RimeProbe.cs'),$utf8).Replace('__RIME_ENGINE_DLL__',$dll))
$ids=@('math','physics','computer','poetry')
$codes=@('ce shi jia jia','ce shi yi yi','ce shi bo bo','ce shi du a')
$words=@('DLCMathFixture','DLCPhysicsFixture','DLCComputerFixture','DLCPoetryFixture')
$fixtureSyllables=@('a','ai','an','ang','ao','ba','bai','ban','bang','bao','bei','ben','beng','bi','bian','biao','bie','bin','bing','bo','bu','ca','cai','can','cang','cao','ce','cen','ceng','cha','chai','chan')
$canonicalForms=@{}
foreach($line in [IO.File]::ReadLines((Join-Path $profileSource 'lua/cn_forms.lua'),$utf8)){
 if($line -match '^\s*\["([^"\r\n]+)"\]=\{'){$syllable=$Matches[1];$forms=@([regex]::Matches($line,'\["([^"\r\n]+)"\]=0')|ForEach-Object {$_.Groups[1].Value}|Sort-Object);if($forms.Count){$canonicalForms[$syllable]=$forms[0]}}
}
function Exact-Spelling([string]$code){return ((@($code.Split(' ')|ForEach-Object {if($canonicalForms.ContainsKey($_)){$canonicalForms[$_]}else{$_}}) -join '"')+'"')}
function Assert-Isolated([string]$path){if(-not ([IO.Path]::GetFullPath($path)).StartsWith(($out+'\'),[StringComparison]::OrdinalIgnoreCase)){throw 'Path is outside the isolated validation directory.'}}
function Remove-Module([string]$id){$path=Join-Path $user ('rymcp_dlc/'+$id);Assert-Isolated $path;if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -Recurse}}
function Adler32([byte[]]$data){[long]$a=1;[long]$b=0;foreach($value in $data){$a=($a+$value)%65521;$b=($b+$a)%65521};return ('{0:x8}' -f [long]($b*65536+$a))}
function Write-Module([int]$index,[string]$text='',[string]$revision='1'){
 $id=$ids[$index];if(-not $text){$text=$words[$index]}
 Remove-Module $id
 $directory=Join-Path $user ('rymcp_dlc/'+$id)
 $header="---`nname: rymcp_dlc/$id/words`nversion: 'fixture-$revision'`nsort: by_weight`nuse_preset_vocabulary: false`n"
 if($id -eq 'poetry'){
  Write-Text (Join-Path $directory 'words.dict.yaml') ($header+"patch:`n  __include: rymcp_dlc/poetry/words_00.dict:/activation`n...`n")
  for($part=0;$part -lt 32;$part++){
   $suffix='{0:d2}' -f $part
   $activation=if($part -lt 31){"activation:`n  __include: rymcp_dlc/poetry/words_$('{0:d2}' -f ($part+1)).dict:/activation`n"}else{"activation:`n  translator/packs/+:`n"+((0..31|ForEach-Object {'    - rymcp_dlc_poetry_{0:d2}' -f $_}) -join "`n")+"`n"}
   $label=if($part -eq 0){$text}else{'DLCPoetryPartition'+$suffix}
   $body="$label`tce shi du $($fixtureSyllables[$part])`t1000000`n"
   $piece=$header.Replace('/words'+"`n",'/words_'+$suffix+"`n")+$activation+"...`n"+$body
   Write-Text (Join-Path $directory ('words_'+$suffix+'.dict.yaml')) $piece
  }
  $manifest="format`t2`nid`t$id`nrevision`tfixture-$revision`nlanguages`tcn`ncn-layout`tshards`ncn-rows`t32`n"
 }else{
  Write-Text (Join-Path $directory 'words.dict.yaml') ($header+"patch:`n  translator/packs/+:`n    - rymcp_dlc_$id`n...`n$text`t$($codes[$index])`t1000000`n")
  $manifest="format`t1`nid`t$id`nrevision`tfixture-$revision`nlanguages`tcn`n"
 }
 foreach($file in Get-ChildItem -LiteralPath $directory -File|Sort-Object Name){$bytes=[IO.File]::ReadAllBytes($file.FullName);$manifest+="file`t$($file.Name)`t$($bytes.Length)`t$(Adler32 $bytes)`n"}
 Write-Text (Join-Path $directory 'manifest.tsv') $manifest
}
$traits=New-Object RimeProbe+Traits;$traits.data_size=[Runtime.InteropServices.Marshal]::SizeOf($traits)-4
foreach($pair in @(@('shared_data_dir',$shared),@('user_data_dir',$user),@('prebuilt_data_dir',(Join-Path $user 'build')),@('staging_dir',(Join-Path $user 'build')),@('log_dir',$logs),@('app_name','rime.dlc_profile_synthetic'))){$traits.($pair[0])=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($pair[1])}
$traits.min_log_level=2;$script:initialized=$false;$script:s=[UIntPtr]::Zero;$script:phase='Setup'
$checks=[Collections.Generic.List[object]]::new();$deployments=[Collections.Generic.List[object]]::new()
function Check([string]$id,[bool]$passed,$actual=$null){$checks.Add([pscustomobject]@{Phase=$script:phase;Id=$id;Passed=$passed;Actual=$actual});if(-not $passed){throw ('CN DLC profile check failed: '+$id)}}
function Close-Engine{if($script:initialized){[RimeProbe]::RimeFinalize();$script:initialized=$false;$script:s=[UIntPtr]::Zero}}
function Start-Engine{[RimeProbe]::RimeInitialize([ref]$traits);$script:initialized=$true}
function Redeploy{
 Close-Engine;Start-Engine;[RimeProbe]::RimeDeployerInitialize([ref]$traits)
 $watch=[Diagnostics.Stopwatch]::StartNew();$deployed=[RimeProbe]::RimeDeployWorkspace();$watch.Stop()
 $deployments.Add([pscustomobject]@{Phase=$script:phase;Milliseconds=$watch.ElapsedMilliseconds})
 Check 'deploy-api' ($deployed -ne 0)
 Check 'compiled-schema' (Test-Path -LiteralPath (Join-Path $user 'build/pc_research.schema.yaml'))
 Close-Engine;Start-Engine
 $script:s=[RimeProbe]::RimeCreateSession();Check 'schema-select' ([RimeProbe]::RimeSelectSchema($script:s,'pc_research') -ne 0)
 [RimeProbe]::RimeSetOption($script:s,'probe_options_ready',1)
 [RimeProbe]::RimeSetOption($script:s,'ascii_mode',0)
 [RimeProbe]::RimeSetOption($script:s,'research_english',0)
 [RimeProbe]::RimeSetOption($script:s,'simplification',0)
}
function Query([string]$code,[switch]$Exact){[RimeProbe]::RimeClearComposition($script:s);[void][RimeProbe]::ReadCommit($script:s);$raw=if($Exact){Exact-Spelling $code}else{$code.Replace(' ','')};foreach($c in $raw.ToCharArray()){[void][RimeProbe]::RimeProcessKey($script:s,[int]$c,0);[void][RimeProbe]::RimeProcessKey($script:s,[int]$c,0x40000000)};return [RimeProbe]::Snapshot($script:s,150)}
function Public-Sample([string]$id){
 $directory=Join-Path $moduleSource $id
 $metadata=@{};foreach($line in [IO.File]::ReadLines((Join-Path $directory 'manifest.tsv'),$utf8)){$f=$line.Split("`t");if($f.Count -eq 2){$metadata[$f[0]]=$f[1]}}
 if($metadata['format'] -notin @('1','2')){throw 'Unknown public manifest format.'}
 $names=if($metadata['format'] -eq '2'){@(Get-ChildItem -LiteralPath $directory -Filter 'words_??.dict.yaml' -File|Sort-Object Name|ForEach-Object {$_.FullName})}else{@((Join-Path $directory 'words.dict.yaml'))}
 foreach($path in $names){
  $body=$false
  foreach($line in [IO.File]::ReadLines($path,$utf8)){
   if($line -eq '...'){$body=$true;continue};if(-not $body -or -not $line -or $line.StartsWith('#')){continue}
   $f=$line.Split("`t");if($f.Count -ne 3){throw 'Malformed public dictionary row.'}
   if($f[0].Length -lt 4 -or $f[0].Length -gt 10 -or $f[0] -notmatch '^[\u4e00-\u9fff]+$' -or (Exact-Spelling $f[1]).Length -gt 48){continue}
   if(@($f[1].Split(' ')|Where-Object {-not $canonicalForms.ContainsKey($_)}).Count){continue}
   if(@((Query $f[1] -Exact).Candidates) -notcontains $f[0]){return [pscustomobject]@{Id=$id;Text=$f[0];Code=$f[1];FixedSpelling=(Exact-Spelling $f[1]);ManifestFormat=[int]$metadata['format']}}
  }
 }
 throw ('No discriminating public sample for '+$id)
}
function Check-Tables([string]$name){
 & $PythonExe (Join-Path $PSScriptRoot 'Check-ChineseDlcTables.py') --build-dir (Join-Path $user 'build') --modules-dir (Join-Path $user 'rymcp_dlc') --output (Join-Path $out ('capacity-'+$name+'.json'))
 Check 'native-tables-exact-complete-without-growth' ($LASTEXITCODE -eq 0)
}
function Export-Learning([string]$name){Close-Engine;Start-Engine;[RimeProbe]::RimeDeployerInitialize([ref]$traits);$path=Join-Path $out $name;Check $name ([RimeProbe]::ExportUserDict('luna_pinyin',$path) -gt 0);Close-Engine;return @([IO.File]::ReadAllLines($path,$utf8)|Where-Object {$_ -and -not $_.StartsWith('#')}) -join "`n"}
$errorText=$null;$samples=@();$inputHashes=[ordered]@{}
foreach($name in @('essay.txt','luna_pinyin.dict.yaml','luna_pinyin.research.dict.yaml','pc_research.schema.yaml','pc_research.custom.yaml','lua/cn_translator.lua','lua/cn_dlc.lua','lua/rymcp_dlc.lua')){$inputHashes[$name]=(Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $user $name)).Hash.ToLowerInvariant()}
try{
 [RimeProbe]::RimeSetup([ref]$traits)
 Redeploy
 Check 'neutral-no-dlc' (@((Query $codes[0]).Candidates) -notcontains $words[0])
 Check 'base-chinese' (@((Query 'ni hao').Candidates) -contains ([string][char]0x4f60+[char]0x597d))
 foreach($id in $ids){$samples+=Public-Sample $id}
 $script:phase='ActualFull'
 Close-Engine
 foreach($id in $ids){$directory=Join-Path $user ('rymcp_dlc/'+$id);[void][IO.Directory]::CreateDirectory((Split-Path $directory -Parent));Copy-Item -LiteralPath (Join-Path $moduleSource $id) -Destination $directory -Recurse}
 Redeploy
 Check-Tables 'actual-full'
 foreach($sample in $samples){Check ('actual-query-'+$sample.Id) (@((Query $sample.Code -Exact).Candidates) -contains $sample.Text)}
 $poetry=$samples|Where-Object {$_.Id -eq 'poetry'}
 $cacheBefore=@(Get-ChildItem -LiteralPath (Join-Path $user 'build') -Filter 'rymcp_dlc_poetry_??.table.bin' -File|Sort-Object Name|Get-FileHash -Algorithm SHA256|ForEach-Object {$_.Hash}) -join "`n"
 Check 'actual-full-shards-present' ($cacheBefore.Split("`n").Count -eq 32)
 Close-Engine
 $installed=Join-Path $user 'rymcp_dlc/poetry';$held=Join-Path $out 'held/poetry'
 Assert-Isolated $installed;Assert-Isolated $held;[void][IO.Directory]::CreateDirectory((Split-Path $held -Parent))
 Move-Item -LiteralPath $installed -Destination $held
 Redeploy
 Check 'actual-delete-static-word-gone' (@((Query $poetry.Code -Exact).Candidates) -notcontains $poetry.Text)
 Check 'actual-delete-keeps-base' (@((Query 'ni hao').Candidates) -contains ([string][char]0x4f60+[char]0x597d))
 Check 'actual-delete-keeps-other-module' (@((Query $samples[0].Code -Exact).Candidates) -contains $samples[0].Text)
 Check 'actual-delete-keeps-stale-cache' ((@(Get-ChildItem -LiteralPath (Join-Path $user 'build') -Filter 'rymcp_dlc_poetry_??.table.bin' -File)).Count -eq 32)
 Close-Engine;Move-Item -LiteralPath $held -Destination $installed;Redeploy
 Check 'actual-restore-candidate' (@((Query $poetry.Code -Exact).Candidates) -contains $poetry.Text)
 $cacheAfter=@(Get-ChildItem -LiteralPath (Join-Path $user 'build') -Filter 'rymcp_dlc_poetry_??.table.bin' -File|Sort-Object Name|Get-FileHash -Algorithm SHA256|ForEach-Object {$_.Hash}) -join "`n"
 Check 'actual-restore-identical-table-cache' ($cacheBefore -ceq $cacheAfter)
 # Update and learning checks use 35 tiny packs instead of recompiling the
 # complete poetry corpus for every fixture mutation.
 $script:phase='FixtureLifecycle';Close-Engine
 for($i=0;$i -lt 4;$i++){Write-Module $i}
 Redeploy;Check-Tables 'fixture'
 for($i=0;$i -lt 4;$i++){Check ('coexist-'+$ids[$i]) (@((Query $codes[$i]).Candidates) -contains $words[$i])}
 $snapshot=Query $codes[0];$index=[Array]::IndexOf([string[]]$snapshot.Candidates,$words[0])
 Check 'learn-selected-native-phrase' ([RimeProbe]::SelectCandidate($script:s,$index) -ne 0)
 [void][RimeProbe]::RimeCommitComposition($script:s);[void][RimeProbe]::ReadCommit($script:s)
 $before=Export-Learning 'synthetic-learning-before.tsv'
 Write-Module 2 'DLCComputerUpdatedFixture' '2';Redeploy
 $snapshot=Query $codes[2]
 Check 'update-new-word' (@($snapshot.Candidates) -contains 'DLCComputerUpdatedFixture')
 Check 'update-old-word-gone' (@($snapshot.Candidates) -notcontains $words[2])
 Close-Engine;Remove-Module 'physics';Redeploy
 Check 'uninstall-cache-retained' (Test-Path -LiteralPath (Join-Path $user 'build/rymcp_dlc_physics.table.bin'))
 Check 'uninstall-static-word-gone' (@((Query $codes[1]).Candidates) -notcontains $words[1])
 Check 'uninstall-keeps-others' (@((Query $codes[3]).Candidates) -contains $words[3])
 $after=Export-Learning 'synthetic-learning-after.tsv';Check 'learning-preserved' ($before -ceq $after)
 foreach($id in $ids){Remove-Module $id};Redeploy
 Check 'all-uninstalled-base-works' (@((Query 'ni hao').Candidates) -contains ([string][char]0x4f60+[char]0x597d))
 Check 'all-uninstalled-poetry-static-gone' (@((Query $codes[3]).Candidates) -notcontains $words[3])
 Close-Engine;Write-Module 0;Redeploy
 Check 'reinstall-candidate' (@((Query $codes[0]).Candidates) -contains $words[0])
 $reinstalled=Export-Learning 'synthetic-learning-reinstalled.tsv';Check 'reinstall-learning-preserved' ($before -ceq $reinstalled)
}catch{$errorText=$_.Exception.Message}finally{
 Close-Engine
 @{Format='cn-dlc-profile-lifecycle-v2';Profile=$Profile;ActualFull=@{Checks=@($checks|Where-Object {$_.Phase -eq 'ActualFull'}).Count;Samples=$samples};FixtureLifecycle=@{Checks=@($checks|Where-Object {$_.Phase -eq 'FixtureLifecycle'}).Count;PoetryRows=32};InputHashes=$inputHashes;Deployments=@($deployments);Completed=($null -eq $errorText);Error=$errorText;Checks=@($checks)}|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $out 'results.json') -Encoding UTF8
}
if($errorText){throw $errorText}
Write-Output ('CN DLC '+$Profile+': '+$checks.Count+' checks passed.')
