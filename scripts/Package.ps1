#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidatePattern('^v?\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string] $Version = '0.5.0',
    [ValidateSet('win-x64', 'win-arm64')]
    [string[]] $Runtime = @('win-x64', 'win-arm64'),
    [string] $OutputDirectory
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$Version = $Version.TrimStart('v')
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root "artifacts/release/v$Version" }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
# Each run gets fresh staging so stale files cannot enter another RID's archive.
$stagingRoot = Join-Path $root ('artifacts/package-' + [guid]::NewGuid().ToString('N'))
foreach ($rid in $Runtime) {
    # The archive is flat: `wtpocket.exe install` runs straight from the extracted folder.
    $stage = Join-Path $stagingRoot $rid
    & (Join-Path $PSScriptRoot 'Build.ps1') -Runtime $rid -Version $Version -OutputDirectory $stage
    Copy-Item -LiteralPath (Join-Path $root 'README.md') -Destination (Join-Path $stage 'README.md')
    & (Join-Path $PSScriptRoot 'Write-Notices.ps1') -OutputPath (Join-Path $stage 'THIRD-PARTY-NOTICES.txt')
    @{ product = 'WTPocket'; version = $Version; runtime = $rid; backend = 'rust'; selfContained = $true } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'release.json') -Encoding utf8NoBOM
    $archive = Join-Path $OutputDirectory "wtpocket-v$Version-$rid.zip"
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $archive -CompressionLevel Optimal -Force
    Write-Output "Packaged $archive"
}
$checksums = Get-ChildItem -LiteralPath $OutputDirectory -Filter "wtpocket-v$Version-win-*.zip" -File |
    Sort-Object Name | ForEach-Object { '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.Name }
[IO.File]::WriteAllLines((Join-Path $OutputDirectory 'SHA256SUMS'), [string[]]$checksums, [Text.UTF8Encoding]::new($false))
