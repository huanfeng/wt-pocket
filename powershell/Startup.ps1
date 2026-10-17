#Requires -Version 7.4
param(
    [string] $StateRoot = (Join-Path (Split-Path $PROFILE.CurrentUserAllHosts -Parent) 'wttools')
)

# This file runs in the caller's profile scope. Keep all persistent state in one
# object so profile variables and other LocationChangedAction users stay intact.
if (-not $IsWindows -or -not $env:WT_SESSION) { return }
if ($ExecutionContext.SessionState.PSVariable.GetValue('global:WtToolsStartupState')) { return }
if (Get-Module WtTools) { return }
$wttoolsStartupModule = [IO.Path]::Combine($PSScriptRoot, 'WtTools.psm1')
if (-not [IO.File]::Exists($wttoolsStartupModule)) {
    Write-Warning 'wttools module is missing. Run Install-WtTools.ps1 again to repair the installation.'
    return
}
$wttoolsStartupContext = @{
    Active = $true
    StateRoot = [IO.Path]::GetFullPath($StateRoot)
    ModulePath = $wttoolsStartupModule
    Panel = $env:WTTOOLS_PANEL -eq '1'
    PreviousLocationHandler = $ExecutionContext.InvokeCommand.LocationChangedAction
    LocationHandler = $null
    PreviousKeyHandler = $null
    DirectoryFile = $null
}
if (-not $wttoolsStartupContext.Panel) {
    $wttoolsProfileKey = if ($env:WT_PROFILE_ID) { $env:WT_PROFILE_ID } else { 'default' }
    $wttoolsProfileHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($wttoolsProfileKey)))
    $wttoolsStartupContext.DirectoryFile = [IO.Path]::Combine($wttoolsStartupContext.StateRoot, 'last-directory-' + $wttoolsProfileHash.Substring(0, 16) + '.txt')
    $wttoolsCurrent = Get-Location
    if ($wttoolsCurrent.Provider.Name -eq 'FileSystem' -and $wttoolsCurrent.ProviderPath.TrimEnd('\') -in @($HOME.TrimEnd('\'), $env:USERPROFILE.TrimEnd('\'))) {
        if ([IO.File]::Exists($wttoolsStartupContext.DirectoryFile)) {
            $wttoolsSaved = [IO.File]::ReadAllText($wttoolsStartupContext.DirectoryFile)
            if ([IO.Directory]::Exists($wttoolsSaved)) { Set-Location -LiteralPath $wttoolsSaved }
        }
    }
    $wttoolsStartupContext.LocationHandler = [System.EventHandler[Management.Automation.LocationChangedEventArgs]] ({
        param($sender, $eventArgs)
        $state = $wttoolsStartupContext
        if ($state.PreviousLocationHandler) { $state.PreviousLocationHandler.Invoke($sender, $eventArgs) }
        if (-not $state.Active -or $eventArgs.NewPath.Provider.Name -ne 'FileSystem') { return }
        $temporary = $null
        try {
            [IO.Directory]::CreateDirectory($state.StateRoot) | Out-Null
            $temporary = $state.DirectoryFile + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
            [IO.File]::WriteAllText($temporary, $eventArgs.NewPath.ProviderPath)
            [IO.File]::Move($temporary, $state.DirectoryFile, $true)
        } catch {
            Write-Verbose "wttools could not save the directory: $_"
        } finally {
            if ($temporary -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
        }
    }.GetNewClosure())
}

function global:Open-WtPanel {
    [CmdletBinding()]
    param([string] $Directory)
    $startup = $global:WtToolsStartupState
    Import-Module $startup.ModulePath -Global -ErrorAction Stop
    $module = Get-Module WtTools
    $startup.Active = $false
    if ($startup.LocationHandler -and $ExecutionContext.InvokeCommand.LocationChangedAction -eq $startup.LocationHandler) {
        $ExecutionContext.InvokeCommand.LocationChangedAction = $startup.PreviousLocationHandler
    }
    # Preserve the binding that existed before the shim, not the shim itself.
    & $module {
        param($previous)
        $script:PreviousKeyHandler = $previous
        $script:KeyBound = $true
    } $startup.PreviousKeyHandler
    Enable-WtTools -RememberDirectory -RestoreDirectory -Panel:$startup.Panel -StateRoot $startup.StateRoot
    Remove-Variable -Name WtToolsStartupState -Scope Global
    if ($PSBoundParameters.ContainsKey('Directory')) { WtTools\Open-WtPanel -Directory $Directory }
    else { WtTools\Open-WtPanel }
}

if (-not (Get-Module PSReadLine)) { Import-Module PSReadLine -ErrorAction Stop }
$wttoolsStartupContext.PreviousKeyHandler = Get-PSReadLineKeyHandler -Chord 'Alt+f'
$global:WtToolsStartupState = $wttoolsStartupContext
if ($wttoolsStartupContext.LocationHandler) {
    $ExecutionContext.InvokeCommand.LocationChangedAction = $wttoolsStartupContext.LocationHandler
    # Record an explicit starting directory even if the user never calls cd.
    $wttoolsNow = Get-Location
    if ($wttoolsNow.Provider.Name -eq 'FileSystem') {
        # Calling the installed handler would also call the user's handler for a
        # synthetic event. Write this initial value without notifying them.
        $wttoolsInitial = $null
        try {
            [IO.Directory]::CreateDirectory($wttoolsStartupContext.StateRoot) | Out-Null
            $wttoolsInitial = $wttoolsStartupContext.DirectoryFile + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
            [IO.File]::WriteAllText($wttoolsInitial, $wttoolsNow.ProviderPath)
            [IO.File]::Move($wttoolsInitial, $wttoolsStartupContext.DirectoryFile, $true)
        } catch { Write-Verbose "wttools could not save the directory: $_" }
        finally { if ($wttoolsInitial -and [IO.File]::Exists($wttoolsInitial)) { [IO.File]::Delete($wttoolsInitial) } }
    }
}
Set-PSReadLineKeyHandler -Chord 'Alt+f' -BriefDescription WtToolsPanel -LongDescription 'Show or hide the wttools terminal panel' -ScriptBlock {
    try { Open-WtPanel } catch { Write-Warning $_ }
}
