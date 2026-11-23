# SPDX-License-Identifier: GPL-3.0-only
# Shared helpers for fixed public native source and build inputs. Requires PowerShell 7.
Set-StrictMode -Version 3
$ErrorActionPreference = 'Stop'
$script:NativeRepositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$script:NativeManifestPath = Join-Path $script:NativeRepositoryRoot 'native/source-manifest.json'

function Get-NativeManifest {
    Get-Content -LiteralPath $script:NativeManifestPath -Raw | ConvertFrom-Json -AsHashtable
}

function Get-NativeRepositoryPath([string]$Relative) {
    $result = [IO.Path]::GetFullPath((Join-Path $script:NativeRepositoryRoot $Relative))
    $prefix = $script:NativeRepositoryRoot.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $result.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Repository-relative path escapes the checkout: $Relative"
    }
    $result
}

function Assert-NativeHash([string]$Path, [string]$Expected) {
    if ($Expected -notmatch '^[0-9a-f]{64}$') { throw 'A SHA256 pin is required.' }
    $actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -cne $Expected) { throw "SHA256 mismatch: $([IO.Path]::GetFileName($Path))" }
    $actual
}

function Invoke-NativeGit([string[]]$Arguments) {
    & git @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Git failed: $($Arguments -join ' ')" }
}

function Assert-NativeSourceHead([string]$SourcePath, [string]$Commit) {
    if (-not (Test-Path -LiteralPath (Join-Path $SourcePath '.git'))) { throw 'Expected a fixed Git checkout.' }
    $head = (& git -C $SourcePath rev-parse HEAD | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $head -cne $Commit) { throw 'Source commit differs from the manifest.' }
}

function Get-NativeAsset([string]$Id, [string]$CacheDirectory) {
    $manifest = Get-NativeManifest
    $assetEntries = @($manifest.assets | Where-Object { $_.id -ceq $Id })
    if ($assetEntries.Count -ne 1) { throw "Unknown or duplicate asset: $Id" }
    $asset = $assetEntries[0]
    New-Item -ItemType Directory -Path $CacheDirectory -Force | Out-Null
    $name = [IO.Path]::GetFileName(([uri]$asset.url).AbsolutePath)
    $path = Join-Path $CacheDirectory $name
    if (-not (Test-Path -LiteralPath $path)) {
        Invoke-WebRequest -Uri $asset.url -OutFile $path -TimeoutSec 180
    }
    $null = Assert-NativeHash $path $asset.sha256
    if ($asset.ContainsKey('bytes') -and (Get-Item -LiteralPath $path).Length -ne $asset.bytes) {
        throw "Asset byte count differs: $Id"
    }
    $path
}

function Expand-NativeArchive([string]$Archive, [string]$Destination, [string[]]$Members = @()) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $arguments = @('x', $Archive, "-o$Destination", '-y', '-bso0', '-bsp0') + $Members
    & 7z @arguments
    if ($LASTEXITCODE -ne 0) { throw "Archive extraction failed: $([IO.Path]::GetFileName($Archive))" }
}

function Assert-NativePe([string]$Path, [int]$Machine) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 64 -or [BitConverter]::ToUInt16($bytes, 0) -ne 0x5a4d) { throw 'Invalid PE image.' }
    $offset = [BitConverter]::ToInt32($bytes, 0x3c)
    if ($offset -lt 0 -or $offset -gt $bytes.Length - 6 -or
        [BitConverter]::ToUInt32($bytes, $offset) -ne 0x4550 -or
        [BitConverter]::ToUInt16($bytes, $offset + 4) -ne $Machine) {
        throw "Unexpected PE architecture: $([IO.Path]::GetFileName($Path))"
    }
}

function Assert-NativeAssembly([string]$SourcePath, [string]$Variant) {
    $report = Get-Content -LiteralPath (Join-Path $SourcePath 'native-source-assembly.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($report.variant -cne $Variant -or $report.sourceAssemblyPassed -ne $true) { throw 'Expected a successful fixed source assembly.' }
    $manifest = Get-NativeManifest
    foreach ($entry in $report.sources) {
        Assert-NativeSourceHead (Join-Path $SourcePath $entry.path) $manifest.sources[$entry.source].commit
    }
    foreach ($component in $manifest.variants[$Variant].components) {
        $patch = @($manifest.patches | Where-Object { $_.id -ceq $component.patch })[0]
        $path = Get-NativeRepositoryPath $patch.path
        $null = Assert-NativeHash $path $patch.sha256
        Invoke-NativeGit @('-C', (Join-Path $SourcePath $component.path), 'apply', '--reverse', '--check', $path)
    }
}

function Copy-NativeSourceNotices([string]$OutputDirectory) {
    $licenseRoot = Get-NativeRepositoryPath 'licenses'
    if (-not (Test-Path -LiteralPath $licenseRoot)) { throw 'Repository third-party notices must accompany build artifacts.' }
    Copy-Item -LiteralPath $licenseRoot -Destination (Join-Path $OutputDirectory 'licenses') -Recurse
    foreach ($name in @('LICENSE', 'LICENSE.txt', 'LICENSE.md')) {
        $path = Get-NativeRepositoryPath $name
        if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination $OutputDirectory }
    }
    $source = Join-Path $OutputDirectory 'build-source'
    New-Item -ItemType Directory -Path $source | Out-Null
    Copy-Item -LiteralPath (Get-NativeRepositoryPath 'native') -Destination (Join-Path $source 'native') -Recurse
    New-Item -ItemType Directory -Path (Join-Path $source 'scripts') | Out-Null
    Copy-Item -LiteralPath $PSScriptRoot -Destination (Join-Path $source 'scripts/native') -Recurse
}
