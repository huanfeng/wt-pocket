#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PipeName,
    [Parameter(Mandatory)][string] $StateRoot
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'wttools requires Windows.' }
$root = Split-Path $PSScriptRoot -Parent
$executable = @((Join-Path $root 'host/wttools-host.exe'), (Join-Path $root 'artifacts/host/wttools-host.exe')) |
    Where-Object { [IO.File]::Exists($_) } | Select-Object -First 1
if (-not $executable) { throw 'Rust host is missing. Run scripts/Build.ps1 or reinstall WTPocket.' }
& $executable $PipeName $StateRoot (Join-Path $root 'powershell/WtTools.psm1') (Join-Path $PSHOME 'pwsh.exe')
