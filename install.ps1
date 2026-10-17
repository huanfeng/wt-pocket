#Requires -Version 7.4
<#
.SYNOPSIS
Installs WTPocket from a verified GitHub release, without administrator access.
.EXAMPLE
& ([scriptblock]::Create((Invoke-RestMethod https://raw.githubusercontent.com/huanfeng/wt-pocket/main/install.ps1)))
.EXAMPLE
./install.ps1 -Version v0.1.0
.EXAMPLE
./install.ps1 -ArchivePath ./wtpocket-v0.1.0-win-x64.zip -ChecksumPath ./SHA256SUMS
#>
[CmdletBinding()]
param(
    [ValidatePattern('^v?\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string] $Version,
    [string] $ArchivePath,
    [string] $ChecksumPath,
    [string] $Destination,
    [string] $ProfilePath,
    [string] $StateRoot
)

$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'WTPocket requires Windows and PowerShell 7.4 or later.' }
if (-not (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
    throw 'Windows Terminal was not found. Install Windows Terminal and enable its wt.exe app execution alias, then retry.'
}
if ($ChecksumPath -and -not $ArchivePath) { throw '-ChecksumPath requires -ArchivePath.' }
if ($ArchivePath -and $Version) { throw 'Use either -ArchivePath for an offline package or -Version for a GitHub release.' }

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('wtpocket-install-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($temporaryRoot) | Out-Null
try {
    if ($ArchivePath) {
        $ArchivePath = (Resolve-Path -LiteralPath $ArchivePath -ErrorAction Stop).ProviderPath
        if (-not [IO.File]::Exists($ArchivePath)) { throw '-ArchivePath must name a ZIP file.' }
        if (-not $ChecksumPath) { $ChecksumPath = Join-Path (Split-Path $ArchivePath -Parent) 'SHA256SUMS' }
        $ChecksumPath = (Resolve-Path -LiteralPath $ChecksumPath -ErrorAction Stop).ProviderPath
        $archiveName = [IO.Path]::GetFileName($ArchivePath)
    } else {
        $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
        if ($architecture -notin @('x64', 'arm64')) {
            throw "Unsupported Windows architecture '$architecture'. WTPocket releases support x64 and ARM64."
        }
        $headers = @{ 'User-Agent' = 'WTPocket-Installer'; Accept = 'application/vnd.github+json' }
        if ($Version) {
            if (-not $Version.StartsWith('v')) { $Version = 'v' + $Version }
        } else {
            try {
                $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/huanfeng/wt-pocket/releases/latest' -Headers $headers
            } catch {
                throw "Could not resolve the latest WTPocket release. Check your network or use -Version vX.Y.Z. $($_.Exception.Message)"
            }
            $Version = [string] $release.tag_name
            if ($Version -notmatch '^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
                throw "Unexpected WTPocket release tag '$Version'."
            }
        }
        $archiveName = "wtpocket-$Version-win-$architecture.zip"
        $releaseUrl = "https://github.com/huanfeng/wt-pocket/releases/download/$Version"
        $ArchivePath = Join-Path $temporaryRoot $archiveName
        $ChecksumPath = Join-Path $temporaryRoot 'SHA256SUMS'
        Write-Host "Downloading WTPocket $Version for Windows $architecture..."
        Invoke-WebRequest -Uri "$releaseUrl/$archiveName" -OutFile $ArchivePath -Headers $headers
        Invoke-WebRequest -Uri "$releaseUrl/SHA256SUMS" -OutFile $ChecksumPath -Headers $headers
    }

    $expectedHashes = @(
        foreach ($line in [IO.File]::ReadAllLines($ChecksumPath)) {
            if ($line -match '^([A-Fa-f0-9]{64})\s+\*?(.+)$' -and $Matches[2] -ceq $archiveName) {
                $Matches[1]
            }
        }
    )
    if ($expectedHashes.Count -ne 1) {
        throw "SHA256SUMS must contain exactly one checksum for '$archiveName'."
    }
    $actualHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash
    if ($actualHash -ine $expectedHashes[0]) {
        throw "SHA256 checksum verification failed for '$archiveName'. No installation files were changed."
    }

    $extractionRoot = Join-Path $temporaryRoot 'package'
    $extractionPrefix = [IO.Path]::GetFullPath($extractionRoot) + [IO.Path]::DirectorySeparatorChar
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $entryPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $archive.Entries) {
            $entryName = $entry.FullName.Replace('/', [IO.Path]::DirectorySeparatorChar)
            $entryTarget = [IO.Path]::GetFullPath((Join-Path $extractionRoot $entryName))
            if ([IO.Path]::IsPathRooted($entryName) -or $entryName.Contains(':') -or
                -not $entryTarget.StartsWith($extractionPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Unsafe ZIP entry '$($entry.FullName)': extraction outside the package directory is forbidden."
            }
            # A package consists only of regular files and directories; no links.
            if ((($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
                throw "Unsafe ZIP entry '$($entry.FullName)': symbolic links are forbidden."
            }
            if (-not $entryPaths.Add($entryTarget)) {
                throw "Duplicate ZIP entry '$($entry.FullName)'."
            }
        }
    } finally {
        $archive.Dispose()
    }
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $extractionRoot
    foreach ($requiredFile in @(
        'LICENSE', 'README.md',
        'scripts/Install-WtTools.ps1', 'scripts/Start-WtToolsHost.ps1', 'scripts/Uninstall-WtTools.ps1',
        'powershell/Startup.ps1', 'powershell/WtTools.psm1', 'src/PanelHost.cs',
        'artifacts/host/wttools-host.exe', 'artifacts/host/WtTools.ShellNative.dll'
    )) {
        if (-not [IO.File]::Exists((Join-Path $extractionRoot $requiredFile))) {
            throw "The WTPocket package is incomplete: missing '$requiredFile'."
        }
    }
    $installParameters = @{}
    foreach ($parameterName in @('Destination', 'ProfilePath', 'StateRoot')) {
        if ($PSBoundParameters.ContainsKey($parameterName)) {
            if ([string]::IsNullOrWhiteSpace($PSBoundParameters[$parameterName])) {
                throw "-$parameterName must not be empty."
            }
            $installParameters[$parameterName] = $PSBoundParameters[$parameterName]
        }
    }
    & (Join-Path $extractionRoot 'scripts/Install-WtTools.ps1') @installParameters
} finally {
    # Only remove the fresh directory allocated by this invocation, never the
    # caller's offline archive or any installed application files.
    $temporaryBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $resolvedTemporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
    if ($resolvedTemporaryRoot.StartsWith($temporaryBase, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolvedTemporaryRoot) -match '^wtpocket-install-[a-f0-9]{32}$' -and
        [IO.Directory]::Exists($resolvedTemporaryRoot)) {
        Remove-Item -LiteralPath $resolvedTemporaryRoot -Recurse -Force
    }
}
