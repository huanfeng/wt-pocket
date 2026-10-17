#Requires -Version 7.4
$script:StateRoot = Join-Path (Split-Path $PROFILE.CurrentUserAllHosts -Parent) 'wttools'
$script:Enabled = $false
$script:Panel = $false
$script:Remember = $false
$script:LocationHandler = $null
$script:PreviousLocationHandler = $null
$script:PreviousKeyHandler = $null
$script:KeyBound = $false
$script:ModulePath = $PSCommandPath
$script:SessionId = "$PID-$([Diagnostics.Process]::GetCurrentProcess().StartTime.ToUniversalTime().Ticks)"

function Initialize-WtToolsNative {
    if (-not ('WtTools.ShellNative' -as [type])) {
        $root = Split-Path (Split-Path $script:ModulePath -Parent) -Parent
        $assembly = @((Join-Path $root 'host/WtTools.ShellNative.dll'), (Join-Path $root 'artifacts/host/WtTools.ShellNative.dll')) |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        if (-not $assembly) { throw 'wttools native API assembly is missing. Run Build.ps1 and reinstall wttools.' }
        [Reflection.Assembly]::LoadFrom($assembly) | Out-Null
    }
}

function Get-WtToolsPipeName {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $key = $identity + '|' + [IO.Path]::GetFullPath($script:StateRoot).ToUpperInvariant()
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($key)))
    return 'wttools-' + $hash.Substring(0, 24)
}

function Get-WtToolsDirectoryFile {
    $profileKey = if ($env:WT_PROFILE_ID) { $env:WT_PROFILE_ID } else { 'default' }
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($profileKey)))
    Join-Path $script:StateRoot ('last-directory-' + $hash.Substring(0, 16) + '.txt')
}

