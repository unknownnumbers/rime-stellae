param([Parameter(Mandatory=$true)][string]$DllPath,
      [Parameter(Mandatory=$true)][string]$EvidencePath,
      [Parameter(Mandatory=$true)][ValidateSet('truthful-key-pairing','truthful-key-nested','truthful-key-repeat-space')][string]$Probe)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw 'Run only on an ephemeral hosted CI runner.' }
if ($Probe) { $env:RIME_CUSTOM_DELTA_PROBE = $Probe }
else { Remove-Item Env:RIME_CUSTOM_DELTA_PROBE -ErrorAction SilentlyContinue }
$dll = (Resolve-Path -LiteralPath $DllPath).ProviderPath.Replace('"','""')
Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
public static class ResponseOwnerProductNative {
  [DllImport(@"$dll", EntryPoint="RunResponseOwnerProductTests", ExactSpelling=true,
    CallingConvention=CallingConvention.Cdecl, CharSet=CharSet.Unicode)]
  public static extern int Run(string path);
}
"@
exit [ResponseOwnerProductNative]::Run($EvidencePath)
