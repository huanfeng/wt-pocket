#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidatePattern('^v?\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string] $Version = '0.1.0',
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
    & (Join-Path $PSScriptRoot 'Build.ps1') -Runtime $rid -SelfContained -Version $Version `
        -OutputDirectory (Join-Path $stage 'artifacts/host')
    # Runtime publishing omits the runtime pack's license and notices. Ship the
    # exact bundled runtime's notices beside its DLLs, including after install.
    $hostDirectory = Join-Path $stage 'artifacts/host'
    $runtimeConfig = Get-Content -LiteralPath (Join-Path $hostDirectory 'wttools-host.runtimeconfig.json') -Raw | ConvertFrom-Json
    $runtimeVersion = ($runtimeConfig.runtimeOptions.includedFrameworks |
        Where-Object name -eq 'Microsoft.NETCore.App').version
    $assets = Get-Content -LiteralPath (Join-Path $root 'src/WtTools.Host/obj/project.assets.json') -Raw |
        ConvertFrom-Json -AsHashtable
    $runtimePack = $null
    foreach ($cacheRoot in $assets.packageFolders.Keys) {
        $candidate = Join-Path $cacheRoot "microsoft.netcore.app.runtime.$rid/$runtimeVersion"
        if ([IO.File]::Exists((Join-Path $candidate 'LICENSE.TXT'))) { $runtimePack = $candidate; break }
    }
    if (-not $runtimePack) { throw "Cannot locate .NET runtime license for $rid $runtimeVersion." }
    Copy-Item -LiteralPath (Join-Path $runtimePack 'LICENSE.TXT') -Destination (Join-Path $hostDirectory 'dotnet-LICENSE.txt')
    Copy-Item -LiteralPath (Join-Path $runtimePack 'THIRD-PARTY-NOTICES.TXT') -Destination (Join-Path $hostDirectory 'dotnet-THIRD-PARTY-NOTICES.txt')
    foreach ($relative in @('README.md', 'LICENSE', 'install.ps1',
            'powershell/Startup.ps1', 'powershell/WtTools.psm1', 'src/PanelHost.cs',
            'scripts/Install-WtTools.ps1', 'scripts/Uninstall-WtTools.ps1',
            'scripts/Start-WtToolsHost.ps1')) {
        $target = Join-Path $stage $relative
        [IO.Directory]::CreateDirectory((Split-Path $target -Parent)) | Out-Null
        Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $target
    }
    @{ product = 'WTPocket'; version = $Version; runtime = $rid; selfContained = $true } |
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
