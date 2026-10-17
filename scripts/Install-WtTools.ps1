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
$lockKey = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
    [Text.Encoding]::UTF8.GetBytes($Destination.TrimEnd('\').ToUpperInvariant())))
$installMutex = [Threading.Mutex]::new($false, ('Local\wtpocket-install-' + $lockKey))
$lockAcquired = $false
try {
    try { $lockAcquired = $installMutex.WaitOne(30000) }
    catch [Threading.AbandonedMutexException] { $lockAcquired = $true }
    if (-not $lockAcquired) { throw 'Another WTPocket installation is still running. Please retry shortly.' }
$hostOutput = Join-Path $root 'artifacts/host'
if ((-not (Test-Path -LiteralPath (Join-Path $hostOutput 'wttools-host.exe')) -or
        -not (Test-Path -LiteralPath (Join-Path $hostOutput 'WtTools.ShellNative.dll'))) -and
        [IO.File]::Exists((Join-Path $PSScriptRoot 'Build.ps1'))) {
    & (Join-Path $PSScriptRoot 'Build.ps1')
}
if (-not [IO.File]::Exists((Join-Path $hostOutput 'WtTools.ShellNative.dll'))) {
    throw 'wttools native API assembly is missing. Run scripts/Build.ps1, then reinstall wttools.'
}
# Inventory and hash the entire payload before touching the installation.
# Every distinct payload gets its own directory: loaded DLLs are never replaced.
$files = @('LICENSE', 'README.md', 'powershell/WtTools.psm1', 'powershell/Startup.ps1', 'scripts/Start-WtToolsHost.ps1', 'scripts/Uninstall-WtTools.ps1')
$payload = @{}
foreach ($relative in $files) { $payload[$relative] = Join-Path $root $relative }
foreach ($file in (Get-Item -LiteralPath (Join-Path $hostOutput 'wttools-host.exe'), (Join-Path $hostOutput 'WtTools.ShellNative.dll'))) {
    $payload['host/' + $file.Name] = $file.FullName
}
if ([IO.File]::Exists((Join-Path $root 'THIRD-PARTY-NOTICES.txt'))) {
    $payload['THIRD-PARTY-NOTICES.txt'] = Join-Path $root 'THIRD-PARTY-NOTICES.txt'
}
if (-not $payload.ContainsKey('host/wttools-host.exe')) { throw 'wttools host executable is missing. Run scripts/Build.ps1 first.' }
$hashes = @{}
$manifest = foreach ($relative in ($payload.Keys | Sort-Object)) {
    $hashes[$relative] = (Get-FileHash -LiteralPath $payload[$relative] -Algorithm SHA256).Hash
    "$relative $($hashes[$relative])"
}
$identity = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
    [Text.Encoding]::UTF8.GetBytes(($manifest -join "`n")))).ToLowerInvariant()
$versions = Join-Path $Destination 'versions'
$installedRoot = Join-Path $versions $identity
$complete = [IO.Directory]::Exists($installedRoot)
if ($complete) {
    foreach ($relative in $payload.Keys) {
        $candidate = Join-Path $installedRoot $relative
        if (-not [IO.File]::Exists($candidate) -or
            (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -ne $hashes[$relative]) {
            $complete = $false
            # Repair a damaged installation without overwriting files that may
            # already be loaded by another process.
            $installedRoot = Join-Path $versions ($identity + '-' + [guid]::NewGuid().ToString('N'))
            break
        }
    }
}
if (-not $complete) {
    $staging = Join-Path $versions ('.staging-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($staging) | Out-Null
    try {
        foreach ($relative in $payload.Keys) {
            $target = Join-Path $staging $relative
            [IO.Directory]::CreateDirectory((Split-Path $target -Parent)) | Out-Null
            Copy-Item -LiteralPath $payload[$relative] -Destination $target
            if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne $hashes[$relative]) {
                throw "Installation verification failed: $relative"
            }
        }
        [IO.Directory]::Move($staging, $installedRoot)
    } finally {
        # Only our newly allocated staging directory can be removed.
        if ([IO.Directory]::Exists($staging)) {
            $stagingPath = [IO.Path]::GetFullPath($staging)
            $versionsPrefix = [IO.Path]::GetFullPath($versions).TrimEnd('\') + '\'
            if (-not $stagingPath.StartsWith($versionsPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Refusing cleanup outside the versions directory.'
            }
            Remove-Item -LiteralPath $stagingPath -Recurse -Force
        }
    }
}

function Write-AtomicText([string] $Path, [string] $Content) {
    [IO.Directory]::CreateDirectory((Split-Path $Path -Parent)) | Out-Null
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, $Content, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Path, $true)
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

# Keep the documented uninstall entry point stable across payload versions.
Write-AtomicText (Join-Path $Destination 'scripts/Uninstall-WtTools.ps1') ([IO.File]::ReadAllText((Join-Path $installedRoot 'scripts/Uninstall-WtTools.ps1')))
$moduleLiteral = (Join-Path $installedRoot 'powershell/WtTools.psm1').Replace("'", "''")
$startupLiteral = (Join-Path $installedRoot 'powershell/Startup.ps1').Replace("'", "''")
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
}
$currentPath = Join-Path $Destination 'current.json'
$previousCurrent = if ([IO.File]::Exists($currentPath)) { [IO.File]::ReadAllText($currentPath) } else { $null }
Write-AtomicText $currentPath (@{ path = $installedRoot } | ConvertTo-Json)
try {
    # The profile is the activation point. It only references verified files.
    if ($updated -cne $text) { Write-AtomicText $ProfilePath $updated }
} catch {
    if ($null -ne $previousCurrent) { Write-AtomicText $currentPath $previousCurrent }
    else { [IO.File]::Delete($currentPath) }
    throw
}
Write-Output "Installed wttools to $installedRoot"
Write-Output 'Existing shells and panels keep using their current version; no loaded DLLs are overwritten.'
Write-Output "Open a new PowerShell 7 tab in Windows Terminal, then press Alt+F at the prompt."
} finally {
    if ($lockAcquired) { $installMutex.ReleaseMutex() }
    $installMutex.Dispose()
}
