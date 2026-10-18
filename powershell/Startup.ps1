#Requires -Version 7.4
param(
    [string] $StateRoot = (Join-Path (Split-Path $PROFILE.CurrentUserAllHosts -Parent) 'wttools')
)

# This file runs in the caller's profile scope. Keep all persistent state in one
# object so profile variables and other LocationChangedAction users stay intact.
# Everything heavy lives in wtpocket.exe; this shim only remembers directories,
# binds Alt+F and defines the `wtpocket` command.
if (-not $IsWindows -or -not $env:WT_SESSION) { return }
if ($ExecutionContext.SessionState.PSVariable.GetValue('global:WtPocketState')) { return }
$wtpocketExe = [IO.Path]::Combine($PSScriptRoot, 'wtpocket.exe')
if (-not [IO.File]::Exists($wtpocketExe)) {
    Write-Warning $(if (($env:WTPOCKET_LANG, (Get-UICulture).Name -ne $null)[0] -like 'zh*') { 'wtpocket.exe 缺失。请重新运行安装命令修复。' } else { 'wtpocket.exe is missing. Run the install command again to repair the installation.' })
    return
}
$wtpocketContext = @{
    StateRoot = [IO.Path]::GetFullPath($StateRoot)
    Exe = $wtpocketExe
    Pwsh = [IO.Path]::Combine($PSHOME, 'pwsh.exe')
    SessionId = $null
    Panel = $env:WTTOOLS_PANEL -eq '1'
    PreviousLocationHandler = $ExecutionContext.InvokeCommand.LocationChangedAction
    LocationHandler = $null
    DirectoryFile = $null
}
$global:WtPocketState = $wtpocketContext

function global:wtpocket { & $global:WtPocketState.Exe @args }

# A panel is just a shell: it needs neither directory memory nor the hotkey
# (the host handles Alt+F for it).
if ($wtpocketContext.Panel) { return }

$wtpocketProfileKey = if ($env:WT_PROFILE_ID) { $env:WT_PROFILE_ID } else { 'default' }
$wtpocketProfileHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($wtpocketProfileKey)))
$wtpocketContext.DirectoryFile = [IO.Path]::Combine($wtpocketContext.StateRoot, 'last-directory-' + $wtpocketProfileHash.Substring(0, 16) + '.txt')
$wtpocketCurrent = Get-Location
if ($wtpocketCurrent.Provider.Name -eq 'FileSystem' -and $wtpocketCurrent.ProviderPath.TrimEnd('\') -in @($HOME.TrimEnd('\'), $env:USERPROFILE.TrimEnd('\'))) {
    if ([IO.File]::Exists($wtpocketContext.DirectoryFile)) {
        $wtpocketSaved = [IO.File]::ReadAllText($wtpocketContext.DirectoryFile)
        if ([IO.Directory]::Exists($wtpocketSaved)) { Set-Location -LiteralPath $wtpocketSaved }
    }
}
# One small file per terminal session feeds `wtpocket restore`; it records only
# the directory. Skipped when WT_SESSION is not a GUID.
if ($env:WT_SESSION -match '^[0-9A-Fa-f-]{36}$') {
    $wtpocketContext.SessionFile = [IO.Path]::Combine($wtpocketContext.StateRoot, 'sessions', $env:WT_SESSION + '.json')
    $wtpocketContext.SessionIdentity = '"profile":"' + $env:WT_PROFILE_ID + '","pid":' + $PID + ',"started":' + [Diagnostics.Process]::GetCurrentProcess().StartTime.ToFileTimeUtc()
}
# Persist the directory: one file per Windows Terminal profile (where new tabs
# start) and one per terminal session (for restore). Never throws.
$wtpocketContext.Save = {
    param([string] $Directory)
    $state = $wtpocketContext
    $writes = @(, @($state.DirectoryFile, $Directory))
    if ($state.SessionFile) {
        $json = '{"path":"' + $Directory.Replace('\', '\\').Replace('"', '\"') + '",' + $state.SessionIdentity + ',"updated":' + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + '}'
        $writes += , @($state.SessionFile, $json)
    }
    foreach ($write in $writes) {
        $temporary = $null
        try {
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($write[0])) | Out-Null
            $temporary = $write[0] + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
            [IO.File]::WriteAllText($temporary, $write[1])
            [IO.File]::Move($temporary, $write[0], $true)
        } catch {
            Write-Verbose "wtpocket could not save the directory: $_"
        } finally {
            if ($temporary -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        }
    }
}.GetNewClosure()
$wtpocketContext.LocationHandler = [System.EventHandler[Management.Automation.LocationChangedEventArgs]] ({
    param($sender, $eventArgs)
    $state = $wtpocketContext
    if ($state.PreviousLocationHandler) { $state.PreviousLocationHandler.Invoke($sender, $eventArgs) }
    if ($eventArgs.NewPath.Provider.Name -ne 'FileSystem') { return }
    & $state.Save $eventArgs.NewPath.ProviderPath
}.GetNewClosure())
$ExecutionContext.InvokeCommand.LocationChangedAction = $wtpocketContext.LocationHandler

# Record an explicit starting directory even if the user never calls cd.
# The installed handler is not called: that would notify the user's own
# handler about a synthetic event.
$wtpocketNow = Get-Location
if ($wtpocketNow.Provider.Name -eq 'FileSystem') { & $wtpocketContext.Save $wtpocketNow.ProviderPath }
if (-not (Get-Module PSReadLine)) { Import-Module PSReadLine -ErrorAction Stop }
Set-PSReadLineKeyHandler -Chord 'Alt+f' -BriefDescription WtPocketPanel -LongDescription 'Show or hide the WTPocket terminal panel' -ScriptBlock {
    try {
        $state = $global:WtPocketState
        if ((Get-Location).Provider.Name -ne 'FileSystem') {
            Write-Warning $(if (($env:WTPOCKET_LANG, (Get-UICulture).Name -ne $null)[0] -like 'zh*') { 'WTPocket 需要文件系统目录（不支持注册表等其他提供程序）。' } else { 'WTPocket requires a filesystem directory (registry and other providers are unsupported).' })
            return
        }
        if (-not $state.SessionId) {
            $state.SessionId = "$PID-$([Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks)"
        }
        # The native process inherits the current location and reads the focused window itself.
        $output = & $state.Exe open --state $state.StateRoot --pwsh $state.Pwsh --session $state.SessionId 2>&1
        if ($LASTEXITCODE -ne 0) { Write-Warning (($output | Out-String).Trim()) }
    } catch { Write-Warning $_ }
}
