# SPDX-License-Identifier: GPL-3.0-only
param(
  [Parameter(Mandatory)][string]$EngineDll,
  [Parameter(Mandatory)][string]$SharedData,
  [Parameter(Mandatory)][string]$ProbeSource,
  [Parameter(Mandatory)][string]$OutputDirectory,
  [ValidateSet('All','Absent','TC','SC','Override')][string]$Case = 'All'
)
$ErrorActionPreference = 'Stop'
$engine = (Resolve-Path -LiteralPath $EngineDll).ProviderPath
$shared = (Resolve-Path -LiteralPath $SharedData).ProviderPath
$probe = (Resolve-Path -LiteralPath $ProbeSource).ProviderPath
$out = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $out) { throw 'Choose a new synthetic font test directory.' }
$null = [IO.Directory]::CreateDirectory($out)

if ($Case -eq 'All') {
  $hostExe = (Get-Process -Id $PID).Path
  foreach ($scenario in 'Absent', 'TC', 'SC', 'Override') {
    & $hostExe -NoProfile -File $PSCommandPath -EngineDll $engine -SharedData $shared `
        -ProbeSource $probe -OutputDirectory (Join-Path $out $scenario) -Case $scenario
    if ($LASTEXITCODE) { throw ('Font preset priority failed: ' + $scenario) }
  }
  $results = foreach ($scenario in 'Absent', 'TC', 'SC', 'Override') {
    Get-Content -LiteralPath (Join-Path $out "$scenario/result.json") -Raw -Encoding UTF8 | ConvertFrom-Json
  }
  $results | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $out 'result.json') -Encoding UTF8
  return
}

$user = Join-Path $out 'user'
$build = Join-Path $user 'build'
$null = [IO.Directory]::CreateDirectory($build)
$utf8 = [Text.UTF8Encoding]::new($false)
$font = 'Microsoft YaHei'
if ($Case -ne 'Absent') {
  $language = if ($Case -eq 'SC') { 'SC' } else { 'TC' }
  $font = 'Noto Sans CJK ' + $language + ', Microsoft YaHei'
  [IO.File]::WriteAllText((Join-Path $user 'rymcp_candidate_font.yaml'), "patch:`n  style/font_face: $font`n", $utf8)
}
$expectedSize = '14'
$custom = Join-Path $user 'weasel.custom.yaml'
$customValue = "# Existing user override.`npatch:`n  style/font_face: Consolas`n  style/font_point: 17`n"
if ($Case -eq 'Override') {
  [IO.File]::WriteAllText($custom, $customValue, $utf8)
  $font = 'Consolas'
  $expectedSize = '17'
}

$env:PATH = (Split-Path -LiteralPath $engine) + ';' + $env:PATH
$source = [IO.File]::ReadAllText($probe)
Add-Type -TypeDefinition $source.Replace('__RIME_ENGINE_DLL__', $engine)
$native = @'
using System;
using System.Runtime.InteropServices;
public static class FontPresetProbe {
    [DllImport(@"__RIME_ENGINE_DLL__", CallingConvention=CallingConvention.Cdecl)]
    static extern IntPtr rime_get_api();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate int Deploy([MarshalAs(UnmanagedType.LPStr)] string file, [MarshalAs(UnmanagedType.LPStr)] string version);
    public static bool DeployConfig() {
        IntPtr api = rime_get_api();
        int offset = IntPtr.Size * 12;
        if (api == IntPtr.Zero || Marshal.ReadInt32(api) + 4 < offset + IntPtr.Size)
            throw new InvalidOperationException("Deploy command unavailable");
        IntPtr function = Marshal.ReadIntPtr(api, offset);
        if (function == IntPtr.Zero) throw new InvalidOperationException("Deploy command unavailable");
        return ((Deploy)Marshal.GetDelegateForFunctionPointer(function, typeof(Deploy)))("weasel.yaml", "config_version") != 0;
    }
}
'@
Add-Type -TypeDefinition $native.Replace('__RIME_ENGINE_DLL__', $engine)
$traits = [RimeProbe+Traits]::new()
$traits.data_size = [Runtime.InteropServices.Marshal]::SizeOf($traits) - 4
$traits.shared_data_dir = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($shared)
$traits.user_data_dir = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($user)
$traits.staging_dir = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($build)
$traits.log_dir = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi($out)
$traits.app_name = [Runtime.InteropServices.Marshal]::StringToHGlobalAnsi('rime.synthetic_candidate_font')
$traits.min_log_level = 2
try {
  [RimeProbe]::RimeSetup([ref]$traits)
  [RimeProbe]::RimeDeployerInitialize([ref]$traits)
  if (-not [FontPresetProbe]::DeployConfig()) { throw 'The native engine did not compile the font test configuration.' }
} finally {
  [RimeProbe]::RimeFinalize()
  foreach ($pointer in @($traits.shared_data_dir,$traits.user_data_dir,$traits.staging_dir,$traits.log_dir,$traits.app_name)) {
    if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::FreeHGlobal($pointer) }
  }
}
$compiled = [IO.File]::ReadAllText((Join-Path $build 'weasel.yaml'))
function Value([string]$name) {
  $match = [regex]::Match($compiled, ('(?m)^  ' + [regex]::Escape($name) + ':[ \t]*([^\r\n]+)\r?$'))
  if (-not $match.Success) { throw ('Compiled style is missing ' + $name) }
  return $match.Groups[1].Value.Trim().Trim('"', [char]39)
}
if ((Value 'font_face') -cne $font -or (Value 'font_point') -cne $expectedSize -or
    (Value 'color_scheme') -cne 'reference_gray') { throw 'Unexpected font precedence or unrelated style changes.' }
if ($Case -eq 'Override' -and [IO.File]::ReadAllText($custom) -cne $customValue) {
  throw 'The font preset rewrote the user override.'
}
$result = [ordered]@{ passed = $true; case = $Case; font = $font; fontPoint = $expectedSize; colorScheme = 'reference_gray' }
$result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $out 'result.json') -Encoding UTF8
$result | ConvertTo-Json -Compress
