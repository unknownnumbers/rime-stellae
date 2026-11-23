# SPDX-License-Identifier: GPL-3.0-only
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceDirectory,
    [Parameter(Mandatory)][string]$UserDirectory,
    [ValidateSet('TC','SC')][string]$InitialPreset,
    [switch]$ValidateOnly
)
$ErrorActionPreference='Stop'
$utf8=[Text.UTF8Encoding]::new($false)
$collectionName='NotoSansCJK-Regular.ttc'
$collectionHash='b76b0433203017ca80401b2ee0dd69350349871c4b19d504c34dbdd80541690a'
$collectionValue='Noto Sans CJK Regular Collection (OpenType)'
$families=@(
    'Noto Sans CJK JP','Noto Sans CJK KR','Noto Sans CJK SC','Noto Sans CJK TC','Noto Sans CJK HK',
    'Noto Sans Mono CJK JP','Noto Sans Mono CJK KR','Noto Sans Mono CJK SC','Noto Sans Mono CJK TC','Noto Sans Mono CJK HK'
)
$fontSubKey='Software\Microsoft\Windows NT\CurrentVersion\Fonts'
$legacy=@(
    @{Name='Noto Sans CJK SC (OpenType)'; File='NotoSansCJKsc-Regular.otf'; Hash='2c76254f6fc379fddfce0a7e84fb5385bb135d3e399294f6eeb6680d0365b74b'}
    @{Name='Noto Sans CJK TC (OpenType)'; File='NotoSansCJKtc-Regular.otf'; Hash='dce08bd4fd91aa8aa76ed8fea4b694c2dfb8550f67871e326843212ddbeb88b4'}
    @{Name='Noto Sans CJK HK (OpenType)'; File='NotoSansCJKhk-Regular.otf'; Hash='97c937514d645eae90415d30ba025e08a94d5bdffdc627404864f90aa0c7d83b'}
)

function Write-FontTrace([string]$Detail) {
    $trace=$env:STELLAE_BUNDLE_TEST_TRACE
    if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted' -or
        -not $trace -or -not [IO.File]::Exists($trace)) {return}
    try {[IO.File]::AppendAllText($trace,$Detail+[Environment]::NewLine,$utf8)}catch{}
}

function Get-FontDigest([string]$Path) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        $stream=[IO.File]::OpenRead($Path)
        try { ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
        finally {$stream.Dispose()}
    } finally {$sha.Dispose()}
}

function Get-OwnedFontPath([string]$Directory,[string]$Name,[string]$Digest) {
    Join-Path $Directory ('RymCp-'+$Digest.Substring(0,12)+'-'+$Name)
}

function Write-InitialFontPreset {
    if (-not $InitialPreset) {return}
    $file=Join-Path $UserDirectory 'rymcp_candidate_font.yaml'
    if ([IO.File]::Exists($file)) {return}
    $stack="Noto Sans CJK $InitialPreset, Microsoft YaHei, SimSun-ExtB:20000:2EBE0, SimSun-ExtG:2EBF0:2EE5D, SimSun-ExtG:30000:323AF, Jigmo2:20000:2EE5D, Jigmo2:2F800:2FA1D, Jigmo3:30000:33479"
    $null=[IO.Directory]::CreateDirectory($UserDirectory)
    $temporary=Join-Path $UserDirectory ('.rymcp-font-default-'+[guid]::NewGuid().ToString('N'))
    $yaml=@(
        '# Initial candidate font preset.'
        'patch:'
        ('  style/font_face: "'+$stack+'"')
        ('  style/label_font_face: "'+$stack+'"')
        ('  style/comment_font_face: "'+$stack+'"')
        ''
    ) -join [Environment]::NewLine
    try {
        [IO.File]::WriteAllText($temporary,$yaml,$utf8)
        [IO.File]::Move($temporary,$file)
    } finally {
        if ([IO.File]::Exists($temporary)) {[IO.File]::Delete($temporary)}
    }
}

