#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PipeName,
    [Parameter(Mandatory)][string] $StateRoot
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'wttools requires Windows.' }
$root = Split-Path $PSScriptRoot -Parent
Add-Type -Path (Join-Path $root 'src/PanelHost.cs')
[WtTools.PanelHost]::Run($PipeName, $StateRoot,
    (Join-Path $root 'powershell/WtTools.psm1'), (Join-Path $PSHOME 'pwsh.exe'))
