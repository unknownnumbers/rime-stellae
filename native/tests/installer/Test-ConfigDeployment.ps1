# SPDX-License-Identifier: GPL-3.0-only
#requires -Version 7
param(
  [Parameter(Mandatory)][string]$Engine,
  [Parameter(Mandatory)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$enginePath = (Resolve-Path -LiteralPath $Engine).Path
$root = (New-Item -ItemType Directory -Path $OutputDirectory).FullName
$shared = (New-Item -ItemType Directory -Path (Join-Path $root 'shared')).FullName
$user = (New-Item -ItemType Directory -Path (Join-Path $root 'user')).FullName
$build = (New-Item -ItemType Directory -Path (Join-Path $user 'build')).FullName
$helper = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../../../schemes/tests/RimeProbe.cs'))
$api = @"
public static class DeploymentProbe {
  [DllImport(@"$enginePath", CallingConvention=CallingConvention.Cdecl)]
  public static extern int RimeDeployConfigFile(string file, string versionKey);
}
"@
Add-Type -TypeDefinition ($helper.Replace('__RIME_ENGINE_DLL__', $enginePath) + "`n" + $api)
$traits = [RimeProbe+Traits]::new()
$traits.data_size = [Runtime.InteropServices.Marshal]::SizeOf($traits) - 4
$paths = @{shared_data_dir=$shared; user_data_dir=$user; prebuilt_data_dir=$build;
           staging_dir=$build; log_dir=$root; app_name='rime.config_deployment_test'}
foreach ($key in $paths.Keys) {
  $traits.$key = [Runtime.InteropServices.Marshal]::StringToCoTaskMemUTF8($paths[$key])
}
$stamp = [datetime]::UtcNow.AddHours(-1)
function Write-Source($Directory, $Name, $Content) {
  $file = Join-Path $Directory $Name
  [IO.File]::WriteAllText($file, $Content, [Text.UTF8Encoding]::new($false))
  $script:stamp = $script:stamp.AddSeconds(2)
  [IO.File]::SetLastWriteTimeUtc($file, $script:stamp)
}
function Deploy-Appearance {
  [DeploymentProbe]::RimeDeployConfigFile('stellae.yaml', 'config_version')
}
function Check($Condition, $Name) {
  if (-not $Condition) { throw "Config deployment failed expectation: $Name" }
}
$source = "config_version: '1'`ntheme: gray`n"
$file = Join-Path $build 'stellae.yaml'
try {
  [RimeProbe]::RimeSetup([ref]$traits)
  [RimeProbe]::RimeDeployerInitialize([ref]$traits)
  Write-Source $shared 'stellae.yaml' $source
  Check ((Deploy-Appearance) -eq 1) 'valid source with optional custom absent'
  $original = [IO.File]::ReadAllText($file)
  Check ($original.Contains('theme: gray')) 'effective initial appearance'
  Check ((Deploy-Appearance) -eq 1) 'unchanged sources'

  Write-Source $shared 'stellae.yaml' "theme: [`n"
  Check ((Deploy-Appearance) -eq 0) 'invalid source reported'
  Check ([IO.File]::ReadAllText($file) -ceq $original) 'old appearance preserved'
  Write-Source $shared 'stellae.yaml' "__include: missing:/values`n"
  Check ((Deploy-Appearance) -eq 0) 'unresolved required include reported'
  Check ([IO.File]::ReadAllText($file) -ceq $original) 'unlinked configuration preserved'

  Write-Source $shared 'stellae.yaml' $source
  Write-Source $user 'stellae.custom.yaml' "patch:`n  theme: green`n"
  Check ((Deploy-Appearance) -eq 1) 'valid customization deployed'
  $customized = [IO.File]::ReadAllText($file)
  Check ($customized.Contains('theme: green')) 'initial customization applied'
  Write-Source $user 'stellae.custom.yaml' "patch: [`n"
  Check ((Deploy-Appearance) -eq 0) 'invalid optional customization reported'
  Check ([IO.File]::ReadAllText($file) -ceq $customized) 'customization failure preserved old output'
  Write-Source $user 'stellae.custom.yaml' "patch:`n  theme: blue`n"
  $locked = [IO.File]::Open($file, 'Open', 'Read', 'Read')
  try { Check ((Deploy-Appearance) -eq 0) 'unwritable output reported' }
  finally { $locked.Dispose() }
  Check ([IO.File]::ReadAllText($file) -ceq $customized) 'locked output preserved'
  Check ((Deploy-Appearance) -eq 1) 'corrected customization deployed'
  Check ([IO.File]::ReadAllText($file).Contains('theme: blue')) 'corrected customization applied'

  Write-Source $shared 'default.yaml' "config_version: '1'`nschema_list: []`n"
  Check ([RimeProbe]::RimeDeployWorkspace() -eq 1) 'valid empty workspace'
  $default = Join-Path $build 'default.yaml'
  $prior = [IO.File]::ReadAllText($default)
  Write-Source $shared 'default.yaml' "schema_list: [`n"
  Check ([RimeProbe]::RimeDeployWorkspace() -eq 0) 'invalid workspace default reported'
  Check ([IO.File]::ReadAllText($default) -ceq $prior) 'previous workspace default preserved'
  Write-Output 'Config deployment tests passed.'
} finally {
  [RimeProbe]::RimeFinalize()
  foreach ($key in $paths.Keys) {
    [Runtime.InteropServices.Marshal]::FreeCoTaskMem($traits.$key)
  }
}
