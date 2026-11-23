# SPDX-License-Identifier: GPL-3.0-only
param(
    [Parameter(Mandatory)][ValidateSet('weasel-61047','weasel-server-61042','weasel-61020','engine-r5','engine-n01')][string]$Variant,
    [Parameter(Mandatory)][string]$Destination
)
. (Join-Path $PSScriptRoot 'Common.ps1')
$manifest = Get-NativeManifest
$destinationPath = [IO.Path]::GetFullPath($Destination)
if (Test-Path -LiteralPath $destinationPath) { throw 'Use a new destination; existing checkouts are never reset.' }
function New-PinnedCheckout([string]$Id, [string]$Path) {
    $spec = $manifest.sources[$Id]
    if ($spec.url -notmatch '^https://github.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$' -or
        $spec.commit -notmatch '^[0-9a-f]{40}$') { throw 'Expected a fixed public GitHub source.' }
    if (Test-Path -LiteralPath $Path) {
        if (@(Get-ChildItem -LiteralPath $Path -Force).Count -ne 0) { throw 'Refuse to replace nonempty source directories.' }
    } else { New-Item -ItemType Directory -Path $Path | Out-Null }
    Invoke-NativeGit @('init', $Path)
    Invoke-NativeGit @('-C', $Path, 'config', 'core.autocrlf', 'false')
    Invoke-NativeGit @('-C', $Path, 'remote', 'add', 'origin', $spec.url)
    Invoke-NativeGit @('-C', $Path, 'fetch', '--depth=1', 'origin', $spec.commit)
    Invoke-NativeGit @('-C', $Path, 'checkout', '--detach', 'FETCH_HEAD')
    Assert-NativeSourceHead $Path $spec.commit
    if ($spec.submodules) {
        Invoke-NativeGit @('-C', $Path, '-c', 'core.autocrlf=false', 'submodule', 'update', '--init', '--recursive')
    }
}
$variantSpec = $manifest.variants[$Variant]
New-PinnedCheckout $variantSpec.rootSource $destinationPath
$assembledSources = @([ordered]@{path='.'; source=$variantSpec.rootSource; commit=$manifest.sources[$variantSpec.rootSource].commit})
if ($variantSpec.rootSource -ceq 'librime') {
    foreach ($plugin in $manifest.enginePlugins) {
        New-PinnedCheckout $plugin.source (Join-Path $destinationPath $plugin.path)
        $assembledSources += [ordered]@{path=$plugin.path; source=$plugin.source; commit=$manifest.sources[$plugin.source].commit}
    }
}
& (Join-Path $PSScriptRoot 'Apply-Patches.ps1') -Variant $Variant -SourcePath $destinationPath
$submodules = @()
if ($manifest.sources[$variantSpec.rootSource].submodules) {
    $submodules = @(& git -C $destinationPath submodule status --recursive)
    if ($LASTEXITCODE -ne 0 -or @($submodules | Where-Object { $_ -match '^[-+U]' }).Count -ne 0) {
        throw 'Submodule checkouts do not match the fixed parent source.'
    }
}
$report = [ordered]@{
    schema='rymcp-native-assembly/1'; variant=$Variant; sourceAssemblyPassed=$true
    compilationPerformed=$false; sources=$assembledSources; submodules=$submodules
    patches=@($variantSpec.components | ForEach-Object {
        $component = $_
        $manifest.patches | Where-Object { $_.id -ceq $component.patch } | ForEach-Object {
            [ordered]@{path=$_.path; sha256=$_.sha256}
        }
    })
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $destinationPath 'native-source-assembly.json') -Encoding utf8
$report | ConvertTo-Json -Depth 8
