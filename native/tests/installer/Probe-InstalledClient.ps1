# SPDX-License-Identifier: GPL-3.0-only
param([Parameter(Mandatory)][ValidateSet('x64','x86')][string]$Architecture,
      [Parameter(Mandatory)][string]$ExpectedSha256,
      [Parameter(Mandatory)][string]$ReportFile)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted'){throw 'Use only the disposable hosted CI installation'}
if([Environment]::Is64BitProcess -ne ($Architecture -ceq 'x64')){throw 'The client probe host has the wrong architecture'}
$key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('Software\Classes\CLSID\{0230F8DE-23D2-4E61-B45B-B6DB84E71145}\InprocServer32')
try{$registered=[string]$key.GetValue('')}finally{if($key){$key.Dispose()}}
if(-not $registered -or -not (Test-Path -LiteralPath $registered -PathType Leaf)){throw 'The installed COM client registration is missing'}
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class PublicUpgradeClient {
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
  public static extern IntPtr LoadLibraryEx(string path,IntPtr file,uint flags);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
  public static extern uint GetModuleFileName(IntPtr module,StringBuilder name,uint size);
  [DllImport("kernel32.dll")] public static extern bool FreeLibrary(IntPtr module);
}
'@
$module=[PublicUpgradeClient]::LoadLibraryEx($registered,[IntPtr]::Zero,8)
if($module -eq [IntPtr]::Zero){throw ('The registered client could not load, Win32 error '+[Runtime.InteropServices.Marshal]::GetLastWin32Error())}
try{
  $path=[Text.StringBuilder]::new(32768)
  if(-not [PublicUpgradeClient]::GetModuleFileName($module,$path,32768)){throw 'The actual loaded client path is unavailable'}
  $loaded=$path.ToString()
  $hash=(Get-FileHash -LiteralPath $loaded).Hash.ToLowerInvariant()
  if([IO.Path]::GetFullPath($loaded) -ine [IO.Path]::GetFullPath($registered) -or $hash -cne $ExpectedSha256){throw 'Windows loaded a different client image from the current installer'}
  [ordered]@{passed=$true;architecture=$Architecture;registeredPath=$registered;loadedPath=$loaded;sha256=$hash;physicalKeyboardTested=$false}|ConvertTo-Json|Set-Content -LiteralPath $ReportFile -Encoding UTF8
}finally{[PublicUpgradeClient]::FreeLibrary($module)|Out-Null}
