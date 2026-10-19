#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('win-x64', 'win-arm64')]
    [string] $Runtime = ('win-' + [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()),
    [string] $OutputDirectory,
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string] $Version = '0.4.0'
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
    if ($LASTEXITCODE -ne 0) { throw 'Rust build failed. Install Rust MSVC and the matching Visual Studio C++ build tools.' }
} finally { $env:WTPOCKET_VERSION = $previousVersion }
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
if (-not $PSBoundParameters.ContainsKey('OutputDirectory')) {
    # Drop leftovers from older layouts (e.g. the .NET host) from our own default
    # directory only; a caller-chosen directory is never cleaned.
    $payload = @('wtpocket.exe', 'Startup.ps1', 'LICENSE')
    Get-ChildItem -LiteralPath $OutputDirectory -File | Where-Object { $_.Name -notin $payload } | Remove-Item -Force
}
# Allowlist: the installable payload is exactly the executable and its PowerShell shim.
Copy-Item -LiteralPath (Join-Path $root "target/$target/release/wtpocket.exe") -Destination (Join-Path $OutputDirectory 'wtpocket.exe') -Force
Copy-Item -LiteralPath (Join-Path $root 'powershell/Startup.ps1') -Destination (Join-Path $OutputDirectory 'Startup.ps1') -Force
Copy-Item -LiteralPath (Join-Path $root 'LICENSE') -Destination (Join-Path $OutputDirectory 'LICENSE') -Force
Write-Output ('wtpocket built in {0:N2} seconds.' -f $timer.Elapsed.TotalSeconds)
