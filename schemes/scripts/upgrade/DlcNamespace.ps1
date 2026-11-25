# SPDX-License-Identifier: GPL-3.0-only
param(
  [Parameter(Mandatory)][ValidateSet('Preflight','Prepare','Apply','Finalize','Rollback')][string]$Action,
  [string]$UserDirectory,
  [Parameter(Mandatory)][string]$StateFile,
  [string]$RequiredFlag,
  [string]$BackupDirectory,
  [ValidateSet('stellae','weasel')][string]$AppearanceConfigId='stellae'
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if(-not $UserDirectory){
  $registry=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,[Microsoft.Win32.RegistryView]::Registry32)
  try{$key=$registry.OpenSubKey('Software\RimeStellae');try{if($key){$UserDirectory=[string]$key.GetValue('RimeUserDir','')}}finally{if($key){$key.Dispose()}}}finally{$registry.Dispose()}
  if(-not $UserDirectory){$UserDirectory=Join-Path $env:APPDATA 'RimeStellae'}
}
$user=[IO.Path]::GetFullPath($UserDirectory).TrimEnd([char[]]'\/')
$statePath=[IO.Path]::GetFullPath($StateFile)
$known=@('math','physics','computer','poetry')
function Child([string]$Root,[string]$Relative){
  if([IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)|:'){throw 'Invalid module migration path'}
  $base=[IO.Path]::GetFullPath($Root).TrimEnd([char[]]'\/')
  $path=[IO.Path]::GetFullPath((Join-Path $base $Relative))
  if(-not $path.StartsWith($base+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Module path escapes its root'}
  for($current=$path;$current -and $current.Length -ge $base.Length;$current=Split-Path $current -Parent){
    if((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'Redirected module migration path'}
  }
  return $path
}
function Save-State($Value){
  $parent=Split-Path $statePath -Parent
  $null=New-Item -ItemType Directory -Path $parent -Force
  [IO.File]::WriteAllText($statePath,($Value|ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
}
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
if($Action -eq 'Preflight'){
  $modules=@()
  foreach($id in $known){
    $old=Child $user ('rymcp_dlc/'+$id);$new=Child $user ('stellae_dlc/'+$id)
    if(Test-Path -LiteralPath $old){
      if(-not (Test-Path -LiteralPath $old -PathType Container)){throw 'A previous module path is not a directory'}
      if(Test-Path -LiteralPath $new){throw ('Old and new module directories both exist; merge them before upgrading: '+$id)}
      if(-not (Test-Path -LiteralPath (Child $old 'manifest.tsv') -PathType Leaf)){throw ('A previous module has no source manifest: '+$id)}
      $modules+=@($id)
    }
  }
  $state=[ordered]@{format='stellae-dlc-namespace-upgrade-v1';userDirectory=$user;needsMigration=($modules.Count -gt 0);modules=$modules;stage='preflight';archive=$null;files=@();createdModules=@();retiredModules=@();oldReferences=@();originalModulesRetained=@();passed=$true}
  Save-State $state
  if($RequiredFlag -and $state.needsMigration){[IO.File]::WriteAllBytes($RequiredFlag,[byte[]]@())}
  Write-Output ('DLC namespace preflight: '+$modules.Count+' module(s)')
  return
}
$state=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8|ConvertFrom-Json
if($state.format -cne 'stellae-dlc-namespace-upgrade-v1' -or $state.userDirectory -ine $user -or -not $state.passed -or @($state.modules|Where-Object {$_ -cnotin $known}).Count){throw 'Unexpected module migration state'}
if(-not $state.needsMigration){Write-Output 'No previous module namespace requires migration';return}
if(-not ('DlcNamespaceFiles' -as [type])){
  Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
public static class DlcNamespaceFiles {
  public sealed class Info { public long Bytes; public string Sha256; public string Adler32; }
  public static Info Facts(string path) {
    long length=0; uint a=1,b=0; byte[] buffer=new byte[1048576];
    using(var sha=SHA256.Create()) using(var f=File.OpenRead(path)) {
      int n; while((n=f.Read(buffer,0,buffer.Length))>0) {
        sha.TransformBlock(buffer,0,n,buffer,0); length+=n;
        for(int start=0;start<n;start+=5552) { int end=Math.Min(start+5552,n); for(int i=start;i<end;i++){a+=buffer[i];b+=a;} a%=65521;b%=65521; }
      }
      sha.TransformFinalBlock(new byte[0],0,0);
      return new Info { Bytes=length,Sha256=BitConverter.ToString(sha.Hash).Replace("-","").ToLowerInvariant(),Adler32=((b<<16)|a).ToString("x8") };
    }
  }
  static byte[] Header(Stream f) {
    using(var result=new MemoryStream()) using(var line=new MemoryStream()) {
      int value; while((value=f.ReadByte())>=0) {
        result.WriteByte((byte)value);line.WriteByte((byte)value);
        if(result.Length>65536)throw new InvalidDataException("Module dictionary header is too large");
        if(value==10) { string s=Encoding.ASCII.GetString(line.ToArray()).TrimEnd('\r','\n');line.SetLength(0);if(s=="...")return result.ToArray(); }
      }
      throw new InvalidDataException("Module dictionary header terminator is missing");
    }
  }
  static string TailHash(string path,int skip) {
    using(var f=File.OpenRead(path))using(var sha=SHA256.Create()){f.Position=skip;return BitConverter.ToString(sha.ComputeHash(f)).Replace("-","");}
  }
  public static void Rewrite(string source,string target,string expected) {
    byte[] oldHeader,newHeader;var utf8=new UTF8Encoding(false,true);
    using(var input=File.OpenRead(source)) {
      oldHeader=Header(input);string text=utf8.GetString(oldHeader);
      MatchCollection names=Regex.Matches(text,@"(?m)^name:[ \t]*([^\r\n]+)");
      if(names.Count!=1||names[0].Groups[1].Value.Trim().Trim('\"','\'')!=expected)throw new InvalidDataException("Module dictionary identity differs from its path");
      string changed=Regex.Replace(text,@"(?<![A-Za-z0-9_])rymcp_dlc(?=[_/])","stellae_dlc");
      if(changed==text)throw new InvalidDataException("Module dictionary namespace is missing");
      newHeader=utf8.GetBytes(changed);
      using(var output=new FileStream(target,FileMode.CreateNew,FileAccess.Write)){output.Write(newHeader,0,newHeader.Length);input.CopyTo(output);}
    }
    if(TailHash(source,oldHeader.Length)!=TailHash(target,newHeader.Length))throw new InvalidDataException("Module dictionary body changed");
  }
}
'@
}
function Records([string]$Root){
  $rows=@()
  foreach($entry in Get-ChildItem -LiteralPath $Root -Recurse -Force){
    $relative=$entry.FullName.Substring($Root.TrimEnd([char[]]'\/').Length+1).Replace('\','/')
    $null=Child $Root $relative
    if($relative -match '(^|/)\S*\.userdb($|/)'){throw 'Learning data is outside the module migration scope'}
    if(-not $entry.PSIsContainer){$facts=[DlcNamespaceFiles]::Facts($entry.FullName);$rows+=@([pscustomobject]@{path=$relative;bytes=$facts.Bytes;sha256=$facts.Sha256;adler32=$facts.Adler32})}
  }
  return $rows
}
function Verify-Tree([string]$Root,$Rows,[string]$HashField='sha256'){
  $actual=@(Get-ChildItem -LiteralPath $Root -Recurse -Force -File)
  if($actual.Count -ne @($Rows).Count){throw 'A module file set changed during upgrade'}
  foreach($row in $Rows){$path=Child $Root $row.path;if(-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Hash $path) -cne $row.$HashField){throw 'A module file changed during upgrade'}}
}
function Remove-CreatedModules{
  $remaining=@()
  foreach($id in @($state.createdModules)){
    $rows=@($state.files|Where-Object {$_.module -ceq $id})
    $old=Child $user ('rymcp_dlc/'+$id);$new=Child $user ('stellae_dlc/'+$id)
    if(-not (Test-Path -LiteralPath $new)){continue}
    try{
      Verify-Tree $old $rows
      Verify-Tree $new $rows 'preparedSha256'
      [IO.Directory]::Delete((Child $user ('stellae_dlc/'+$id)),$true)
    }catch{$remaining+=@($id)}
  }
  $state.createdModules=$remaining
  Save-State $state
  if($remaining.Count){throw 'Changed or locked migrated modules were retained for manual recovery'}
}
function Verify-RetirementRemainder([string]$Root,$Rows){
  $expected=@{};foreach($row in $Rows){$expected[$row.path]=$row.sha256}
  foreach($file in Get-ChildItem -LiteralPath $Root -Recurse -Force -File){
    $relative=$file.FullName.Substring($Root.Length+1).Replace('\','/')
    $path=Child $Root $relative
    if(-not $expected.ContainsKey($relative) -or (Hash $path) -cne $expected[$relative]){throw 'Changed files in a partially retired module were retained'}
  }
}
if($Action -eq 'Prepare'){
  if($state.stage -cne 'preflight'){throw 'Module preparation requires a fresh preflight'}
  $base=if($BackupDirectory){[IO.Path]::GetFullPath($BackupDirectory)}else{Join-Path $env:LOCALAPPDATA 'Rime/scheme-upgrades/dlc-namespace'}
  if($base -ieq $user -or $base.StartsWith($user+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Module backups must be outside the user directory'}
  $archive=Child $base ([Guid]::NewGuid().ToString('N'));$null=New-Item -ItemType Directory -Path $archive
  $all=@()
  foreach($id in $state.modules){
    $source=Child $user ('rymcp_dlc/'+$id);$destination=Child $user ('stellae_dlc/'+$id)
    if(Test-Path -LiteralPath $destination){throw 'The new module path appeared after preflight'}
    $rows=@(Records $source);$byPath=@{};foreach($row in $rows){$byPath[$row.path]=$row}
    $raw=Join-Path $archive ('original/'+$id);$stage=Join-Path $archive ('prepared/'+$id)
    $null=New-Item -ItemType Directory -Path $raw,$stage -Force
    foreach($row in $rows){
      $origin=Child $source $row.path;$saved=Child $raw $row.path;$target=Child $stage $row.path
      $null=New-Item -ItemType Directory -Path (Split-Path $saved -Parent),(Split-Path $target -Parent) -Force
      [IO.File]::Copy($origin,$saved,$false)
      if((Hash $saved) -cne $row.sha256){throw 'Module backup differs from the original'}
      if($row.path -ceq 'words.dict.yaml' -or ($id -ceq 'poetry' -and $row.path -cmatch '^words_(0[0-9]|[12][0-9]|3[01])\.dict\.yaml$')){
        $leaf=$row.path.Substring(0,$row.path.Length-'.dict.yaml'.Length)
        [DlcNamespaceFiles]::Rewrite($saved,$target,('rymcp_dlc/'+$id+'/'+$leaf))
      }else{[IO.File]::Copy($saved,$target,$false)}
    }
    $manifest=Child $stage 'manifest.tsv';$text=[Text.UTF8Encoding]::new($false,$true).GetString([IO.File]::ReadAllBytes($manifest))
    foreach($line in ($text -split '\r?\n')){
      if($line.StartsWith("file`t") -and $line -cnotmatch '^file\t[^\t\r\n]+\t[0-9]+\t[0-9a-f]{8}$'){throw 'Malformed module file manifest record'}
    }
    $manifestPaths=@{}
    $text=[regex]::Replace($text,'(?m)^file\t([^\t\r\n]+)\t([0-9]+)\t([0-9a-f]{8})(?=\r?$)',[Text.RegularExpressions.MatchEvaluator]{param($match)
      $relative=$match.Groups[1].Value
      if($manifestPaths.ContainsKey($relative) -or -not $byPath.ContainsKey($relative) -or $relative -ceq 'manifest.tsv'){throw 'Invalid module file manifest'}
      $manifestPaths[$relative]=$true;$before=$byPath[$relative]
      if($before.bytes -ne [long]$match.Groups[2].Value -or $before.adler32 -cne $match.Groups[3].Value){throw 'A module file differs from its source manifest'}
      $facts=[DlcNamespaceFiles]::Facts((Child $stage $relative))
      return ('file'+"`t"+$relative+"`t"+$facts.Bytes+"`t"+$facts.Adler32)
    })
    if($manifestPaths.Count -eq 0){throw 'The module source manifest has no file records'}
    foreach($row in $rows){
      if(($row.path -ceq 'words.dict.yaml' -or ($id -ceq 'poetry' -and $row.path -cmatch '^words_(0[0-9]|[12][0-9]|3[01])\.dict\.yaml$')) -and -not $manifestPaths.ContainsKey($row.path)){throw 'A module dictionary header has no source-manifest record'}
    }
    [IO.File]::WriteAllText($manifest,$text,[Text.UTF8Encoding]::new($false))
    Verify-Tree $source $rows
    foreach($row in $rows){$row|Add-Member -NotePropertyName preparedSha256 -NotePropertyValue (Hash (Child $stage $row.path));$row|Add-Member -NotePropertyName module -NotePropertyValue $id;$all+=@($row)}
  }
  $state.archive=$archive;$state.files=$all;$state.stage='prepared';Save-State $state
  [IO.File]::Copy($statePath,(Join-Path $archive 'migration.json'),$false)
}elseif($Action -eq 'Apply'){
  if($state.stage -cne 'prepared'){throw 'Module activation requires a verified preparation'}
  # Check all modules before publishing any one of them.
  foreach($id in $state.modules){
    $rows=@($state.files|Where-Object {$_.module -ceq $id});$old=Child $user ('rymcp_dlc/'+$id);$new=Child $user ('stellae_dlc/'+$id)
    Verify-Tree $old $rows
    if(Test-Path -LiteralPath $new){throw 'The new module directory already exists'}
    Verify-Tree (Join-Path $state.archive ('prepared/'+$id)) $rows 'preparedSha256'
  }
  try{
    foreach($id in $state.modules){
      $rows=@($state.files|Where-Object {$_.module -ceq $id});$new=Child $user ('stellae_dlc/'+$id)
      $parent=Split-Path $new -Parent;$null=New-Item -ItemType Directory -Path $parent -Force
      $temporary=Child $parent ('.upgrade-'+$id+'-'+[Guid]::NewGuid().ToString('N'))
      $null=New-Item -ItemType Directory -Path $temporary
      try{
        foreach($row in $rows){$source=Child (Join-Path $state.archive ('prepared/'+$id)) $row.path;$target=Child $temporary $row.path;$null=New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force;[IO.File]::Copy($source,$target,$false)}
        Verify-Tree $temporary $rows 'preparedSha256'
        [IO.Directory]::Move($temporary,$new)
      }finally{
        if(Test-Path -LiteralPath $temporary -PathType Container){[IO.Directory]::Delete((Child $parent (Split-Path $temporary -Leaf)),$true)}
      }
      $state.createdModules+=@($id);Save-State $state
    }
    $state.stage='applied';Save-State $state
  }catch{
    Remove-CreatedModules
    throw
  }
}elseif($Action -eq 'Rollback'){
  if($state.stage -cnotin @('prepared','applied') -or @($state.retiredModules).Count){throw 'Retired original modules prevent automatic rollback; retain the verified archives for recovery'}
  Remove-CreatedModules
  $state.stage='rolled-back';Save-State $state
}else{
  if($state.stage -ceq 'finalized'){Write-Output 'Module namespace is already finalized';return}
  if($state.stage -cne 'applied'){throw 'Module retirement requires a completed activation'}
  if(-not (Test-Path -LiteralPath (Child $user ('build/'+$AppearanceConfigId+'.yaml')) -PathType Leaf)){throw 'Deploy the new frontend configuration before retiring old modules'}
  $references=@()
  $configFiles=@(Get-ChildItem -LiteralPath $user -Filter '*.custom.yaml' -File)
  $entry=Child $user 'rime.lua'
  if(Test-Path -LiteralPath $entry -PathType Leaf){$configFiles+=@(Get-Item -LiteralPath $entry)}
  $lua=Child $user 'lua'
  if(Test-Path -LiteralPath $lua -PathType Container){$configFiles+=@(Get-ChildItem -LiteralPath $lua -Filter '*.lua' -Recurse -File)}
  $bridges=@(Get-ChildItem -LiteralPath $user -Filter 'rymcp_dlc_*.dict.yaml' -File)
  foreach($entry in $bridges){$references+=@($entry.Name)}
  $defaults=Child $user 'build/default.yaml'
  if(Test-Path -LiteralPath $defaults -PathType Leaf){
    foreach($match in [regex]::Matches([IO.File]::ReadAllText($defaults),'(?m)^\s*-\s*(?:\{\s*)?schema:\s*[''"]?([A-Za-z0-9_.-]+)')){
      $compiled=Child $user ('build/'+$match.Groups[1].Value+'.schema.yaml')
      if(Test-Path -LiteralPath $compiled -PathType Leaf){$configFiles+=@(Get-Item -LiteralPath $compiled)}
    }
  }
  foreach($entry in $configFiles){if([IO.File]::ReadAllText($entry.FullName) -match 'rymcp_dlc'){$references+=@($entry.Name)}}
  $state.oldReferences=$references
  # Validate every module and archive before retiring any old source.
  foreach($id in $state.modules){
    $rows=@($state.files|Where-Object {$_.module -ceq $id});$old=Child $user ('rymcp_dlc/'+$id);$new=Child $user ('stellae_dlc/'+$id)
    Verify-Tree $new $rows 'preparedSha256';Verify-Tree (Join-Path $state.archive ('original/'+$id)) $rows
    if($references.Count){continue}
    if($id -cin @($state.retiredModules)){
      if(Test-Path -LiteralPath $old -PathType Container){Verify-RetirementRemainder $old $rows}
    }else{Verify-Tree $old $rows}
  }
  foreach($id in $state.modules){
    if($references.Count){if($id -cnotin @($state.originalModulesRetained)){$state.originalModulesRetained+=@($id)};continue}
    $old=Child $user ('rymcp_dlc/'+$id)
    if(-not (Test-Path -LiteralPath $old)){continue}
    # Resolve and validate the exact known module again before recursive removal.
    $verified=Child $user ('rymcp_dlc/'+$id)
    if($verified -ine $old){throw 'Unexpected retired module path'}
    if($id -cnotin @($state.retiredModules)){$state.retiredModules+=@($id);Save-State $state}
    [IO.Directory]::Delete($verified,$true)
  }
  $oldRoot=Child $user 'rymcp_dlc'
  if((Test-Path -LiteralPath $oldRoot -PathType Container) -and @(Get-ChildItem -LiteralPath $oldRoot -Force).Count -eq 0){[IO.Directory]::Delete($oldRoot,$false)}
  $state.stage='finalized';Save-State $state
}
Write-Output ('DLC namespace '+$Action+' completed for '+@($state.modules).Count+' module(s)')
