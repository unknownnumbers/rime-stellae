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
    if ($Variant -ceq 'stellae-61052') { Assert-StellaeSourceFiles $SourcePath }
}

function Assert-StellaeSourceFiles([string]$SourcePath) {
    $manifest = Get-NativeManifest
    $inventory = Get-Content -LiteralPath (Get-NativeRepositoryPath $manifest.frontendSourceFiles) -Raw | ConvertFrom-Json -AsHashtable
    $patch = @($manifest.patches | Where-Object { $_.id -ceq 'stellae61052' })[0]
    if ($inventory.schema -cne 'stellae-frontend-source-files/1' -or
        $inventory.patchSha256 -cne $patch.sha256 -or -not $inventory.byteExactReplay) {
        throw 'The frontend byte inventory does not describe the complete source patch.'
    }
    foreach ($entry in $inventory.files) {
        $path = Join-Path $SourcePath $entry.path
        if ($entry.ContainsKey('deleted') -and $entry.deleted) {
            if (Test-Path -LiteralPath $path) { throw 'A deleted source file remains in the frontend assembly.' }
        } else {
            $null = Assert-NativeHash $path $entry.sha256
        }
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
    foreach ($relative in @('installer','assets','scripts/package')) {
        $path = Get-NativeRepositoryPath $relative
        if (-not (Test-Path -LiteralPath $path)) { throw "Required public build source is missing: $relative" }
        $destination = Join-Path $source $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $path -Destination $destination -Recurse
    }
}

function Export-NativeAssemblySource([string]$SourcePath, [string]$Variant, [string]$ArchivePath) {
    Assert-NativeAssembly $SourcePath $Variant
    if (Test-Path -LiteralPath $ArchivePath) { throw 'The assembled-source archive must be new.' }
    $manifest = Get-NativeManifest
    $assembly = Get-Content -LiteralPath (Join-Path $SourcePath 'native-source-assembly.json') -Raw | ConvertFrom-Json -AsHashtable
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $assembly.sources) {
        $tree = Join-Path $SourcePath $entry.path
        $raw = (& git -C $tree -c core.quotepath=false ls-files --recurse-submodules -z | Out-String)
        if ($LASTEXITCODE -ne 0) { throw 'Could not enumerate the fixed source repositories.' }
        foreach ($path in $raw.TrimEnd([char[]]@([char]13,[char]10,[char]0)).Split([char]0)) {
            if (-not $path) { continue }
            $relative = if ($entry.path -ceq '.') { $path } else { "$($entry.path)/$path" }
            $null = $paths.Add($relative.Replace('\','/'))
        }
    }
    # git apply leaves added source files untracked. Include every patch path.
    foreach ($component in $manifest.variants[$Variant].components) {
        $patch = @($manifest.patches | Where-Object { $_.id -ceq $component.patch })[0]
        $stats = @(& git apply --numstat (Get-NativeRepositoryPath $patch.path))
        if ($LASTEXITCODE -ne 0) { throw 'Could not enumerate complete patch source paths.' }
        foreach ($line in $stats) {
            $path = ($line -split "`t",3)[2]
            $relative = if ($component.path -ceq '.') { $path } else { "$($component.path)/$path" }
            $null = $paths.Add($relative.Replace('\','/'))
        }
    }
    $null = $paths.Add('native-source-assembly.json')
    $root = [IO.Path]::GetFullPath($SourcePath).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    $files = @(); $excluded = @()
    New-Item -ItemType Directory -Path (Split-Path -Parent $ArchivePath) -Force | Out-Null
    $zip = [IO.Compression.ZipFile]::Open($ArchivePath,[IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($relative in @($paths | Sort-Object)) {
            if ($relative.Split('/') -contains '.git') { throw 'Git metadata must not enter a source archive.' }
            $path = [IO.Path]::GetFullPath((Join-Path $root $relative))
            if (-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'A source path escapes its assembly.' }
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            # Preserve source files, icons and test data. Prebuilt tools/libraries
            # remain fixed external build inputs with their own source notices.
            if ([IO.Path]::GetExtension($path).ToLowerInvariant() -in @('.pdb','.exe','.dll','.ime','.obj','.lib','.exp','.o','.a','.so')) {
                $excluded += $relative
                continue
            }
            $item = Get-Item -LiteralPath $path
            $file = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip,$path,$relative,[IO.Compression.CompressionLevel]::Optimal)
            $files += [ordered]@{path=$relative;bytes=$item.Length;sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()}
        }
        $record = [ordered]@{
            schema='stellae-assembled-source/1'; variant=$Variant
            publicBuildCommit=$env:GITHUB_SHA; publicBuildRunId=$env:GITHUB_RUN_ID
            capturedBeforeCompilation=$true; sources=$assembly.sources
            files=$files; excludedPrebuiltFiles=$excluded; gitMetadataIncluded=$false
        }
        $entry = $zip.CreateEntry('source-archive-manifest.json',[IO.Compression.CompressionLevel]::Optimal)
        $writer = [IO.StreamWriter]::new($entry.Open(),[Text.UTF8Encoding]::new($false))
        try { $writer.Write(($record | ConvertTo-Json -Depth 10) + "`n") } finally { $writer.Dispose() }
    } finally { $zip.Dispose() }
    if ($files.Count -eq 0) { throw 'The assembled-source archive is empty.' }
    [ordered]@{files=$files.Count;excludedPrebuiltFiles=$excluded.Count;sha256=(Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()}
}
