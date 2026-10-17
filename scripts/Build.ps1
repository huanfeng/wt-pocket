#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('win-x64', 'win-arm64')]
    [string] $Runtime,
    [switch] $SelfContained,
    [string] $OutputDirectory,
    [ValidatePattern('^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$')]
    [string] $Version = '0.1.0'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $root 'artifacts/host' }
if ($SelfContained -and -not $Runtime) { throw '-SelfContained requires -Runtime.' }
$timer = [Diagnostics.Stopwatch]::StartNew()
$publishArguments = @('publish', (Join-Path $root 'src/WtTools.Host/WtTools.Host.csproj'), '-c', 'Release',
    '--self-contained', $SelfContained.IsPresent.ToString().ToLowerInvariant(),
    '--output', $OutputDirectory, '--nologo', "-p:Version=$Version")
if ($Runtime) { $publishArguments += @('--runtime', $Runtime) }
& dotnet @publishArguments
if ($LASTEXITCODE -ne 0) { throw 'wttools host build failed.' }
& dotnet build (Join-Path $root 'src/WtTools.ShellNative/WtTools.ShellNative.csproj') -c Release `
    --output $OutputDirectory --nologo
if ($LASTEXITCODE -ne 0) { throw 'wttools shell helper build failed.' }
Write-Output "wttools host and shell helper built in $($timer.Elapsed.TotalSeconds.ToString('F2')) seconds."
