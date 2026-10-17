#Requires -Version 7.4
[CmdletBinding()]
param(
    [string] $Destination = (Join-Path (Split-Path $PROFILE.CurrentUserAllHosts -Parent) 'wttools/app'),
    [string] $ProfilePath = $PROFILE.CurrentUserCurrentHost,
    [string] $StateRoot = (Join-Path (Split-Path $PROFILE.CurrentUserAllHosts -Parent) 'wttools')
)
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'wttools requires Windows.' }
$root = Split-Path $PSScriptRoot -Parent
$Destination = [IO.Path]::GetFullPath($Destination)
$ProfilePath = [IO.Path]::GetFullPath($ProfilePath)
$StateRoot = [IO.Path]::GetFullPath($StateRoot)
$installedModule = Join-Path $Destination 'powershell/WtTools.psm1'
if (Test-Path -LiteralPath $installedModule) {
    Import-Module $installedModule
    Stop-WtTools -StateRoot $StateRoot
    Remove-Module WtTools
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ((Test-Path -LiteralPath (Join-Path $StateRoot 'host.json')) -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 50
    }
    Start-Sleep -Milliseconds 100
}
$hostOutput = Join-Path $root 'artifacts/host'
if ((-not (Test-Path -LiteralPath (Join-Path $hostOutput 'wttools-host.exe')) -or
        -not (Test-Path -LiteralPath (Join-Path $hostOutput 'WtTools.ShellNative.dll'))) -and
        (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    & (Join-Path $PSScriptRoot 'Build.ps1')
}
if (-not [IO.File]::Exists((Join-Path $hostOutput 'WtTools.ShellNative.dll'))) {
    throw 'wttools native API assembly is missing. Run scripts/Build.ps1 with the .NET 10 SDK, then reinstall wttools.'
}
$files = @('LICENSE', 'README.md', 'powershell/WtTools.psm1', 'powershell/Startup.ps1', 'src/PanelHost.cs', 'scripts/Start-WtToolsHost.ps1', 'scripts/Uninstall-WtTools.ps1')
foreach ($relative in $files) {
    $target = Join-Path $Destination $relative
    [IO.Directory]::CreateDirectory((Split-Path $target -Parent)) | Out-Null
    if ([IO.Path]::GetFullPath((Join-Path $root $relative)) -ne [IO.Path]::GetFullPath($target)) {
        Copy-Item -LiteralPath (Join-Path $root $relative) -Destination $target -Force
    }
}
if (Test-Path -LiteralPath (Join-Path $hostOutput 'wttools-host.exe')) {
    $target = Join-Path $Destination 'host'
    [IO.Directory]::CreateDirectory($target) | Out-Null
    Get-ChildItem -LiteralPath $hostOutput -File | Where-Object Extension -ne '.pdb' | ForEach-Object {
        $targetFile = Join-Path $target $_.Name
        # Open shells keep the native helper loaded. Identical files need no
        # replacement and can safely stay in use during a host-only update.
        if (-not ([IO.File]::Exists($targetFile) -and
                (Get-FileHash -LiteralPath $_.FullName).Hash -eq (Get-FileHash -LiteralPath $targetFile).Hash)) {
            try {
                Copy-Item -LiteralPath $_.FullName -Destination $targetFile -Force
            } catch {
                throw "Could not update '$targetFile'. If it is in use, close existing PowerShell sessions and Panels, then run the installer from a fresh PowerShell session. $($_.Exception.Message)"
            }
        }
    }
}

$moduleLiteral = (Join-Path $Destination 'powershell/WtTools.psm1').Replace("'", "''")
$startupLiteral = (Join-Path $Destination 'powershell/Startup.ps1').Replace("'", "''")
$block = @'
# >>> wttools >>>
if ($env:WT_SESSION) {
    if ([IO.File]::Exists('__MODULE__') -and [IO.File]::Exists('__STARTUP__')) {
        try {
            . '__STARTUP__' -StateRoot '__STATE__'
        } catch {
            Write-Warning "wttools failed to initialize: $_"
        }
    } else {
        Write-Warning 'wttools module is missing. Run Install-WtTools.ps1 again to repair the installation.'
    }
}
# <<< wttools <<<
'@.Replace('__MODULE__', $moduleLiteral).Replace('__STARTUP__', $startupLiteral).Replace('__STATE__', $StateRoot.Replace("'", "''"))
$text = if (Test-Path -LiteralPath $ProfilePath) { [IO.File]::ReadAllText($ProfilePath) } else { '' }
$pattern = '(?ms)^# >>> wttools >>>\r?\n.*?^# <<< wttools <<<[^\S\r\n]*(?:\r?\n)?'
if ([regex]::IsMatch($text, $pattern)) {
    $replacement = $block + [Environment]::NewLine
    $updated = [regex]::Replace($text, $pattern, [Text.RegularExpressions.MatchEvaluator] { param($match) $replacement })
} else {
    $separator = if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { [Environment]::NewLine } else { '' }
    $updated = $text + $separator + $block + [Environment]::NewLine
}
if ($updated -cne $text) {
    if (Test-Path -LiteralPath $ProfilePath) {
        $backup = $ProfilePath + '.wttools-' + (Get-Date -Format 'yyyyMMddHHmmssfff') + '.bak'
        Copy-Item -LiteralPath $ProfilePath -Destination $backup
        Write-Output "Profile backup: $backup"
    }
    [IO.Directory]::CreateDirectory((Split-Path $ProfilePath -Parent)) | Out-Null
    [IO.File]::WriteAllText($ProfilePath, $updated, [Text.UTF8Encoding]::new($false))
}
Write-Output "Installed wttools to $Destination"
Write-Output "Open a new PowerShell 7 tab in Windows Terminal, then press Alt+F at the prompt."
