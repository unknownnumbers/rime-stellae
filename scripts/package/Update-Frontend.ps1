# SPDX-License-Identifier: GPL-3.0-only
#Requires -Version 7.2
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$ProgramDirectory,
  [Parameter(Mandatory)][string]$PayloadDirectory,
  [Parameter(Mandatory)][string]$ExpectedCurrentManifest,
  [Parameter(Mandatory)][string]$ReportFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$program=[IO.Path]::GetFullPath($ProgramDirectory).TrimEnd([char[]]'\/')
$payload=[IO.Path]::GetFullPath($PayloadDirectory).TrimEnd([char[]]'\/')
$reportPath=[IO.Path]::GetFullPath($ReportFile)
$reportDirectory=Split-Path $reportPath -Parent
$allowed=@('stellaex64.dll','stellaex64.ime','StellaeServer.exe','StellaeDeployer.exe','stellae.dll','stellae.ime')
$helperNames=@('Update-Frontend.ps1','profile-policy/InstallProfilePolicy.ps1','profile-policy/NativeProfileSnapshot.ps1')
$phase='preflight'
$script:helperStillRunning=$false
$script:activeHelperPid=$null
function Child([string]$Root,[string]$Relative){
 if([IO.Path]::IsPathRooted($Relative) -or $Relative -match '(^|[\\/])\.\.([\\/]|$)|:'){throw 'Invalid frontend component path.'}
 $path=[IO.Path]::GetFullPath((Join-Path $Root $Relative))
 if(-not $path.StartsWith($Root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'A frontend path escapes its root.'}
 $current=$path
 while($current -and $current.Length -ge $Root.Length){
  if((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'A frontend path is redirected.'}
  $current=Split-Path $current -Parent
 }
 return $path
}
function Hash([string]$Path){(Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()}
function Require-Image([string]$Path,[int]$Machine){
 $reader=[IO.BinaryReader]::new([IO.File]::OpenRead($Path))
 try{
  if($reader.ReadUInt16() -ne 0x5a4d){throw 'Expected a Windows frontend image.'}
  $reader.BaseStream.Position=0x3c;$offset=$reader.ReadUInt32();$reader.BaseStream.Position=$offset
  if($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne $Machine){throw 'Unexpected frontend image architecture.'}
 }finally{$reader.Dispose()}
}
function Write-Atomic([string]$Path,[byte[]]$Bytes){
 $temporary=$Path+'.frontend-'+[guid]::NewGuid().ToString('N')+'.tmp'
 [IO.File]::WriteAllBytes($temporary,$Bytes)
 if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temporary,$Path,[NullString]::Value)}else{[IO.File]::Move($temporary,$Path)}
}
function Save-Json([string]$Path,$Value){
 Write-Atomic $Path ([Text.UTF8Encoding]::new($false).GetBytes(($Value|ConvertTo-Json -Depth 20)+[Environment]::NewLine))
}
function Require-Stopped {
 if(@(Get-Process -Name StellaeServer,StellaeDeployer -ErrorAction SilentlyContinue).Count){throw 'Stop the input service and close the settings program before updating frontend images.'}
}
function Run-Hidden([string]$File,[string[]]$Arguments,[string]$Name){
 $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=$File;$start.WorkingDirectory=$program
 $start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
 foreach($argument in $Arguments){$start.ArgumentList.Add($argument)}
 $process=[Diagnostics.Process]::Start($start)
 $script:activeHelperPid=$process.Id
 try{
  $stdout=$process.StandardOutput.ReadToEndAsync();$stderr=$process.StandardError.ReadToEndAsync()
  if(-not $process.WaitForExit(120000)){$script:helperStillRunning=$true;throw ('An upstream update helper is still running: '+$Name+' pid='+$process.Id)}
  [IO.File]::WriteAllText((Join-Path $reportDirectory ($Name+'.stdout.txt')),$stdout.Result)
  [IO.File]::WriteAllText((Join-Path $reportDirectory ($Name+'.stderr.txt')),$stderr.Result)
  if($process.ExitCode -ne 0){throw ('The upstream update helper failed: '+$Name+' exit='+$process.ExitCode)}
 }finally{$process.Dispose()}
}
try{
 if(-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess){throw 'Use an x64 update process.'}
 $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
 if(-not ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'Frontend component copying requires UAC elevation.'}
 $spec=Get-Content -LiteralPath (Child $payload 'frontend-update-inputs.json') -Raw|ConvertFrom-Json
 $expected=Get-Content -LiteralPath $ExpectedCurrentManifest -Raw|ConvertFrom-Json
 if($spec.format -cne 'stellae-frontend-update-v1' -or $spec.sourceRef -cnotmatch '^[0-9a-f]{40}$' -or
    $spec.componentVersion -cnotmatch '^[0-9]+(\.[0-9]+){2,3}$' -or $spec.runtimeEnginesIncluded -ne $false -or $spec.independent32BitBackendIncluded -ne $false){throw 'Invalid six-image frontend component manifest.'}
 if($expected.format -cne 'stellae-frontend-current-v1' -or [IO.Path]::GetFullPath($expected.programDirectory).TrimEnd([char[]]'\/') -ine $program -or $expected.userSid -cne $identity.User.Value){throw 'The captured installation or Windows user differs.'}
 $names=@($spec.files|ForEach-Object {[string]$_.path})
 $currentNames=@($expected.files|ForEach-Object {[string]$_.path})
 if($names.Count -ne 6 -or @($names|Select-Object -Unique).Count -ne 6 -or (Compare-Object ($allowed|Sort-Object) ($names|Sort-Object)) -or
    $currentNames.Count -ne 6 -or @($currentNames|Select-Object -Unique).Count -ne 6 -or (Compare-Object ($allowed|Sort-Object) ($currentNames|Sort-Object))){throw 'The component and capture must describe exactly six frontend images.'}
 $helpers=@($spec.helpers|ForEach-Object {[string]$_.path})
 if($helpers.Count -ne 3 -or @($helpers|Select-Object -Unique).Count -ne 3 -or (Compare-Object ($helperNames|Sort-Object) ($helpers|Sort-Object))){throw 'The component must retain the existing installer input-profile helpers.'}
 foreach($entry in $spec.helpers){
  $path=Child $payload $entry.path
  if($entry.sha256 -cnotmatch '^[0-9a-f]{64}$' -or (Hash $path) -cne $entry.sha256 -or (Get-Item -LiteralPath $path).Length -ne [long]$entry.bytes){throw 'A component update helper differs.'}
 }
 $updater=@($spec.helpers|Where-Object path -CEQ 'Update-Frontend.ps1')[0]
 if((Hash $PSCommandPath) -cne $updater.sha256){throw 'The updater differs from the reviewed component.'}
 foreach($entry in $spec.files){
  $machine=if($entry.path -cin @('stellae.dll','stellae.ime')){0x014c}else{0x8664}
  $origin=Child $payload $entry.path;$target=Child $program $entry.path
  $before=@($expected.files|Where-Object path -CEQ $entry.path)[0]
  if($entry.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $before.sha256 -cnotmatch '^[0-9a-f]{64}$' -or
     [int]$entry.machine -ne $machine -or (Hash $origin) -cne $entry.sha256 -or (Get-Item -LiteralPath $origin).Length -ne [long]$entry.bytes -or
     (Hash $target) -cne $before.sha256){throw ('A captured or incoming frontend image differs: '+$entry.path)}
  Require-Image $origin $machine
 }
 $setup=Child $program 'StellaeSetup.exe';$runtime=Child $program 'rime.dll';$package=Child $program 'package-manifest.json'
 foreach($entry in @(@{Path=$setup;Expected=$expected.setupSha256},@{Path=$runtime;Expected=$expected.runtimeSha256},@{Path=$package;Expected=$expected.packageManifestSha256})){
  if($entry.Expected -cnotmatch '^[0-9a-f]{64}$' -or (Hash $entry.Path) -cne $entry.Expected){throw 'An installed setup, engine or base-package file differs from the capture.'}
 }
 $settingsPath=Child $program 'settings-component.json'
 if($expected.settingsComponentSha256){if(-not (Test-Path -LiteralPath $settingsPath) -or (Hash $settingsPath) -cne $expected.settingsComponentSha256){throw 'The installed settings component marker differs.'}}
 elseif(Test-Path -LiteralPath $settingsPath){throw 'An uncaptured settings component marker appeared.'}
 if(Test-Path -LiteralPath $settingsPath){
  $settings=Get-Content -LiteralPath $settingsPath -Raw|ConvertFrom-Json
  if($settings.format -cne 'stellae-settings-component-v1' -or @($settings.files|Where-Object path -CEQ 'StellaeDeployer.exe').Count -ne 1){throw 'The existing settings marker has an unsupported format.'}
 }
 $frontendMarker=Child $program 'frontend-component.json'
 if(Test-Path -LiteralPath $frontendMarker){
  if((Get-Content -LiteralPath $frontendMarker -Raw|ConvertFrom-Json).format -cne 'stellae-frontend-component-v1'){throw 'An unrelated frontend marker is preserved.'}
 }
 Require-Stopped
 $base=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,[Microsoft.Win32.RegistryView]::Registry32)
 try{$key=$base.OpenSubKey('Software\RimeStellae');if(-not $key){throw 'The installed output preference is missing.'};try{$hant=[int]$key.GetValue('Hant',-1)}finally{$key.Dispose()}}finally{$base.Dispose()}
 if($hant -notin @(0,1)){throw 'The installed output preference is unknown.'}
 $null=New-Item -ItemType Directory -Path $reportDirectory -Force
 $policy=Child $payload 'profile-policy/InstallProfilePolicy.ps1'
 $powershell=Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
 $state=$reportPath+'.input-before.json'
 if(Test-Path -LiteralPath $state){throw 'Use a fresh frontend update report path.'}
 $phase='capture-input-settings'
 Run-Hidden $powershell @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$policy,'-Action','Capture','-StateFile',$state) 'input-capture'
 $phase='copy-frontend-images'
 Require-Stopped
 foreach($entry in $spec.files){
  Write-Atomic (Child $program $entry.path) ([IO.File]::ReadAllBytes((Child $payload $entry.path)))
 }
 $phase='upstream-setup'
 try{Run-Hidden $setup @($(if($hant){'/t'}else{'/s'})) 'upstream-setup'}
 finally{
  if(-not $script:helperStillRunning){
   $phase='restore-input-settings'
   Run-Hidden $powershell @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$policy,'-Action','Finalize','-StateFile',$state,'-Hant',([string]$hant)) 'input-finalize'
  }
 }
 $policyResult=Get-Content -LiteralPath ($state+'.result.json') -Raw|ConvertFrom-Json
 if(-not $policyResult.Passed){throw 'The existing installer policy did not preserve Windows input settings.'}
 $phase='verify-registration-and-bytes'
 $registered=@()
 foreach($view in @(@{Name='x64';Flag=[Microsoft.Win32.RegistryView]::Registry64;File='stellaex64.dll'},@{Name='x86';Flag=[Microsoft.Win32.RegistryView]::Registry32;File='stellae.dll'})){
  $registry=[Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,$view.Flag)
  try{$key=$registry.OpenSubKey('SOFTWARE\Classes\CLSID\{0230F8DE-23D2-4E61-B45B-B6DB84E71145}\InprocServer32');if(-not $key){throw 'The upstream setup omitted a TSF registration.'};try{$dll=[Environment]::ExpandEnvironmentVariables(([string]$key.GetValue('')).Trim('"'))}finally{$key.Dispose()}}finally{$registry.Dispose()}
  $record=@($spec.files|Where-Object path -CEQ $view.File)[0]
  if((Hash $dll) -cne $record.sha256){throw ('Windows registered frontend bytes differ: '+$view.Name)}
  $registered+=@([ordered]@{architecture=$view.Name;path=$dll;sha256=$record.sha256})
 }
 foreach($entry in $spec.files){if((Hash (Child $program $entry.path)) -cne $entry.sha256){throw 'An installed frontend image differs after upstream setup.'}}
 if((Hash $runtime) -cne $expected.runtimeSha256 -or (Hash $setup) -cne $expected.setupSha256 -or (Hash $package) -cne $expected.packageManifestSha256){throw 'An engine, setup or base-package file changed.'}
 $deployer=@($spec.files|Where-Object path -CEQ 'StellaeDeployer.exe')[0]
 $basePackage=Get-Content -LiteralPath $package -Raw|ConvertFrom-Json
 $marker=[ordered]@{format='stellae-frontend-component-v1';componentVersion=$spec.componentVersion;sourceRef=$spec.sourceRef;files=$spec.files;baseBundleVersion=$basePackage.bundleVersion;runtimeSha256=$expected.runtimeSha256}
 Save-Json $frontendMarker $marker
 if(Test-Path -LiteralPath $settingsPath){
  $settings=Get-Content -LiteralPath $settingsPath -Raw|ConvertFrom-Json
  $settings.componentVersion=$spec.componentVersion;$settings.sourceRef=$spec.sourceRef;$settings.deployerSha256=$deployer.sha256
  foreach($entry in $settings.files){if($entry.path -ceq 'StellaeDeployer.exe'){$entry.bytes=$deployer.bytes;$entry.sha256=$deployer.sha256}}
  Save-Json $settingsPath $settings
 }
 $phase='complete'
 $report=[ordered]@{passed=$true;sourceRef=$spec.sourceRef;componentVersion=$spec.componentVersion;frontendImages=6;registeredDlls=$registered;existingSetupReused=$true;inputSettingsPolicyPassed=$true;runtimeEngineHashUnchanged=$true;basePackageUnchanged=$true;independent32BitBackendUpdated=$false;profilesOrLearningUpdated=$false;runningApplicationImagesVerified=$false}
 Save-Json $reportPath $report
 $report|ConvertTo-Json -Depth 10
}catch{
 if(Test-Path -LiteralPath $reportDirectory){Save-Json $reportPath ([ordered]@{passed=$false;phase=$phase;error=$_.Exception.Message;upstreamHelperStillRunning=$script:helperStillRunning;upstreamHelperProcessId=$script:activeHelperPid})}
 throw
}