function Assert-FontFamilies {
    $missing=[StellaeCandidateFontNative]::GetMissingFamilies($families)
    if ($missing.Count) {throw ('Windows did not expose these fonts to DirectWrite: '+($missing -join ', '))}
}

function Test-RegisteredCollection($Registry,[string]$Directory) {
    if (-not $Registry) {return $false}
    foreach ($name in $Registry.GetValueNames()) {
        $path=[Environment]::ExpandEnvironmentVariables([string]$Registry.GetValue($name,''))
        if ($path -notmatch '(?:^|[\\/])NotoSansCJK-Regular\.ttc$' -or $path.StartsWith('\\')) {continue}
        if (-not [IO.Path]::IsPathRooted($path)) {$path=Join-Path $Directory $path}
        if ([IO.File]::Exists($path)) {
            try {if ((Get-FontDigest $path) -ceq $collectionHash) {return $true}}
            catch [IO.IOException] {continue}
            catch [UnauthorizedAccessException] {continue}
        }
    }
    $false
}

function Install-FontCollection([string]$Source) {
    $fontDirectory=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Microsoft\Windows\Fonts'
    $destination=Get-OwnedFontPath $fontDirectory $collectionName $collectionHash
    $registry=[Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($fontSubKey)
    if (-not $registry) {throw 'The current user font registry is unavailable.'}
    $fileCreated=$false
    $fontLoaded=$false
    $registrationAdded=$false
    $current=''
    $removed=[Collections.Generic.List[object]]::new()
    try {
        $current=[string]$registry.GetValue($collectionValue,'')
        if ($current -and $current -ine $destination) {
            throw 'A different installation already uses the collection registration.'
        }
        $null=[IO.Directory]::CreateDirectory($fontDirectory)
        if ([IO.File]::GetAttributes($fontDirectory) -band [IO.FileAttributes]::ReparsePoint) {
            throw 'The current user font directory is a reparse point.'
        }
        $external=$false
        if (-not $current -and -not [StellaeCandidateFontNative]::GetMissingFamilies($families).Count) {
            $machine=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($fontSubKey)
            try {
                $external=(Test-RegisteredCollection $registry $fontDirectory) -or
                    (Test-RegisteredCollection $machine (Join-Path $env:WINDIR 'Fonts'))
            } finally {if ($machine) {$machine.Dispose()}}
        }
        if (-not $external) {
            if ([IO.File]::Exists($destination)) {
                if (([IO.File]::GetAttributes($destination) -band [IO.FileAttributes]::ReparsePoint) -or
                    (Get-FontDigest $destination) -cne $collectionHash) {
                    throw 'The installed font collection does not match the bundled file.'
                }
            } else {
                [IO.File]::Copy($Source,$destination,$false)
                $fileCreated=$true
            }
            if (-not $current -or [StellaeCandidateFontNative]::GetMissingFamilies($families).Count) {
                if (-not [StellaeCandidateFontNative]::LoadFont($destination)) {
                    throw 'Windows could not load the Noto Sans CJK Regular collection.'
                }
                $fontLoaded=$true
            }
            if (-not $current) {
                $registry.SetValue($collectionValue,$destination,[Microsoft.Win32.RegistryValueKind]::String)
                $registrationAdded=$true
            }
        }
        if ($fontLoaded) {[StellaeCandidateFontNative]::NotifyFontChange()}
        Assert-FontFamilies

        # Migrate only exact prior Stellae registrations and upstream font files.
        foreach ($old in $legacy) {
            $path=Get-OwnedFontPath $fontDirectory $old.File $old.Hash
            if ($registry.GetValue($old.Name,$null) -ine $path -or -not [IO.File]::Exists($path) -or
                ([IO.File]::GetAttributes($path) -band [IO.FileAttributes]::ReparsePoint) -or
                (Get-FontDigest $path) -cne $old.Hash) {continue}
            $otherRegistrations=@($registry.GetValueNames() | Where-Object {
                $_ -ine $old.Name -and $registry.GetValue($_,$null) -ieq $path
            }).Count -gt 0
            $entry=[pscustomobject]@{
                Name=$old.Name; Path=$path; Hash=$old.Hash; Unloaded=$false; OwnedOnly=(-not $otherRegistrations)
            }
            $registry.DeleteValue($old.Name)
            $removed.Add($entry)
            if ($entry.OwnedOnly) {$entry.Unloaded=[StellaeCandidateFontNative]::UnloadFont($path)}
        }
        if ($removed.Count) {
            [StellaeCandidateFontNative]::NotifyFontChange()
            Assert-FontFamilies
        }
        Write-InitialFontPreset
    } catch {
        foreach ($old in $removed) {
            if ($old.Unloaded) {$null=[StellaeCandidateFontNative]::LoadFont($old.Path)}
            $registry.SetValue($old.Name,$old.Path,[Microsoft.Win32.RegistryValueKind]::String)
        }
        if ($registrationAdded -and $registry.GetValue($collectionValue,$null) -ieq $destination) {
            $registry.DeleteValue($collectionValue,$false)
        }
        if ($fontLoaded) {$null=[StellaeCandidateFontNative]::UnloadFont($destination)}
        if ($fileCreated -and -not $current) {
            try {[IO.File]::Delete($destination)}
            catch [IO.IOException] {Write-FontTrace 'candidate-font-rollback-file-in-use'}
            catch [UnauthorizedAccessException] {Write-FontTrace 'candidate-font-rollback-file-in-use'}
        }
        if ($fontLoaded -or $removed.Count) {[StellaeCandidateFontNative]::NotifyFontChange()}
        throw
    } finally {$registry.Dispose()}

    foreach ($old in $removed) {
        if (-not $old.OwnedOnly) {continue}
        try {
            if ([IO.File]::Exists($old.Path) -and
                -not ([IO.File]::GetAttributes($old.Path) -band [IO.FileAttributes]::ReparsePoint) -and
                (Get-FontDigest $old.Path) -ceq $old.Hash) {[IO.File]::Delete($old.Path)}
        } catch [IO.IOException] {
            Write-FontTrace "candidate-font-old-file-in-use name=$($old.Name)"
        } catch [UnauthorizedAccessException] {
            Write-FontTrace "candidate-font-old-file-in-use name=$($old.Name)"
        }
    }
    Write-FontTrace "candidate-font-ready migrated=$($removed.Count)"
}

try {
    $manifest=Get-Content -LiteralPath (Join-Path $SourceDirectory 'font-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $records=@($manifest.files)
    $asset=$records[0]
    if ($manifest.id -cne 'stellae-font-regular-collection' -or $manifest.schemaVersion -ne 2 -or
        $records.Count -ne 1 -or $asset.file -cne $collectionName -or $asset.sha256 -cne $collectionHash -or
        $asset.size -ne 19484784 -or $asset.role -cne 'primary' -or $asset.version -cne '2.004' -or
        $asset.license -cne 'OFL-1.1' -or @($asset.families).Count -ne $families.Count -or
        (Compare-Object $families @($asset.families) -CaseSensitive)) {
        throw 'The font collection manifest does not match the bundled Noto Sans CJK release.'
    }
    $source=Join-Path $SourceDirectory $collectionName
    if ((Get-Item -LiteralPath $source).Length -ne $asset.size -or (Get-FontDigest $source) -cne $collectionHash) {
        throw 'The bundled font collection failed verification.'
    }
    if (-not $ValidateOnly) {
        Add-Type -LiteralPath (Join-Path $PSScriptRoot 'CandidateFontNative.cs')
        Install-FontCollection $source
    }
} catch {
    $message=$_.Exception.Message -replace '[\r\n]+',' '
    Write-FontTrace "candidate-font-helper-error line=$($_.InvocationInfo.ScriptLineNumber) id=$($_.FullyQualifiedErrorId) $message"
    throw
}
