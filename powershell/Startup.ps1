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
    Write-Warning 'wtpocket.exe is missing. Run the install command again to repair the installation.'
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
$wtpocketContext.LocationHandler = [System.EventHandler[Management.Automation.LocationChangedEventArgs]] ({
    param($sender, $eventArgs)
    $state = $wtpocketContext
    if ($state.PreviousLocationHandler) { $state.PreviousLocationHandler.Invoke($sender, $eventArgs) }
    if ($eventArgs.NewPath.Provider.Name -ne 'FileSystem') { return }
    $temporary = $null
    try {
        [IO.Directory]::CreateDirectory($state.StateRoot) | Out-Null
        $temporary = $state.DirectoryFile + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        [IO.File]::WriteAllText($temporary, $eventArgs.NewPath.ProviderPath)
        [IO.File]::Move($temporary, $state.DirectoryFile, $true)
    } catch {
        Write-Verbose "wtpocket could not save the directory: $_"
    } finally {
        if ($temporary -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}.GetNewClosure())
$ExecutionContext.InvokeCommand.LocationChangedAction = $wtpocketContext.LocationHandler

# Record an explicit starting directory even if the user never calls cd.
$wtpocketNow = Get-Location
if ($wtpocketNow.Provider.Name -eq 'FileSystem') {
    # Calling the installed handler would also call the user's handler for a
    # synthetic event. Write this initial value without notifying them.
    $wtpocketInitial = $null
    try {
        [IO.Directory]::CreateDirectory($wtpocketContext.StateRoot) | Out-Null
        $wtpocketInitial = $wtpocketContext.DirectoryFile + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        [IO.File]::WriteAllText($wtpocketInitial, $wtpocketNow.ProviderPath)
        [IO.File]::Move($wtpocketInitial, $wtpocketContext.DirectoryFile, $true)
    } catch { Write-Verbose "wtpocket could not save the directory: $_" }
    finally { if ($wtpocketInitial -and [IO.File]::Exists($wtpocketInitial)) { [IO.File]::Delete($wtpocketInitial) } }
}

if (-not (Get-Module PSReadLine)) { Import-Module PSReadLine -ErrorAction Stop }
Set-PSReadLineKeyHandler -Chord 'Alt+f' -BriefDescription WtPocketPanel -LongDescription 'Show or hide the WTPocket terminal panel' -ScriptBlock {
    try {
        $state = $global:WtPocketState
        if ((Get-Location).Provider.Name -ne 'FileSystem') {
            Write-Warning 'WTPocket requires a filesystem directory (registry and other providers are unsupported).'
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
