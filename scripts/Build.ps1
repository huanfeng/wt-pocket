#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('win-x64', 'win-arm64')]
    [string] $Runtime = ('win-' + [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()),
    [string] $OutputDirectory,
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string] $Version = '0.2.0'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'artifacts/host' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
$target = switch ($Runtime) { 'win-x64' { 'x86_64-pc-windows-msvc' } 'win-arm64' { 'aarch64-pc-windows-msvc' } }
$timer = [Diagnostics.Stopwatch]::StartNew()
$previousVersion = $env:WTPOCKET_VERSION
try {
    $env:WTPOCKET_VERSION = $Version
    & cargo build --manifest-path (Join-Path $root 'Cargo.toml') --locked --release --target $target
    if ($LASTEXITCODE -ne 0) { throw 'Rust host build failed. Install Rust MSVC and the matching Visual Studio C++ build tools.' }
} finally { $env:WTPOCKET_VERSION = $previousVersion }
# This tiny managed P/Invoke bridge uses PowerShell's runtime. No .NET runtime is bundled.
$helperOutput = Join-Path $root 'artifacts/shell-helper'
& dotnet build (Join-Path $root 'src/WtTools.ShellNative/WtTools.ShellNative.csproj') -c Release `
    --output $helperOutput --nologo
if ($LASTEXITCODE -ne 0) { throw 'PowerShell native API helper build failed.' }
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
# Allowlist prevents old .NET host/runtime files from leaking into new packages.
Copy-Item -LiteralPath (Join-Path $root "target/$target/release/wttools-host.exe") -Destination (Join-Path $OutputDirectory 'wttools-host.exe') -Force
Copy-Item -LiteralPath (Join-Path $helperOutput 'WtTools.ShellNative.dll') -Destination (Join-Path $OutputDirectory 'WtTools.ShellNative.dll') -Force
Write-Output "Rust host and PowerShell helper built in $($timer.Elapsed.TotalSeconds.ToString('F2')) seconds."
