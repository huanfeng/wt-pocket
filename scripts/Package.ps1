#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidatePattern('^v?\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string] $Version = '0.2.0',
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
# Each run gets fresh staging so stale runtime files cannot enter another RID's archive.
$stagingRoot = Join-Path $root ('artifacts/package-' + [guid]::NewGuid().ToString('N'))
foreach ($rid in $Runtime) {
    $stage = Join-Path $stagingRoot $rid
    [IO.Directory]::CreateDirectory($stage) | Out-Null
    & (Join-Path $PSScriptRoot 'Build.ps1') -Runtime $rid -Version $Version `
        -OutputDirectory (Join-Path $stage 'artifacts/host')
    foreach ($relative in @('README.md', 'LICENSE', 'install.ps1',
            'powershell/Startup.ps1', 'powershell/WtTools.psm1',
            'scripts/Install-WtTools.ps1', 'scripts/Uninstall-WtTools.ps1',
            'scripts/Start-WtToolsHost.ps1')) {
        $target = Join-Path $stage $relative
        [IO.Directory]::CreateDirectory((Split-Path $target -Parent)) | Out-Null
        Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $target
    }
    & (Join-Path $PSScriptRoot 'Write-Notices.ps1') -OutputPath (Join-Path $stage 'THIRD-PARTY-NOTICES.txt')
    @{ product = 'WTPocket'; version = $Version; runtime = $rid; backend = 'rust'; selfContained = $true } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'release.json') -Encoding utf8NoBOM
    Get-ChildItem -LiteralPath (Join-Path $stage 'artifacts/host') -Filter '*.pdb' -File |
        Remove-Item -Force
    $archive = Join-Path $OutputDirectory "wtpocket-v$Version-$rid.zip"
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $archive -CompressionLevel Optimal -Force
    Write-Output "Packaged $archive"
}
$checksums = Get-ChildItem -LiteralPath $OutputDirectory -Filter "wtpocket-v$Version-win-*.zip" -File |
    Sort-Object Name | ForEach-Object { '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.Name }
[IO.File]::WriteAllLines((Join-Path $OutputDirectory 'SHA256SUMS'), [string[]]$checksums, [Text.UTF8Encoding]::new($false))
