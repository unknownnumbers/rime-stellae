# SPDX-License-Identifier: GPL-3.0-only
#Requires -Version 7.2
param(
  [Parameter(Mandatory)][string]$NewInstaller,
  [Parameter(Mandatory)][string]$SchemeSource,
  [Parameter(Mandatory)][ValidateSet('Personal','ProductCopy')][string]$Configuration,
  [Parameter(Mandatory)][string]$OutputDirectory
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or -not [Environment]::Is64BitProcess){throw 'Use a fresh hosted x64 runner'}
$program=Join-Path $env:ProgramFiles 'RimeStellae'
$user=Join-Path $env:APPDATA 'RimeStellae'
if((Test-Path -LiteralPath $program) -or (Test-Path -LiteralPath $user) -or (Get-Process StellaeServer -ErrorAction SilentlyContinue)){throw 'The published upgrade test requires a fresh runner'}
$out=[IO.Path]::GetFullPath($OutputDirectory)
if(-not $out.StartsWith(([IO.Path]::GetFullPath($env:RUNNER_TEMP).TrimEnd('\')+'\'),[StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $out)){throw 'Use a new result directory under RUNNER_TEMP'}
$null=New-Item -ItemType Directory -Path $out
$new=(Resolve-Path -LiteralPath $NewInstaller).Path
$report=[ordered]@{passed=$false;configuration=$Configuration;previousVersion='2026.11.24.1';previousSource='d5230f72ef5c09b14bbdc3247d372e2497811b79';syntheticFixtureOnly=$true;physicalKeyboardTested=$false;checks=@()}
$env:STELLAE_BUNDLE_TEST_TRACE=Join-Path $out 'installer.log'
function Check([string]$Name,[bool]$Passed){$report.checks+=@([ordered]@{name=$Name;passed=$Passed});if(-not $Passed){throw $Name}}
function Run([string]$File,[string[]]$Arguments,[string]$Name,[int]$Timeout=600000){
  $start=[Diagnostics.ProcessStartInfo]::new($File)
  $start.UseShellExecute=$false;$start.CreateNoWindow=$true
  foreach($argument in $Arguments){$start.ArgumentList.Add($argument)}
  $process=[Diagnostics.Process]::Start($start)
  try{if(-not $process.WaitForExit($Timeout)){throw ($Name+' timed out')};if($process.ExitCode -notin @(0,3010)){throw ($Name+' failed, exit '+$process.ExitCode)}}finally{$process.Dispose()}
}
function Stop-Frontend {
  if(Get-Process StellaeServer -ErrorAction SilentlyContinue){Run (Join-Path $program 'StellaeServer.exe') @('/quit') 'stop synthetic frontend' 30000}
  $limit=[DateTime]::UtcNow.AddSeconds(20)
  while((Get-Process StellaeServer -ErrorAction SilentlyContinue) -and [DateTime]::UtcNow -lt $limit){Start-Sleep -Milliseconds 100}
  if(Get-Process StellaeServer -ErrorAction SilentlyContinue){throw 'The synthetic frontend remained running'}
}
function Fetch([string]$Name,[string]$Url,[string]$Sha256,[long]$Bytes){
  $path=Join-Path $out $Name
  Invoke-WebRequest -Uri $Url -OutFile $path -TimeoutSec 240
  Check ('Pinned predecessor '+$Name) ((Get-Item -LiteralPath $path).Length -eq $Bytes -and (Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -ceq $Sha256)
  return $path
}
try{
  $old=Fetch 'previous-installer.exe' 'https://github.com/unknownnumbers/rime-stellae/releases/download/v2026.11.24.1/stellae-2026.11.24.1-installer.exe' '42667a7853929f24bea3b7d3b0b8d9405ddadea83d068d454a50b89400dfaf45' 122917728
  Run $old @('/S') 'published predecessor installation'
  Stop-Frontend
  $shared=Join-Path $program 'data'
  $oldPackage=Get-Content -LiteralPath (Join-Path $program 'package-manifest.json') -Raw|ConvertFrom-Json
  Check 'The actual published bundle is installed' ($oldPackage.bundleVersion -ceq '2026.11.24.1')
  Check 'The predecessor uses its released Chinese schema' (Test-Path -LiteralPath (Join-Path $user 'build/pc_research.schema.yaml'))
  $copied=@()
  if($Configuration -ceq 'ProductCopy'){
    $profile=Get-Content -LiteralPath (Join-Path $shared 'config-source-manifest.json') -Raw|ConvertFrom-Json
    foreach($entry in @($profile.source_files)+@($profile.generated_files)){
      if($entry.archive_sha256 -cne $entry.sha256 -or $entry.archive_path -cnotlike 'UserProfile/*'){continue}
      $relative=$entry.archive_path.Substring('UserProfile/'.Length)
      $origin=Join-Path $shared $entry.path
      $target=Join-Path $user $relative
      $null=New-Item -ItemType Directory -Path (Split-Path $target) -Force
      Copy-Item -LiteralPath $origin -Destination $target
      $copied+=@($relative)
    }
    Check 'The canonical released user-copy entrypoint is present' ('rime.lua' -in $copied)
    Check 'The canonical released user-copy defaults are present' ('default.custom.yaml' -in $copied)
  }else{
    [IO.File]::WriteAllText((Join-Path $user 'default.custom.yaml'),"# Synthetic personal switcher setting.`npatch:`n  switcher/abbreviate_options: false`n")
  }
  $defaultBefore=(Get-FileHash -LiteralPath (Join-Path $user 'default.custom.yaml')).Hash
  [IO.File]::WriteAllText((Join-Path $user 'weasel.custom.yaml'),"# Synthetic personal appearance setting.`npatch:`n  style/font_point: 17`n  style/horizontal: false`n")
  $appearanceBefore=(Get-FileHash -LiteralPath (Join-Path $user 'weasel.custom.yaml')).Hash
  $math=Fetch 'previous-math.zip' 'https://github.com/unknownnumbers/rime-stellae/releases/download/v2026.11.24.1/stellae-dlc-math-2026.11.24.1.zip' 'e6b568f0292a62a667bfcf43ec35f18c53219e4883dffc383c09b242437ba922' 2592627
  Expand-Archive -LiteralPath $math -DestinationPath $user
  $dlcFixture=@'
import hashlib,json,sys,zlib
from pathlib import Path
user,out=map(Path,sys.argv[1:]);poetry=user/'rymcp_dlc/poetry';poetry.mkdir(parents=True)
payload={}
payload['words.dict.yaml']=b"---\nname: rymcp_dlc/poetry/words\nversion: '1'\nsort: by_weight\nuse_preset_vocabulary: false\npatch:\n  __include: rymcp_dlc/poetry/words_00.dict:/activation\n...\n"
packs=''.join('    - rymcp_dlc_poetry_%02d\n'%i for i in range(32))
for i in range(32):
 activation=('activation:\n  __include: rymcp_dlc/poetry/words_%02d.dict:/activation\n'%(i+1) if i<31 else 'activation:\n  translator/packs/+:\n'+packs)
 header="---\nname: rymcp_dlc/poetry/words_%02d\nversion: '1'\nsort: by_weight\nuse_preset_vocabulary: false\n"%i
 payload['words_%02d.dict.yaml'%i]=(header+activation+'...\n'+chr(0x7532)+chr(0x8bd7)+'\tjia shi\t100\n').encode()
for name,raw in payload.items():(poetry/name).write_bytes(raw)
manifest=['format\t1','id\tpoetry','revision\t1','languages\tcn']+['file\t%s\t%d\t%08x'%(name,len(raw),zlib.adler32(raw)&0xffffffff) for name,raw in sorted(payload.items())]
(poetry/'manifest.tsv').write_text('\n'.join(manifest)+'\n',encoding='utf-8')
rows=[]
for domain in ('math','poetry'):
 root=user/'rymcp_dlc'/domain
 for path in sorted(root.rglob('*')):
  if not path.is_file():continue
  rel=path.relative_to(user/'rymcp_dlc').as_posix();raw=path.read_bytes()
  if path.name.endswith('.dict.yaml'):
   marker=b'\n...\n';assert marker in raw;raw=raw.split(marker,1)[1];kind='dictionary-body'
  elif rel.endswith('manifest.tsv'):continue
  else:kind='byte-exact-resource'
  rows.append({'path':rel,'kind':kind,'sha256':hashlib.sha256(raw).hexdigest()})
out.write_text(json.dumps(rows,indent=2)+'\n',encoding='utf-8')
'@
  & python -c $dlcFixture $user (Join-Path $out 'dlc-before.json')
  if($LASTEXITCODE){throw 'The synthetic predecessor DLC fixture failed'}
  Run (Join-Path $program 'StellaeDeployer.exe') @('/deploy') 'predecessor DLC deployment'
  Stop-Frontend
  $shell=(Get-Process -Id $PID).Path
  Run $shell @('-NoProfile','-File',(Join-Path $PSScriptRoot 'Test-PublicUpgradeLearning.ps1'),'-Phase','Before','-SchemeSource',$SchemeSource,'-OutputDirectory',(Join-Path $out 'learning-before')) 'predecessor genuine learning'
  Run $new @('/S') 'published bundle coverage upgrade'
  Stop-Frontend
  Check 'Personal appearance bytes migrate exactly' ((Get-FileHash -LiteralPath (Join-Path $user 'stellae.custom.yaml')).Hash -ceq $appearanceBefore)
  Check 'The former appearance filename is archived' (-not (Test-Path -LiteralPath (Join-Path $user 'weasel.custom.yaml')))
  if($Configuration -ceq 'Personal'){
    Check 'Personal default override bytes are preserved' ((Get-FileHash -LiteralPath (Join-Path $user 'default.custom.yaml')).Hash -ceq $defaultBefore)
  }else{
    Check 'The former product default copy is retired' (-not (Test-Path -LiteralPath (Join-Path $user 'default.custom.yaml')))
    Check 'The former product Lua entrypoint is retired' (-not (Test-Path -LiteralPath (Join-Path $user 'rime.lua')))
    $oldLua=@($copied|Where-Object {$_ -like 'lua/*.lua' -and (Test-Path -LiteralPath (Join-Path $user $_))})
    Check 'No old flat product modules shadow the current shared modules' ($oldLua.Count -eq 0)
  }
  Check 'Old user schema copies are retired' (-not (Test-Path -LiteralPath (Join-Path $user 'pc_research.schema.yaml')) -and -not (Test-Path -LiteralPath (Join-Path $user 'jp_sela.schema.yaml')))
  $compiled=Get-Content -LiteralPath (Join-Path $user 'build/default.yaml') -Raw
  Check 'The deployed default schema list uses the current entries' ($compiled -match 'schema: cn_stellae' -and $compiled -match 'schema: jp_stellae' -and $compiled -notmatch 'schema: (?:pc_research|jp_sela)')
  $appearance=Get-Content -LiteralPath (Join-Path $user 'build/stellae.yaml') -Raw
  Check 'Personal font size is effective under the new config ID' ($appearance -match '(?m)^\s+font_point: 17\s*$')
  Check 'The old compiled appearance is archived' (-not (Test-Path -LiteralPath (Join-Path $user 'build/weasel.yaml')))
  $verifyDlc=@'
import hashlib,json,sys
from pathlib import Path
user,before=map(Path,sys.argv[1:]);rows=json.loads(before.read_bytes());root=user/'stellae_dlc'
assert root.is_dir() and not (user/'rymcp_dlc').exists()
for row in rows:
 raw=(root/row['path']).read_bytes()
 if row['kind']=='dictionary-body':raw=raw.split(b'\n...\n',1)[1]
 assert hashlib.sha256(raw).hexdigest()==row['sha256'],row['path']
config=(user/'build/cn_stellae.schema.yaml').read_text('utf-8-sig')
assert 'stellae_dlc_math' in config and 'stellae_dlc_poetry_31' in config
print(json.dumps({'passed':True,'preservedDlcResources':len(rows),'mathAndPoetryReconnected':True}))
'@
  & python -c $verifyDlc $user (Join-Path $out 'dlc-before.json')
  if($LASTEXITCODE){throw 'The predecessor DLC content or activation changed'}
  Run $shell @('-NoProfile','-File',(Join-Path $PSScriptRoot 'Test-PublicUpgradeLearning.ps1'),'-Phase','After','-SchemeSource',$SchemeSource,'-OutputDirectory',(Join-Path $out 'learning-after'),'-Baseline',(Join-Path $out 'learning-before/result.json')) 'migrated genuine learning'
  $manifest=Get-Content -LiteralPath (Join-Path $program 'package-manifest.json') -Raw|ConvertFrom-Json
  foreach($arch in @('x64','x86')){
    $name=if($arch -ceq 'x64'){'stellaex64.dll'}else{'stellae.dll'}
    $record=@($manifest.files|Where-Object {($_.PSObject.Properties['path'] -and $_.path -ceq $name) -or ($_.PSObject.Properties['installed_path'] -and $_.installed_path -ceq $name)})
    Check ('One installed '+$arch+' client provenance record') ($record.Count -eq 1)
    $clientShell=Join-Path $env:WINDIR $(if($arch -ceq 'x64'){'System32/WindowsPowerShell/v1.0/powershell.exe'}else{'SysWOW64/WindowsPowerShell/v1.0/powershell.exe'})
    Run $clientShell @('-NoProfile','-File',(Join-Path $PSScriptRoot 'Probe-InstalledClient.ps1'),'-Architecture',$arch,'-ExpectedSha256',$record[0].sha256,'-ReportFile',(Join-Path $out ('loaded-client-'+$arch+'.json'))) ($arch+' registered image load')
  }
  $report.oldProductUserCopies=$copied
  $report.passed=$true
}finally{
  $report|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $out 'result.json') -Encoding UTF8
}
Write-Output ('PASS actual published bundle upgrade '+$Configuration+': '+$report.checks.Count)
