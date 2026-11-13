# SPDX-License-Identifier: GPL-3.0-only
param(
  [Parameter(Mandatory)][string]$EngineDll,
  [Parameter(Mandatory)][string]$SharedData,
  [Parameter(Mandatory)][string]$SchemeSource,
  [Parameter(Mandatory)][string]$OutputDirectory,
  [string]$SeedBuildDirectory,
  [ValidateSet('All','Absent','Empty','Override')][string]$Case='All'
)
$ErrorActionPreference='Stop'
$out=[IO.Path]::GetFullPath($OutputDirectory)
if(Test-Path -LiteralPath $out){throw 'Choose a fresh synthetic output directory.'}
New-Item -ItemType Directory -Path $out | Out-Null
$dll=[IO.Path]::GetFullPath($EngineDll)
$shared=[IO.Path]::GetFullPath($SharedData)
$scheme=[IO.Path]::GetFullPath($SchemeSource)
foreach($name in @('rymcp_bundle_default.yaml','rymcp_bundle_weasel.yaml')){
  if(-not(Test-Path -LiteralPath (Join-Path $shared $name))){throw 'Missing namespaced bundle preset.'}
}
if($Case -eq 'All'){
  $hostExe=(Get-Process -Id $PID).Path
  $reports=@()
  foreach($scenario in @('Absent','Empty','Override')){
    $caseOut=Join-Path $out $scenario.ToLowerInvariant()
    $seed=$SeedBuildDirectory
    if($scenario -ne 'Absent'){$seed=Join-Path $out 'absent/user/build'}
    $arguments=@('-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,
      '-EngineDll',$dll,'-SharedData',$shared,'-SchemeSource',$scheme,
      '-OutputDirectory',$caseOut,'-Case',$scenario)
    if($seed){$arguments+=@('-SeedBuildDirectory',$seed)}
    & $hostExe @arguments
    if($LASTEXITCODE -ne 0){throw ('Bundle preset priority failed: '+$scenario)}
    $report=Get-Content -LiteralPath (Join-Path $caseOut 'result.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if(-not $report.passed -or $report.checks -lt 20){throw 'Preset validation is incomplete.'}
    $reports+=$report
  }
  $summary=[ordered]@{passed=$true;checks=($reports|Measure-Object -Property checks -Sum).Sum;cases=$reports;syntheticOnly=$true}
  $summary|ConvertTo-Json -Depth 8|Set-Content -LiteralPath (Join-Path $out 'result.json') -Encoding UTF8
  [pscustomobject]@{passed=$true;checks=$summary.checks;cases=@($reports|Select-Object case,passed,checks)}|ConvertTo-Json -Depth 5
  exit 0
}

$user=Join-Path $out 'user'
$build=Join-Path $user 'build'
New-Item -ItemType Directory -Path $build -Force | Out-Null
'{"kind":"fixed-synthetic-profile","format":1}'|Set-Content -LiteralPath (Join-Path $user '.synthetic-profile.json') -Encoding UTF8
if($SeedBuildDirectory){
  $seed=[IO.Path]::GetFullPath($SeedBuildDirectory)
  if(-not(Test-Path -LiteralPath (Join-Path (Split-Path $seed -Parent) '.synthetic-profile.json'))){throw 'A seed must belong to a marked synthetic profile.'}
  foreach($file in Get-ChildItem -LiteralPath $seed -File -Filter '*.bin'){
    if($file.Name -match 'userdb|\.log|\.pdb'){throw 'Unexpected seed file.'}
    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $build $file.Name)
  }
}
$utf8=[Text.UTF8Encoding]::new($false)
if($Case -eq 'Empty'){
  foreach($name in @('default.custom.yaml','weasel.custom.yaml')){[IO.File]::WriteAllBytes((Join-Path $user $name),[byte[]]@())}
}elseif($Case -eq 'Override'){
  $custom=@'
patch:
  schema_list:
    - schema: jp_sela
    - schema: pc_research
  switcher/hotkeys: [F4]
  key_binder/bindings/+:
    - {when: always, accept: F9, toggle: ascii_punct}
'@
  [IO.File]::WriteAllText((Join-Path $user 'default.custom.yaml'),$custom,$utf8)
  [IO.File]::WriteAllText((Join-Path $user 'weasel.custom.yaml'),"patch:`n  style/font_point: 17`n",$utf8)
}
$source=[IO.File]::ReadAllText((Join-Path $scheme 'tests/RimeProbe.cs'))
Add-Type -TypeDefinition $source.Replace('__RIME_ENGINE_DLL__',$dll)
$configApi=@'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class BundlePresetConfigApi {
  [DllImport(@"__RIME_ENGINE_DLL__",CallingConvention=CallingConvention.Cdecl)] static extern IntPtr rime_get_api();
  [StructLayout(LayoutKind.Sequential)] struct Config { public IntPtr ptr; }
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Deploy([MarshalAs(UnmanagedType.LPStr)] string file,[MarshalAs(UnmanagedType.LPStr)] string version);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Open([MarshalAs(UnmanagedType.LPStr)] string id,ref Config config);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int Close(ref Config config);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate IntPtr GetText(ref Config config,[MarshalAs(UnmanagedType.LPStr)] string key);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate int GetNumber(ref Config config,[MarshalAs(UnmanagedType.LPStr)] string key,out int value);
  [UnmanagedFunctionPointer(CallingConvention.Cdecl)] delegate UIntPtr ListSize(ref Config config,[MarshalAs(UnmanagedType.LPStr)] string key);
  static T Function<T>(int index) where T:class {
    IntPtr api=rime_get_api(); int offset=IntPtr.Size+index*IntPtr.Size;
    if(api==IntPtr.Zero || Marshal.ReadInt32(api)+4<offset+IntPtr.Size)throw new InvalidOperationException("API field unavailable");
    IntPtr function=Marshal.ReadIntPtr(api,offset);
    if(function==IntPtr.Zero)throw new InvalidOperationException("API function unavailable");
    return (T)(object)Marshal.GetDelegateForFunctionPointer(function,typeof(T));
  }
  public static bool DeployConfig(string name){return Function<Deploy>(11)(name,"config_version")!=0;}
  public static string Text(string id,string key){
    Config c=new Config(); if(Function<Open>(36)(id,ref c)==0)throw new InvalidOperationException("Config unavailable: "+id);
    try{IntPtr ptr=Function<GetText>(42)(ref c,key);if(ptr==IntPtr.Zero)return null;int count=0;while(Marshal.ReadByte(ptr,count)!=0)count++;byte[] data=new byte[count];Marshal.Copy(ptr,data,0,count);return Encoding.UTF8.GetString(data);}
    finally{Function<Close>(37)(ref c);}
  }
  public static int Number(string id,string key){
    Config c=new Config(); if(Function<Open>(36)(id,ref c)==0)throw new InvalidOperationException("Config unavailable: "+id);
    try{int value;if(Function<GetNumber>(39)(ref c,key,out value)==0)throw new InvalidOperationException("Config integer unavailable: "+key);return value;}
    finally{Function<Close>(37)(ref c);}
  }
  public static bool Flag(string id,string key){
    Config c=new Config();if(Function<Open>(36)(id,ref c)==0)throw new InvalidOperationException("Config unavailable: "+id);
    try{int value;if(Function<GetNumber>(38)(ref c,key,out value)==0)throw new InvalidOperationException("Config boolean unavailable: "+key);return value!=0;}
    finally{Function<Close>(37)(ref c);}
  }
  public static int Count(string id,string key){
    Config c=new Config();if(Function<Open>(36)(id,ref c)==0)throw new InvalidOperationException("Config unavailable: "+id);
    try{return checked((int)Function<ListSize>(67)(ref c,key).ToUInt64());}finally{Function<Close>(37)(ref c);}
  }
}
'@
Add-Type -TypeDefinition $configApi.Replace('__RIME_ENGINE_DLL__',$dll)
$env:PATH=(Split-Path $dll -Parent)+';'+$env:PATH
$traits=New-Object RimeProbe+Traits
$traits.data_size=[Runtime.InteropServices.Marshal]::SizeOf($traits)-4
$traits.shared_data_dir=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($shared)
$traits.user_data_dir=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($user)
$traits.prebuilt_data_dir=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($build)
$traits.staging_dir=$traits.prebuilt_data_dir
$traits.log_dir=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($out)
$traits.app_name=[Runtime.InteropServices.Marshal]::StringToHGlobalAnsi('rime.bundle_preset_priority')
$traits.min_log_level=2
$checks=[Collections.Generic.List[object]]::new()
$session=[UIntPtr]::Zero
$errorText=$null
function Check([string]$id,[bool]$passed,$actual=$null){
  $checks.Add([pscustomobject]@{id=$id;passed=$passed;actual=$actual})
  if(-not $passed){throw ('Preset assertion failed: '+$id)}
}
function Query([string]$raw){
  [RimeProbe]::RimeClearComposition($session)
  foreach($ch in $raw.ToCharArray()){
    [void][RimeProbe]::RimeProcessKey($session,[int]$ch,0)
    [void][RimeProbe]::RimeProcessKey($session,[int]$ch,0x40000000)
  }
  return [RimeProbe]::Snapshot($session,250)
}
try{
  [RimeProbe]::RimeSetup([ref]$traits)
  [RimeProbe]::RimeInitialize([ref]$traits)
  [RimeProbe]::RimeDeployerInitialize([ref]$traits)
  Check 'workspace-deploy-returned' ([bool][RimeProbe]::RimeDeployWorkspace())
  Check 'weasel-config-deploy-returned' ([BundlePresetConfigApi]::DeployConfig('weasel.yaml'))
  foreach($name in @('default.yaml','weasel.yaml','pc_research.schema.yaml','jp_sela.schema.yaml')){
    $file=Join-Path $build $name
    Check ('compiled-'+$name) (Test-Path -LiteralPath $file)
    $text=[IO.File]::ReadAllText($file)
    Check ('nonempty-'+$name) ($text.Length -gt 100)
  }
  $first=if($Case -eq 'Override'){'jp_sela'}else{'pc_research'}
  $second=if($Case -eq 'Override'){'pc_research'}else{'jp_sela'}
  Check 'exactly-two-schemas' ([BundlePresetConfigApi]::Count('default','schema_list') -eq 2)
  Check 'first-schema' ([BundlePresetConfigApi]::Text('default','schema_list/@0/schema') -ceq $first)
  Check 'second-schema' ([BundlePresetConfigApi]::Text('default','schema_list/@1/schema') -ceq $second)
  $hotkey=if($Case -eq 'Override'){'F4'}else{'Control+grave'}
  Check 'one-switcher-hotkey' ([BundlePresetConfigApi]::Count('default','switcher/hotkeys') -eq 1)
  Check 'expected-switcher-hotkey' ([BundlePresetConfigApi]::Text('default','switcher/hotkeys/@0') -ceq $hotkey)
  $font=if($Case -eq 'Override'){17}else{14}
  Check 'expected-font-point' ([BundlePresetConfigApi]::Number('weasel','style/font_point') -eq $font)
  Check 'preserved-bundle-color' ([BundlePresetConfigApi]::Text('weasel','style/color_scheme') -ceq 'reference_gray')
  Check 'preserved-bundle-preedit' (-not [BundlePresetConfigApi]::Flag('weasel','style/inline_preedit'))
  Check 'preserved-bundle-global-ascii' ([BundlePresetConfigApi]::Flag('weasel','global_ascii'))
  $bindingCount=[BundlePresetConfigApi]::Count('default','key_binder/bindings')
  $accepts=@(for($index=0;$index -lt $bindingCount;$index++){[BundlePresetConfigApi]::Text('default',('key_binder/bindings/@'+$index+'/accept'))})
  Check 'Chinese-shortcut-applied-once' (@($accepts|Where-Object {$_ -ceq 'Control+r'}).Count -eq 1)
  Check 'Japanese-shortcut-applied-once' (@($accepts|Where-Object {$_ -ceq 'Control+e'}).Count -eq 1)
  $expectedF9=if($Case -eq 'Override'){1}else{0}
  Check 'user-binding-applied-once' (@($accepts|Where-Object {$_ -ceq 'F9'}).Count -eq $expectedF9)
  $session=[RimeProbe]::RimeCreateSession()
  $buffer=New-Object byte[] 256
  Check 'actual-initial-schema' ([bool][RimeProbe]::RimeGetCurrentSchema($session,$buffer,[UIntPtr]::new([uint32]256)) -and [Text.Encoding]::UTF8.GetString($buffer).Trim([char]0) -ceq $first)
  Check 'select-Chinese' ([bool][RimeProbe]::RimeSelectSchema($session,'pc_research'))
  Check 'Chinese-default-SC' ([RimeProbe]::RimeGetOption($session,'simplification') -eq 1)
  Check 'actual-Chinese-candidate' ((Query 'nihao').Candidates -ccontains '你好')
  Check 'actual-default-SC-mixed-candidate' ((Query 'wifimima').Candidates -ccontains 'Wi-Fi 密码')
  if($Case -eq 'Override'){
    [RimeProbe]::RimeClearComposition($session)
    $before=[RimeProbe]::RimeGetOption($session,'ascii_punct')
    [void][RimeProbe]::RimeProcessKey($session,0xffc6,0)
    $after=[RimeProbe]::RimeGetOption($session,'ascii_punct')
    [void][RimeProbe]::RimeProcessKey($session,0xffc6,0x40000000)
    Check 'user-binding-real-key-toggle' ($after -ne $before)
    Check 'user-binding-key-release-no-second-toggle' ([RimeProbe]::RimeGetOption($session,'ascii_punct') -eq $after)
  }
  [RimeProbe]::RimeClearComposition($session)
  Check 'select-Japanese' ([bool][RimeProbe]::RimeSelectSchema($session,'jp_sela'))
  [RimeProbe]::RimeSetOption($session,'probe_options_ready',1)
  Check 'actual-Japanese-candidate' ((Query 'qtaberu').Candidates -ccontains '食べる')
  if($Case -eq 'Empty'){
    Check 'empty-default-custom-preserved' ((Get-Item -LiteralPath (Join-Path $user 'default.custom.yaml')).Length -eq 0)
    Check 'empty-weasel-custom-preserved' ((Get-Item -LiteralPath (Join-Path $user 'weasel.custom.yaml')).Length -eq 0)
  }
}catch{$errorText=$_.Exception.Message}
finally{
  if($session -ne [UIntPtr]::Zero){[RimeProbe]::RimeClearComposition($session);[void][RimeProbe]::RimeDestroySession($session)}
  [RimeProbe]::RimeFinalize()
  foreach($ptr in @($traits.shared_data_dir,$traits.user_data_dir,$traits.prebuilt_data_dir,$traits.log_dir,$traits.app_name)){
    if($ptr -ne [IntPtr]::Zero){[Runtime.InteropServices.Marshal]::FreeHGlobal($ptr)}
  }
  $report=[ordered]@{passed=($null -eq $errorText -and $checks.Count -gt 20);case=$Case;checks=$checks.Count;error=$errorText;syntheticOnly=$true;results=$checks.ToArray()}
  $report|ConvertTo-Json -Depth 7|Set-Content -LiteralPath (Join-Path $out 'result.json') -Encoding UTF8
}
if(-not $report.passed){throw ('Bundle preset priority case failed: '+$errorText)}
[pscustomobject]@{case=$Case;passed=$true;checks=$checks.Count}|ConvertTo-Json
