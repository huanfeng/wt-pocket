#Requires -Version 7.4
[CmdletBinding()]
param(
    [string] $ProfilePath = $PROFILE.CurrentUserCurrentHost,
    [string] $Destination = (Join-Path (Split-Path $PROFILE.CurrentUserAllHosts -Parent) 'wttools/app'),
    [string] $StateRoot = (Join-Path (Split-Path $PROFILE.CurrentUserAllHosts -Parent) 'wttools')
)
$ErrorActionPreference = 'Stop'
$module = Join-Path $Destination 'powershell/WtTools.psm1'
if (Test-Path -LiteralPath $module) {
    Import-Module $module
    Stop-WtTools -StateRoot $StateRoot
    Remove-Module WtTools
}
if (Test-Path -LiteralPath $ProfilePath) {
    $text = [IO.File]::ReadAllText($ProfilePath)
    $updated = [regex]::Replace($text, '(?ms)^# >>> wttools >>>\r?\n.*?^# <<< wttools <<<[^\S\r\n]*(?:\r?\n)?', '')
    if ($text -cne $updated) {
        Copy-Item -LiteralPath $ProfilePath -Destination ($ProfilePath + '.wttools-uninstall-' + (Get-Date -Format 'yyyyMMddHHmmssfff') + '.bak')
        [IO.File]::WriteAllText($ProfilePath, $updated, [Text.UTF8Encoding]::new($false))
    }
}
Write-Output 'wttools disabled for new shells. Running panels are revealed, not terminated. Installed files and directory history are retained.'
