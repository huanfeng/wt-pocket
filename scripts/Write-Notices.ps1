#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string] $OutputPath)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$metadataJson = & cargo metadata --locked --format-version 1 --manifest-path (Join-Path $root 'Cargo.toml')
if ($LASTEXITCODE -ne 0) { throw 'Cannot read locked dependency metadata.' }
$metadata = $metadataJson | ConvertFrom-Json
$notice = [Text.StringBuilder]::new("WTPocket third-party notices`n`n")
# Include license texts for the locked dependency graph, including build tools.
foreach ($package in ($metadata.packages | Where-Object name -ne 'wtpocket' | Sort-Object name)) {
    [void] $notice.AppendLine("=== $($package.name) $($package.version) ($($package.license)) ===")
    $directory = Split-Path $package.manifest_path -Parent
    $licenses = @(Get-ChildItem -LiteralPath $directory -File | Where-Object Name -match '^(LICENSE|COPYING|UNLICENSE)')
    if ($licenses.Count -eq 0) { throw "No license text found for $($package.name)." }
    foreach ($licenseFile in $licenses) {
        [void] $notice.AppendLine([IO.File]::ReadAllText($licenseFile.FullName))
    }
}
$sysroot = & rustc --print sysroot
if ($LASTEXITCODE -ne 0) { throw 'Cannot locate Rust standard library notices.' }
$rustDocs = Join-Path $sysroot 'share/doc/rust'
foreach ($licenseFile in (Get-ChildItem -LiteralPath (Join-Path $rustDocs 'licenses') -File)) {
    [void] $notice.AppendLine("=== Rust: $($licenseFile.Name) ===")
    [void] $notice.AppendLine([IO.File]::ReadAllText($licenseFile.FullName))
}
# Standard-library attribution includes its own third-party dependencies.
$attribution = Join-Path $rustDocs 'COPYRIGHT-library.html'
if (-not [IO.File]::Exists($attribution)) { $attribution = Join-Path $rustDocs 'COPYRIGHT.html' }
if (-not [IO.File]::Exists($attribution)) { throw 'Rust standard library attribution is missing; install the rust-docs component.' }
[void] $notice.AppendLine('=== Rust standard library attribution (HTML) ===')
[void] $notice.AppendLine([IO.File]::ReadAllText($attribution))
[IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath), $notice.ToString(), [Text.UTF8Encoding]::new($false))
