#Requires -Version 7.4
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('wttools-startup-' + [guid]::NewGuid().ToString('N'))
$originalLocation = Get-Location
$originalHandler = $ExecutionContext.InvokeCommand.LocationChangedAction
$originalSession = $env:WT_SESSION
$originalProfile = $env:WT_PROFILE_ID
$originalPanel = $env:WTTOOLS_PANEL
$checks = 0
function Assert($condition, $message) {
    if (-not $condition) { throw $message }
    $script:checks++
}
function Reset-Startup {
    if (Get-Module WtTools) { Remove-Module WtTools }
    $ExecutionContext.InvokeCommand.LocationChangedAction = $originalHandler
    Remove-Variable WtToolsStartupState -Scope Global -ErrorAction Ignore
    Remove-Item Function:\Open-WtPanel -ErrorAction Ignore
}
try {
    [IO.Directory]::CreateDirectory($temp) | Out-Null
    $state = Join-Path $temp 'state'
    $work = Join-Path $temp "工作 '目录;[test]"
    [IO.Directory]::CreateDirectory($work) | Out-Null
    $fixture = Join-Path $temp 'powershell'
    [IO.Directory]::CreateDirectory($fixture) | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'powershell/Startup.ps1') -Destination $fixture
    @'
function Enable-WtTools {
    param([switch]$RememberDirectory,[switch]$RestoreDirectory,[switch]$Panel,[string]$StateRoot)
    $global:StartupForwardedEnable = @{} + $PSBoundParameters
    $global:StartupTransferredKey = $script:PreviousKeyHandler
    $global:StartupTransferredBound = $script:KeyBound
}
function Open-WtPanel {
    param([string]$Directory)
    $global:StartupForwardedOpen = @{} + $PSBoundParameters
}
Export-ModuleMember -Function Enable-WtTools,Open-WtPanel
'@ | Set-Content -LiteralPath (Join-Path $fixture 'WtTools.psm1')
    $shim = Join-Path $fixture 'Startup.ps1'
    $env:WT_SESSION = 'startup-test'
    $env:WT_PROFILE_ID = 'startup-profile'
    $env:WTTOOLS_PANEL = $null
    Import-Module PSReadLine
    Set-PSReadLineKeyHandler -Chord Alt+f -Function ForwardWord
    $script:locationCalls = 0
    $prior = [System.EventHandler[Management.Automation.LocationChangedEventArgs]] { $script:locationCalls++ }
    $ExecutionContext.InvokeCommand.LocationChangedAction = $prior
    Set-Location -LiteralPath $work
    $script:locationCalls = 0
    $promptBefore = (Get-Item Function:\prompt).ScriptBlock
    $watch = [Diagnostics.Stopwatch]::StartNew()
    . $shim -StateRoot $state
    $watch.Stop()
    Write-Output ('Cold shim with PSReadLine preloaded: {0:F2} ms' -f $watch.Elapsed.TotalMilliseconds)
    Assert (-not (Get-Module WtTools)) 'Shim imported full module eagerly.'
    Assert (-not ('WtTools.ShellNative' -as [type])) 'Shim loaded native API eagerly.'
    Assert ((Get-Item Function:\prompt).ScriptBlock -eq $promptBefore) 'Shim changed prompt.'
    Assert ($script:locationCalls -eq 0) 'Initialization invoked previous location callback.'
    $directoryFile = $global:WtToolsStartupState.DirectoryFile
    Assert ([IO.File]::ReadAllText($directoryFile) -ceq $work) 'Initial directory was not recorded literally.'
    $handler = $ExecutionContext.InvokeCommand.LocationChangedAction
    . $shim -StateRoot $state
    Assert ($ExecutionContext.InvokeCommand.LocationChangedAction -eq $handler) 'Repeated shim added another location handler.'
    Set-Location -LiteralPath $temp
    Assert ($script:locationCalls -eq 1) 'Prior handler should run exactly once per directory change.'
    Assert ([IO.File]::ReadAllText($directoryFile) -ceq $temp) 'Changed directory not saved.'
    Open-WtPanel -Directory $work
    Assert ($global:StartupForwardedOpen.Directory -ceq $work) 'Lazy command lost literal directory.'
    Assert ($global:StartupForwardedEnable.StateRoot -ceq $state) 'Lazy command lost state root.'
    Assert ($global:StartupForwardedEnable.RememberDirectory -and $global:StartupForwardedEnable.RestoreDirectory) 'Lazy enable flags missing.'
    Assert ($global:StartupTransferredBound -and $global:StartupTransferredKey.Function -eq 'ForwardWord') 'Original key handler ownership not transferred.'
    Assert ($ExecutionContext.InvokeCommand.LocationChangedAction -eq $prior) 'Prior location handler not restored during transition.'
    Assert (-not (Get-Variable WtToolsStartupState -Scope Global -ErrorAction Ignore)) 'Shim state survived transition.'
    Reset-Startup
    Set-Location -LiteralPath $temp
    $ExecutionContext.InvokeCommand.LocationChangedAction = $prior
    . $shim -StateRoot $state
    $chainState = @{ Handler = $ExecutionContext.InvokeCommand.LocationChangedAction }
    $wrapper = [System.EventHandler[Management.Automation.LocationChangedEventArgs]] ({
        param($sender, $eventArgs)
        $chainState.Handler.Invoke($sender, $eventArgs)
    }.GetNewClosure())
    $ExecutionContext.InvokeCommand.LocationChangedAction = $wrapper
    Open-WtPanel
    $script:locationCalls = 0
    $beforeChainChange = [IO.File]::ReadAllText($directoryFile)
    Set-Location -LiteralPath $work
    Assert ($script:locationCalls -eq 1) 'Inactive chained shim lost previous callback.'
    Assert ([IO.File]::ReadAllText($directoryFile) -ceq $beforeChainChange) 'Inactive chained shim still wrote directory history.'
    Assert ($ExecutionContext.InvokeCommand.LocationChangedAction -eq $wrapper) 'Lazy transition removed another tool callback.'
    Reset-Startup
    [IO.File]::WriteAllText($directoryFile, $work)
    Set-Location -LiteralPath $HOME
    . $shim -StateRoot $state
    Assert ((Get-Location).ProviderPath -ceq $work) 'Saved directory not restored from home.'
    Reset-Startup
    $env:WT_PROFILE_ID = 'different-profile'
    Set-Location -LiteralPath $temp
    . $shim -StateRoot $state
    Assert ($global:WtToolsStartupState.DirectoryFile -ne $directoryFile) 'Different WT profile shared directory history.'
    Reset-Startup
    $env:WT_PROFILE_ID = 'startup-profile'
    $env:WTTOOLS_PANEL = '1'
    Set-Location -LiteralPath $HOME
    $savedBefore = [IO.File]::ReadAllText($directoryFile)
    . $shim -StateRoot $state
    Assert ((Get-Location).ProviderPath -ceq $HOME) 'Panel restored parent history.'
    Set-Location -LiteralPath $temp
    Assert ([IO.File]::ReadAllText($directoryFile) -ceq $savedBefore) 'Panel overwrote parent history.'
    Open-WtPanel
    Assert ($global:StartupForwardedEnable.Panel) 'Panel mode lost on lazy transition.'
    Assert (-not $global:StartupForwardedOpen.ContainsKey('Directory')) 'Implicit directory became explicit during forwarding.'
    Write-Output "PASS: $checks startup checks"
} finally {
    Reset-Startup
    $ExecutionContext.InvokeCommand.LocationChangedAction = $originalHandler
    $env:WT_SESSION = $originalSession
    $env:WT_PROFILE_ID = $originalProfile
    $env:WTTOOLS_PANEL = $originalPanel
    Set-Location -LiteralPath $originalLocation.ProviderPath
    if ([IO.Path]::GetFullPath($temp).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $temp -Recurse -Force
    }
}
