# SPDX-License-Identifier: GPL-3.0-only
param(
    [Parameter(Mandatory)][ValidateSet('weasel-61047','weasel-server-61042','weasel-61020','engine-r5','engine-n01')][string]$Variant,
    [Parameter(Mandatory)][string]$SourcePath,
    [switch]$CheckOnly,
    [switch]$AllowSourceArchive
)
. (Join-Path $PSScriptRoot 'Common.ps1')
$manifest = Get-NativeManifest
$source = (Resolve-Path -LiteralPath $SourcePath).Path
if ($AllowSourceArchive -and -not $CheckOnly) { throw 'Archives are permitted for read-only patch checks only.' }
foreach ($component in $manifest.variants[$Variant].components) {
    $tree = [IO.Path]::GetFullPath((Join-Path $source $component.path))
    $spec = $manifest.sources[$component.source]
    if (-not $AllowSourceArchive) {
        Assert-NativeSourceHead $tree $spec.commit
        Invoke-NativeGit @('-C', $tree, 'diff', '--quiet', 'HEAD', '--')
    }
    $patches = @($manifest.patches | Where-Object { $_.id -ceq $component.patch })
    if ($patches.Count -ne 1 -or $patches[0].source -cne $component.source) { throw 'Invalid component patch mapping.' }
    $patch = Get-NativeRepositoryPath $patches[0].path
    $null = Assert-NativeHash $patch $patches[0].sha256
    Invoke-NativeGit @('-C', $tree, 'apply', '--check', $patch)
    if (-not $CheckOnly) { Invoke-NativeGit @('-C', $tree, 'apply', $patch) }
}
[ordered]@{variant=$Variant; patchCheckPassed=$true; applied=(-not $CheckOnly); upstreamGitIdentityChecked=(-not $AllowSourceArchive)} | ConvertTo-Json -Compress
