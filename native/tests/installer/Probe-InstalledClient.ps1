# SPDX-License-Identifier: GPL-3.0-only
param([Parameter(Mandatory)][ValidateSet('x64','x86')][string]$Architecture,
      [Parameter(Mandatory)][string]$ExpectedSha256,
      [Parameter(Mandatory)][string]$ReportFile)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
function Hash([string]$Path){
  $algorithm=[Security.Cryptography.SHA256]::Create()
  $stream=$null
  try{$stream=[IO.File]::OpenRead($Path);return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}
  finally{if($stream){$stream.Dispose()};$algorithm.Dispose()}
}
$report=[ordered]@{passed=$false;stage='host-guard';architecture=$Architecture;registeredPath=$null;registeredPhysicalPath=$null;loadedPath=$null;loadedPhysicalPath=$null;expectedSha256=$ExpectedSha256;beforeSha256=$null;sha256=$null;physicalKeyboardTested=$false;error=$null}
$module=[IntPtr]::Zero
try{
  if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted'){throw 'Use only the disposable hosted CI installation'}
  $report.stage='architecture'
  if([Environment]::Is64BitProcess -ne ($Architecture -ceq 'x64')){throw 'The client probe host has the wrong architecture'}
  $report.stage='registration'
  $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('Software\Classes\CLSID\{0230F8DE-23D2-4E61-B45B-B6DB84E71145}\InprocServer32')
  try{$registered=if($key){[string]$key.GetValue('')}else{''}}finally{if($key){$key.Dispose()}}
  if(-not $registered){throw 'The installed COM client registration is missing'}
  $registered=[IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($registered).Trim('"'))
  $report.registeredPath=$registered
  if(-not (Test-Path -LiteralPath $registered -PathType Leaf)){throw 'The registered client file is missing'}
  $report.stage='native-helper'
  Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class PublicUpgradeClient {
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
  public static extern IntPtr LoadLibraryEx(string path,IntPtr file,uint flags);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
  public static extern uint GetModuleFileName(IntPtr module,StringBuilder name,uint size);
  [DllImport("kernel32.dll")] public static extern bool FreeLibrary(IntPtr module);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateFile(string name,uint access,uint sharing,IntPtr security,uint disposition,uint flags,IntPtr template);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint GetFinalPathNameByHandle(IntPtr file,StringBuilder path,int size,uint flags);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  public static string PhysicalFile(string name) {
    IntPtr handle=CreateFile(name,0x80,7,IntPtr.Zero,3,0x80,IntPtr.Zero);
    if(handle==new IntPtr(-1))throw new Win32Exception(Marshal.GetLastWin32Error());
    try {
      StringBuilder path=new StringBuilder(32768);
      uint length=GetFinalPathNameByHandle(handle,path,path.Capacity,0);
      if(length==0 || length>=path.Capacity)throw new Win32Exception(Marshal.GetLastWin32Error());
      string result=path.ToString();
      return result.StartsWith(@"\\?\",StringComparison.Ordinal)?result.Substring(4):result;
    } finally {CloseHandle(handle);}
  }
}
'@
  $report.stage='registered-image'
  $report.registeredPhysicalPath=[IO.Path]::GetFullPath([PublicUpgradeClient]::PhysicalFile($registered))
  $report.beforeSha256=Hash $report.registeredPhysicalPath
  if($report.beforeSha256 -cne $ExpectedSha256){throw 'The registered client bytes differ from the current installer'}
  $report.stage='load-library'
  $module=[PublicUpgradeClient]::LoadLibraryEx($registered,[IntPtr]::Zero,8)
  if($module -eq [IntPtr]::Zero){throw ('The registered client could not load, Win32 error '+[Runtime.InteropServices.Marshal]::GetLastWin32Error())}
  $report.stage='loaded-image'
  $path=[Text.StringBuilder]::new(32768)
  $length=[PublicUpgradeClient]::GetModuleFileName($module,$path,32768)
  if($length -eq 0 -or $length -ge 32768){throw 'The actual loaded client path is unavailable'}
  $report.loadedPath=$path.ToString()
  $report.loadedPhysicalPath=[IO.Path]::GetFullPath([PublicUpgradeClient]::PhysicalFile($report.loadedPath))
  $report.sha256=Hash $report.loadedPhysicalPath
  if($report.loadedPhysicalPath -ine $report.registeredPhysicalPath -or $report.sha256 -cne $ExpectedSha256){throw 'Windows loaded a different client image from the current installer'}
  $report.passed=$true;$report.stage='complete'
}catch{
  $report.error=[ordered]@{message=$_.Exception.Message;type=$_.Exception.GetType().FullName;position=$_.InvocationInfo.PositionMessage}
  throw
}finally{
  if($module -ne [IntPtr]::Zero){[PublicUpgradeClient]::FreeLibrary($module)|Out-Null}
  [IO.File]::WriteAllText([IO.Path]::GetFullPath($ReportFile),($report|ConvertTo-Json -Depth 5)+"`n",[Text.UTF8Encoding]::new($false))
}