function Save-WtToolsDirectory {
    param([Management.Automation.PathInfo] $Location)
    if (-not $script:Remember -or $script:Panel -or $Location.Provider.Name -ne 'FileSystem') { return }
    $temporary = $null
    try {
        [IO.Directory]::CreateDirectory($script:StateRoot) | Out-Null
        $destination = Get-WtToolsDirectoryFile
        $temporary = $destination + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
        [IO.File]::WriteAllText($temporary, $Location.ProviderPath)
        [IO.File]::Move($temporary, $destination, $true)
    } catch {
        # Directory bookkeeping must never break Set-Location or a user's prompt.
        Write-Verbose "wttools could not save the directory: $_"
    } finally {
        if ($temporary -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Start-WtToolsHost {
    $root = Split-Path (Split-Path $script:ModulePath -Parent) -Parent
    $pipeName = Get-WtToolsPipeName
    $nativeHost = @((Join-Path $root 'host/wttools-host.exe'), (Join-Path $root 'artifacts/host/wttools-host.exe')) |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if ($nativeHost) {
        $start = [Diagnostics.ProcessStartInfo]::new($nativeHost)
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        foreach ($argument in @($pipeName, $script:StateRoot, $script:ModulePath, (Join-Path $PSHOME 'pwsh.exe'))) {
            $start.ArgumentList.Add($argument)
        }
        $process = [Diagnostics.Process]::Start($start)
        $process.Dispose()
    } else {
        $hostScript = (Join-Path $root 'scripts/Start-WtToolsHost.ps1').Replace("'", "''")
        $literalState = $script:StateRoot.Replace("'", "''")
        $command = "& '$hostScript' -PipeName '$pipeName' -StateRoot '$literalState'"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        Start-Process (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoLogo', '-NoProfile', '-EncodedCommand', $encoded) -WindowStyle Hidden
    }
}

function Send-WtToolsRequest {
    param([hashtable] $Request, [switch] $DoNotStart)
    $pipe = $null
    try {
        $pipeName = Get-WtToolsPipeName
        $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [IO.Pipes.PipeDirection]::InOut)
        try { $pipe.Connect(150) } catch [TimeoutException] {
            $pipe.Dispose()
            if ($DoNotStart) { return }
            Start-WtToolsHost
            $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [IO.Pipes.PipeDirection]::InOut)
            $pipe.Connect(12000)
        }
        $infoPath = Join-Path $script:StateRoot 'host.json'
        if (Test-Path -LiteralPath $infoPath) {
            Initialize-WtToolsNative
            $hostInfo = Get-Content -LiteralPath $infoPath -Raw | ConvertFrom-Json
            [WtTools.ShellNative]::AllowSetForegroundWindow([uint32]$hostInfo.pid) | Out-Null
        }
        $writer = [IO.StreamWriter]::new($pipe, [Text.UTF8Encoding]::new($false), 1024, $true)
        $writer.AutoFlush = $true
        $reader = [IO.StreamReader]::new($pipe, [Text.UTF8Encoding]::new($false), $false, 1024, $true)
        try {
            $writer.WriteLine(($Request | ConvertTo-Json -Compress))
            $read = $reader.ReadLineAsync()
            if (-not $read.Wait(15000)) { throw 'wttools host response timed out. Check host.log in the state directory.' }
            if (-not $read.Result) { throw 'wttools host disconnected.' }
            $response = $read.Result | ConvertFrom-Json
            if (-not $response.ok) { throw $response.error }
        } finally { $reader.Dispose(); $writer.Dispose() }
    } finally { if ($pipe) { $pipe.Dispose() } }
}

function Open-WtPanel {
    [CmdletBinding()]
    param([string] $Directory)
    if (-not $IsWindows -or -not $env:WT_SESSION) { throw 'Open-WtPanel must run inside Windows Terminal on Windows.' }
    Initialize-WtToolsNative
    # Capture the originating window before startup or IPC can change focus.
    $sourceWindow = [WtTools.ShellNative]::GetForegroundWindow().ToInt64()
    $location = if ($PSBoundParameters.ContainsKey('Directory')) { Get-Item -LiteralPath $Directory -ErrorAction Stop } else { Get-Location }
    $provider = if ($location -is [Management.Automation.PathInfo]) { $location.Provider } else { $location.PSProvider }
    if ($provider.Name -ne 'FileSystem') {
        throw 'wttools requires a filesystem directory (registry and other providers are unsupported).'
    }
    $path = if ($location -is [Management.Automation.PathInfo]) { $location.ProviderPath } else { $location.FullName }
    if (-not [IO.Directory]::Exists($path)) { throw 'wttools requires an existing directory.' }
    Send-WtToolsRequest @{ action = 'toggle'; directory = $path; sourceWindow = $sourceWindow; sessionId = $script:SessionId }
}

function Enable-WtTools {
    [CmdletBinding()]
    param(
        [switch] $Panel,
        [switch] $RememberDirectory,
        [switch] $RestoreDirectory,
        [string] $StateRoot
    )
    if (-not $IsWindows) { throw 'wttools requires Windows and PowerShell 7.' }
    if ($StateRoot) { $script:StateRoot = [IO.Path]::GetFullPath($StateRoot) }
    $script:Panel = $Panel -or $env:WTTOOLS_PANEL -eq '1'
    $script:Remember = $RememberDirectory -and -not $script:Panel -and [bool]$env:WT_SESSION
    # Window APIs are only needed when the user opens a panel. Compiling
    # them here would add Roslyn startup to every new shell's profile.
    if (-not $script:Enabled) {
        # Restore before installing our handler so the initial home directory
        # cannot overwrite the previously saved value.
        $current = Get-Location
        if ($RestoreDirectory -and -not $script:Panel -and $env:WT_SESSION -and $current.Provider.Name -eq 'FileSystem' `
            -and $current.ProviderPath.TrimEnd('\') -in @($HOME.TrimEnd('\'), $env:USERPROFILE.TrimEnd('\'))) {
            $file = Get-WtToolsDirectoryFile
            if (Test-Path -LiteralPath $file) {
                $saved = [IO.File]::ReadAllText($file)
                if ([IO.Directory]::Exists($saved)) { Set-Location -LiteralPath $saved }
            }
        }
        $script:PreviousLocationHandler = $ExecutionContext.InvokeCommand.LocationChangedAction
        $script:LocationHandler = [System.EventHandler[Management.Automation.LocationChangedEventArgs]] {
            param($sender, $eventArgs)
            if ($script:PreviousLocationHandler) { $script:PreviousLocationHandler.Invoke($sender, $eventArgs) }
            Save-WtToolsDirectory $eventArgs.NewPath
        }
        $ExecutionContext.InvokeCommand.LocationChangedAction = $script:LocationHandler
        $script:Enabled = $true
    }
    if ($env:WT_SESSION) {
        if (-not (Get-Module PSReadLine)) { Import-Module PSReadLine -ErrorAction Stop }
        if (-not $script:KeyBound) {
            $script:PreviousKeyHandler = Get-PSReadLineKeyHandler -Chord 'Alt+f'
            $script:KeyBound = $true
        }
        Set-PSReadLineKeyHandler -Chord 'Alt+f' -BriefDescription WtToolsPanel -LongDescription 'Show or hide the wttools terminal panel' -ScriptBlock {
            try { Open-WtPanel } catch { Write-Warning $_ }
        }
    }
    Save-WtToolsDirectory (Get-Location)
}

function Stop-WtTools {
    [CmdletBinding()]
    param([string] $StateRoot)
    if ($StateRoot) { $script:StateRoot = [IO.Path]::GetFullPath($StateRoot) }
    Send-WtToolsRequest @{ action = 'shutdown' } -DoNotStart
}

$ExecutionContext.SessionState.Module.OnRemove = {
    if ($script:LocationHandler -and $ExecutionContext.InvokeCommand.LocationChangedAction -eq $script:LocationHandler) {
        $ExecutionContext.InvokeCommand.LocationChangedAction = $script:PreviousLocationHandler
    }
    $binding = if ($script:KeyBound) { Get-PSReadLineKeyHandler -Chord 'Alt+f' }
    if ($script:KeyBound -and $binding -and $binding.Function -eq 'WtToolsPanel') {
        if ($script:PreviousKeyHandler -and $script:PreviousKeyHandler.Group -ne 'Custom') {
            Set-PSReadLineKeyHandler -Chord 'Alt+f' -Function $script:PreviousKeyHandler.Function
        } else { Remove-PSReadLineKeyHandler -Chord 'Alt+f' }
    }
}
Export-ModuleMember -Function Enable-WtTools, Open-WtPanel, Stop-WtTools
