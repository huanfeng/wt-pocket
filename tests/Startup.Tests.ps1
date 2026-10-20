#Requires -Version 7.4
# Exercises powershell/Startup.ps1 (the only PowerShell shipped with WTPocket).
# Every scenario runs in a child `pwsh -NoProfile` process, so this session, the
# real profile and the real state directory are never touched.
$ErrorActionPreference = 'Stop'
# Messages are asserted in English regardless of the machine's display language.
$env:WTPOCKET_LANG = 'en'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('wtpocket-startup-' + [guid]::NewGuid().ToString('N'))
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$script:checks = 0
$savedEnvironment = @{}
function Assert-True($Condition, [string] $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}

# Runs $Body (after a common prelude) in a child shell. The body reports by
# calling Emit with a hashtable; results travel through a UTF-8 file so Unicode
# paths survive the console code page. Returns the parsed result plus raw output.
function Invoke-Child([string] $Body, [hashtable] $Environment = @{}) {
    $id = [guid]::NewGuid().ToString('N')
    $scriptFile = Join-Path $temp "child-$id.ps1"
    $outFile = Join-Path $temp "child-$id.json"
    $prelude = @'
$ErrorActionPreference = 'Stop'
$Shim = $env:ST_SHIM; $Root = $env:ST_ROOT; $Work = $env:ST_WORK; $Temp = $env:ST_TEMP
function Emit($Value) { [IO.File]::WriteAllText($env:ST_OUT, ($Value | ConvertTo-Json -Compress -Depth 6), [Text.UTF8Encoding]::new($false)) }
function New-Handler([scriptblock] $Block) { [System.EventHandler[Management.Automation.LocationChangedEventArgs]] $Block }
'@
    [IO.File]::WriteAllText($scriptFile, $prelude + "`n" + $Body, [Text.UTF8Encoding]::new($true))
    $values = @{
        ST_SHIM = $script:shim; ST_ROOT = $script:stateRoot; ST_WORK = $script:work; ST_TEMP = $temp
        ST_STUB = $script:stub; ST_RECORD = (Join-Path $temp "record-$id.json"); ST_OUT = $outFile
        WT_SESSION = 'startup-test'; WT_PROFILE_ID = 'startup-profile'; WTTOOLS_PANEL = $null; STUB_EXIT = $null
    }
    foreach ($key in $Environment.Keys) { $values[$key] = $Environment[$key] }
    foreach ($key in $values.Keys) { $script:savedEnvironment[$key] = [Environment]::GetEnvironmentVariable($key) }
    try {
        foreach ($key in $values.Keys) { [Environment]::SetEnvironmentVariable($key, $values[$key]) }
        $output = & $pwsh -NoLogo -NoProfile -File $scriptFile 2>&1
        $exit = $LASTEXITCODE
    } finally {
        foreach ($key in $values.Keys) { [Environment]::SetEnvironmentVariable($key, $script:savedEnvironment[$key]) }
    }
    if ($exit -ne 0 -or -not [IO.File]::Exists($outFile)) {
        throw "Child scenario failed (exit $exit): $(($output | Out-String).Trim())"
    }
    [pscustomobject] @{
        Result = (Get-Content -LiteralPath $outFile -Raw -Encoding utf8 | ConvertFrom-Json)
        Output = $output
        Record = Join-Path $temp "record-$id.json"
    }
}

try {
    [IO.Directory]::CreateDirectory($temp) | Out-Null
    $stateRoot = Join-Path $temp 'state dir'
    $work = Join-Path $temp "工作 ‘目录’ '[test];"
    [IO.Directory]::CreateDirectory($work) | Out-Null

    # Package layout: Startup.ps1 next to the real wtpocket.exe, like artifacts/host.
    $builtExe = Join-Path $root 'artifacts/host/wtpocket.exe'
    if (-not [IO.File]::Exists($builtExe)) { throw "Missing $builtExe. Run scripts/Build.ps1 first." }
    $fixture = Join-Path $temp 'package'
    [IO.Directory]::CreateDirectory($fixture) | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'powershell/Startup.ps1') -Destination $fixture
    Copy-Item -LiteralPath $builtExe -Destination $fixture
    $shim = Join-Path $fixture 'Startup.ps1'

    # Argument-recording stand-in for wtpocket.exe.
    $stubDirectory = Join-Path $temp 'stub'
    [IO.Directory]::CreateDirectory($stubDirectory) | Out-Null
    $stub = Join-Path $stubDirectory 'Stub.cmd'
    [IO.File]::WriteAllText((Join-Path $stubDirectory 'Record.ps1'), @'
[IO.File]::WriteAllText($env:ST_RECORD, (@{ args = @($args); cwd = [Environment]::CurrentDirectory } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
if ($env:STUB_EXIT) { Write-Output 'stub-boom'; exit ([int] $env:STUB_EXIT) }
'@)
    [IO.File]::WriteAllText($stub, "@echo off`r`n`"$pwsh`" -NoLogo -NoProfile -File `"%~dp0Record.ps1`" %*`r`nexit /b %ERRORLEVEL%`r`n")

    # --- Cold start, bookkeeping and the variables/functions the shim may leave behind.
    $cold = Invoke-Child @'
Import-Module PSReadLine
Set-PSReadLineKeyHandler -Chord Alt+f -Function ForwardWord
$script:calls = 0
$prior = New-Handler ({ $script:calls++ })
$ExecutionContext.InvokeCommand.LocationChangedAction = $prior
Set-Location -LiteralPath $Work
$script:calls = 0
$promptBefore = (Get-Item Function:\prompt).ScriptBlock
$watch = [Diagnostics.Stopwatch]::StartNew()
$varsBefore = $null; $fnBefore = $null; $varsAfter = $null; $fnAfter = $null; $initialCalls = $null
$varsBefore = @(Get-Variable | ForEach-Object Name)
$fnBefore = @(Get-ChildItem Function: | ForEach-Object Name)
$watch.Restart()
. $Shim -StateRoot $Root
$watch.Stop()
$initialCalls = $script:calls
$varsAfter = @(Get-Variable | ForEach-Object Name)
$fnAfter = @(Get-ChildItem Function: | ForEach-Object Name)
$stateObject = $global:WtPocketState
$directoryFile = $stateObject.DirectoryFile
$initialDirectory = [IO.File]::ReadAllText($directoryFile)
$handler = $ExecutionContext.InvokeCommand.LocationChangedAction
. $Shim -StateRoot $Root
$guarded = [object]::ReferenceEquals($stateObject, $global:WtPocketState) -and ($ExecutionContext.InvokeCommand.LocationChangedAction -eq $handler)
Set-Location -LiteralPath $Temp
$callsAfterChange = $script:calls
$savedAfterChange = [IO.File]::ReadAllText($directoryFile)
$bound = Get-PSReadLineKeyHandler -Bound | Where-Object Key -eq 'Alt+f'
Emit @{
    ms = $watch.Elapsed.TotalMilliseconds
    promptSame = ((Get-Item Function:\prompt).ScriptBlock -eq $promptBefore)
    initialCalls = $initialCalls
    initialDirectoryExact = ($initialDirectory -ceq $Work)
    guarded = $guarded
    callsAfterChange = $callsAfterChange
    savedAfterChangeExact = ($savedAfterChange -ceq $Temp)
    newVariables = @($varsAfter | Where-Object { $_ -notin $varsBefore })
    newFunctions = @($fnAfter | Where-Object { $_ -notin $fnBefore })
    boundFunction = "$($bound.Function)"
    stateKeys = @($stateObject.Keys | Sort-Object)
    stateRootExact = ($stateObject.StateRoot -ceq $Root)
    panel = $stateObject.Panel
    exeIsSibling = ($stateObject.Exe -ceq (Join-Path (Split-Path $Shim) 'wtpocket.exe'))
    pwshIsCurrent = ($stateObject.Pwsh -ceq (Join-Path $PSHOME 'pwsh.exe'))
    loggedToHistoryFile = ((Split-Path $directoryFile) -ceq $Root)
    mentionsBelowHome = ($directoryFile -like '*last-directory-*.txt')
}
'@
    Write-Output ('Cold shim with PSReadLine preloaded: {0:F2} ms' -f $cold.Result.ms)
    Assert-True ($cold.Result.ms -lt 750) "Cold shim stays within the 750 ms budget (took $($cold.Result.ms) ms)"
    Assert-True $cold.Result.promptSame 'Shim does not change the prompt'
    Assert-True ($cold.Result.initialCalls -eq 0) 'Initialization does not invoke the previous location callback'
    Assert-True $cold.Result.initialDirectoryExact 'Initial directory is recorded literally (Unicode, quotes, brackets)'
    Assert-True $cold.Result.guarded 'Dot-sourcing twice keeps the same state and does not add a handler'
    Assert-True ($cold.Result.callsAfterChange -eq 1) 'Previous location handler runs exactly once per directory change'
    Assert-True $cold.Result.savedAfterChangeExact 'Changed directory is saved'
    Assert-True $cold.Result.loggedToHistoryFile 'Directory history lives in the state root'
    Assert-True $cold.Result.mentionsBelowHome 'Directory history file is named per Windows Terminal profile'
    Assert-True ($cold.Result.boundFunction -eq 'WtPocketPanel') 'Alt+F is bound to WtPocketPanel (replacing the previous binding)'
    Assert-True $cold.Result.stateRootExact 'State root is taken from -StateRoot'
    Assert-True $cold.Result.exeIsSibling 'Exe points at the wtpocket.exe next to Startup.ps1'
    Assert-True $cold.Result.pwshIsCurrent 'Pwsh points at the running pwsh.exe'
    Assert-True (-not $cold.Result.panel) 'Normal shells are not panel shells'
    $allowedVariables = @('Shim', 'Root', 'Work', 'Temp', 'StateRoot', 'WtPocketState')
    $leakedVariables = @($cold.Result.newVariables | Where-Object { $_ -notin $allowedVariables -and $_ -notlike 'wtpocket*' })
    Assert-True ($leakedVariables.Count -eq 0) "Shim leaks no undocumented variables (found: $($leakedVariables -join ', '))"
    Assert-True ((@($cold.Result.newFunctions | Sort-Object) -join ',') -eq 'wtp,wtpocket') "Shim defines only the wtpocket and wtp functions (found: $($cold.Result.newFunctions -join ', '))"

    # --- The wtpocket function runs the sibling executable.
    $versionRun = Invoke-Child @'
. $Shim -StateRoot $Root
$sibling = Join-Path (Split-Path $Shim) 'wtpocket.exe'
$viaFunction = (wtpocket version | Out-String).Trim()
$direct = (& $sibling version | Out-String).Trim()
$viaShort = (wtp version | Out-String).Trim()
Emit @{ viaFunction = $viaFunction; viaShort = $viaShort; direct = $direct; kind = (Get-Command wtpocket).CommandType.ToString(); exeIsSibling = ($global:WtPocketState.Exe -ceq $sibling) }
'@
    Assert-True ($versionRun.Result.kind -eq 'Function') 'wtpocket is a function'
    Assert-True ($versionRun.Result.viaFunction -match '\d+\.\d+\.\d+') "wtpocket version prints a version (got '$($versionRun.Result.viaFunction)')"
    Assert-True ($versionRun.Result.viaFunction -ceq $versionRun.Result.direct) 'wtpocket function runs the sibling executable'
    Assert-True ($versionRun.Result.viaShort -ceq $versionRun.Result.direct) 'wtp is the same command as wtpocket'

    # --- No WT_SESSION: nothing is defined, nothing is written.
    $outside = Invoke-Child @'
$prior = New-Handler ({ })
$ExecutionContext.InvokeCommand.LocationChangedAction = $prior
. $Shim -StateRoot $Root
Emit @{
    stateDefined = [bool] (Get-Variable WtPocketState -Scope Global -ErrorAction Ignore)
    functionDefined = [bool] (Get-Command wtpocket -ErrorAction Ignore)
    handlerUntouched = ($ExecutionContext.InvokeCommand.LocationChangedAction -eq $prior)
    stateDirectoryCreated = [IO.Directory]::Exists($Root)
}
'@ @{ WT_SESSION = $null; ST_ROOT = (Join-Path $temp 'fresh-outside') }
    Assert-True (-not $outside.Result.stateDefined -and -not $outside.Result.functionDefined) 'Without WT_SESSION the shim defines nothing'
    Assert-True $outside.Result.handlerUntouched 'Without WT_SESSION the location handler is untouched'
    Assert-True (-not $outside.Result.stateDirectoryCreated) 'Without WT_SESSION nothing is written'

    # --- Missing wtpocket.exe: warn and stay inert.
    $bare = Join-Path $temp 'bare'
    [IO.Directory]::CreateDirectory($bare) | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'powershell/Startup.ps1') -Destination $bare
    $missing = Invoke-Child @'
$prior = New-Handler ({ })
$ExecutionContext.InvokeCommand.LocationChangedAction = $prior
$records = @(. (Join-Path $env:ST_BARE 'Startup.ps1') -StateRoot $Root 3>&1)
$warnings = @($records | Where-Object { $_ -is [Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
Emit @{
    warnings = $warnings
    stateDefined = [bool] (Get-Variable WtPocketState -Scope Global -ErrorAction Ignore)
    functionDefined = [bool] (Get-Command wtpocket -ErrorAction Ignore)
    handlerUntouched = ($ExecutionContext.InvokeCommand.LocationChangedAction -eq $prior)
    stateDirectoryCreated = [IO.Directory]::Exists($Root)
}
'@ @{ ST_BARE = $bare; ST_ROOT = (Join-Path $temp 'fresh-missing') }
    Assert-True (@($missing.Result.warnings).Count -eq 1 -and $missing.Result.warnings[0] -like '*wtpocket.exe is missing*') 'Missing wtpocket.exe produces one actionable warning'
    Assert-True (-not $missing.Result.stateDefined -and -not $missing.Result.functionDefined -and -not $missing.Result.stateDirectoryCreated) 'Missing wtpocket.exe leaves the shell untouched'
    Assert-True $missing.Result.handlerUntouched 'Missing wtpocket.exe leaves the location handler untouched'

    # --- Directory restore: only from the home directory, per profile, only to existing directories.
    $restore = Invoke-Child @'
function Reset-Shim {
    Remove-Variable WtPocketState -Scope Global -ErrorAction Ignore
    Remove-Item Function:\wtpocket -ErrorAction Ignore
    $ExecutionContext.InvokeCommand.LocationChangedAction = $null
}
Set-Location -LiteralPath $Temp
. $Shim -StateRoot $Root
$directoryFile = $global:WtPocketState.DirectoryFile
Reset-Shim

[IO.File]::WriteAllText($directoryFile, $Work)
Set-Location -LiteralPath $HOME
. $Shim -StateRoot $Root
$restoredFromHome = ((Get-Location).ProviderPath -ceq $Work)
Reset-Shim

Set-Location -LiteralPath $Temp
. $Shim -StateRoot $Root
$keptOutsideHome = ((Get-Location).ProviderPath -ceq $Temp)
Reset-Shim

[IO.File]::WriteAllText($directoryFile, (Join-Path $Temp 'gone'))
Set-Location -LiteralPath $HOME
. $Shim -StateRoot $Root
$ignoredMissing = ((Get-Location).ProviderPath -ceq $HOME)
Reset-Shim

$env:WT_PROFILE_ID = 'different-profile'
Set-Location -LiteralPath $Temp
. $Shim -StateRoot $Root
$differentFile = $global:WtPocketState.DirectoryFile
Emit @{ restoredFromHome = $restoredFromHome; keptOutsideHome = $keptOutsideHome; ignoredMissing = $ignoredMissing; separateProfiles = ($differentFile -ne $directoryFile) }
'@
    Assert-True $restore.Result.restoredFromHome 'Saved directory is restored when starting in the home directory'
    Assert-True $restore.Result.keptOutsideHome 'Saved directory is not restored when starting elsewhere'
    Assert-True $restore.Result.ignoredMissing 'A saved directory that no longer exists is ignored'
    Assert-True $restore.Result.separateProfiles 'Different Windows Terminal profiles do not share directory history'

    # --- Panel shells: function and state only; no memory, no hotkey.
    $panelRun = Invoke-Child @'
Import-Module PSReadLine
Set-PSReadLineKeyHandler -Chord Alt+f -Function ForwardWord
$prior = New-Handler ({ })
$ExecutionContext.InvokeCommand.LocationChangedAction = $prior
Set-Location -LiteralPath $HOME
. $Shim -StateRoot $Root
$stayedHome = ((Get-Location).ProviderPath -ceq $HOME)
Set-Location -LiteralPath $Temp
$bound = Get-PSReadLineKeyHandler -Bound | Where-Object Key -eq 'Alt+f'
Emit @{
    panel = $global:WtPocketState.Panel
    functionDefined = [bool] (Get-Command wtpocket -ErrorAction Ignore)
    stayedHome = $stayedHome
    handlerUntouched = ($ExecutionContext.InvokeCommand.LocationChangedAction -eq $prior)
    directoryFileNull = ($null -eq $global:WtPocketState.DirectoryFile)
    stateDirectoryCreated = [IO.Directory]::Exists($Root)
    boundFunction = "$($bound.Function)"
}
'@ @{ WTTOOLS_PANEL = '1'; ST_ROOT = (Join-Path $temp 'fresh-panel') }
    Assert-True $panelRun.Result.panel 'WTTOOLS_PANEL=1 marks the state as a panel shell'
    Assert-True $panelRun.Result.functionDefined 'Panel shells still get the wtpocket function'
    Assert-True $panelRun.Result.stayedHome 'Panel shells never restore directory history'
    Assert-True ($panelRun.Result.handlerUntouched -and $panelRun.Result.directoryFileNull -and -not $panelRun.Result.stateDirectoryCreated) 'Panel shells neither record directories nor install a location handler'
    Assert-True ($panelRun.Result.boundFunction -eq 'ForwardWord') 'Panel shells leave the user Alt+F binding alone (the host handles Alt+F)'

    # --- Chaining: handlers installed before and after the shim keep working.
    $chain = Invoke-Child @'
$script:calls = 0
$prior = New-Handler ({ $script:calls++ })
$ExecutionContext.InvokeCommand.LocationChangedAction = $prior
Set-Location -LiteralPath $Temp
. $Shim -StateRoot $Root
$directoryFile = $global:WtPocketState.DirectoryFile
$chainState = @{ Handler = $ExecutionContext.InvokeCommand.LocationChangedAction; Later = 0 }
$wrapper = New-Handler (({ param($sender, $eventArgs) $chainState.Later++; $chainState.Handler.Invoke($sender, $eventArgs) }).GetNewClosure())
$ExecutionContext.InvokeCommand.LocationChangedAction = $wrapper
$script:calls = 0
Set-Location -LiteralPath $Work
$afterFileSystem = @{ prior = $script:calls; later = $chainState.Later; saved = ([IO.File]::ReadAllText($directoryFile) -ceq $Work) }
$script:calls = 0
Set-Location HKCU:\
Emit @{
    afterFileSystem = $afterFileSystem
    registryPriorCalls = $script:calls
    registryKeptHistory = ([IO.File]::ReadAllText($directoryFile) -ceq $Work)
    wrapperStillInstalled = ($ExecutionContext.InvokeCommand.LocationChangedAction -eq $wrapper)
}
'@
    Assert-True ($chain.Result.afterFileSystem.prior -eq 1 -and $chain.Result.afterFileSystem.later -eq 1) 'Handlers on both sides of the shim each run exactly once'
    Assert-True $chain.Result.afterFileSystem.saved 'Directory is saved through a later chained handler'
    Assert-True ($chain.Result.registryPriorCalls -eq 1) 'Previous handler still sees non-filesystem locations'
    Assert-True $chain.Result.registryKeptHistory 'Non-filesystem locations never overwrite directory history'
    Assert-True $chain.Result.wrapperStillInstalled 'The shim does not remove handlers installed after it'

    # --- Alt+F handler: run the shipped script block against a recording stand-in for wtpocket.exe.
    $handlerRun = Invoke-Child @'
Import-Module PSReadLine
Set-Location -LiteralPath $Work
. $Shim -StateRoot $Root
$ast = [Management.Automation.Language.Parser]::ParseFile($Shim, [ref] $null, [ref] $null)
$command = $ast.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Set-PSReadLineKeyHandler' }, $true)
$parameter = $command.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'ScriptBlock' }
$index = $command.CommandElements.IndexOf($parameter)
$handler = $command.CommandElements[$index + 1].ScriptBlock.GetScriptBlock()
$global:WtPocketState.Exe = $env:ST_STUB
$sessionBefore = $global:WtPocketState.SessionId

$first = @(& $handler 3>&1)
$firstRecord = Get-Content -LiteralPath $env:ST_RECORD -Raw -Encoding utf8 | ConvertFrom-Json
$sessionAfter = $global:WtPocketState.SessionId
Remove-Item -LiteralPath $env:ST_RECORD
$second = @(& $handler 3>&1)
$secondRecord = Get-Content -LiteralPath $env:ST_RECORD -Raw -Encoding utf8 | ConvertFrom-Json

Remove-Item -LiteralPath $env:ST_RECORD
$env:STUB_EXIT = '3'
$failed = @(& $handler 3>&1)
$failedWarnings = @($failed | Where-Object { $_ -is [Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
Remove-Item -LiteralPath $env:ST_RECORD
$env:STUB_EXIT = $null

Set-Location HKCU:\
$registry = @(& $handler 3>&1)
$registryWarnings = @($registry | Where-Object { $_ -is [Management.Automation.WarningRecord] } | ForEach-Object { $_.Message })
Emit @{
    args = @($firstRecord.args)
    cwdExact = ($firstRecord.cwd -ceq $Work)
    firstWarnings = @($first | Where-Object { $_ -is [Management.Automation.WarningRecord] }).Count
    sessionBefore = $sessionBefore
    sessionAfter = $sessionAfter
    secondArgs = @($secondRecord.args)
    expectedState = $global:WtPocketState.StateRoot
    expectedPwsh = $global:WtPocketState.Pwsh
    pid = $PID
    failedWarnings = $failedWarnings
    registryWarnings = $registryWarnings
    registryLaunched = [IO.File]::Exists($env:ST_RECORD)
}
'@
    $r = $handlerRun.Result
    Assert-True ($null -eq $r.sessionBefore) 'No session id exists before the first Alt+F'
    Assert-True ($r.sessionAfter -match "^$($r.pid)-\d+$") "Session id combines the shell PID and its start time (got '$($r.sessionAfter)')"
    Assert-True (@($r.args).Count -eq 7 -and $r.args[0] -eq 'open' -and $r.args[1] -eq '--state' -and $r.args[3] -eq '--pwsh' -and $r.args[5] -eq '--session') 'Alt+F runs: open --state <root> --pwsh <path> --session <id>'
    Assert-True ($r.args[2] -ceq $r.expectedState) 'Alt+F passes the state root'
    Assert-True ($r.args[4] -ceq $r.expectedPwsh) 'Alt+F passes the pwsh path'
    Assert-True ($r.args[6] -ceq $r.sessionAfter) 'Alt+F passes the session id'
    Assert-True $r.cwdExact 'The native process inherits the current location (Unicode and punctuation intact)'
    Assert-True ($r.firstWarnings -eq 0) 'A successful open produces no warnings'
    Assert-True (@($r.secondArgs)[6] -ceq $r.sessionAfter) 'The session id is stable across Alt+F presses'
    Assert-True (@($r.failedWarnings).Count -eq 1 -and $r.failedWarnings[0] -like '*stub-boom*') 'A non-zero exit becomes a warning carrying the output'
    Assert-True (@($r.registryWarnings).Count -eq 1 -and $r.registryWarnings[0] -like '*filesystem*') 'A non-filesystem location warns instead of launching'
    Assert-True (-not $r.registryLaunched) 'A non-filesystem location never starts wtpocket'

    # --- Session records feed `wtpocket restore`: one file per terminal session, directory only.
    $sessionId = [guid]::NewGuid().ToString()
    $profileId = '{574e775e-4f2a-5b96-ac1e-a2962a402336}'
    $recorded = Invoke-Child @'
$before = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
Set-Location -LiteralPath $Work
. $Shim -StateRoot $Root
$file = Join-Path (Join-Path $Root 'sessions') ($env:WT_SESSION + '.json')
$first = Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json
Set-Location -LiteralPath $Temp
$second = Get-Content -LiteralPath $file -Raw -Encoding utf8 | ConvertFrom-Json
Emit @{
    work = $Work; temp = $Temp; before = $before; pid = $PID
    firstPath = $first.path; firstProfile = $first.profile; firstPid = $first.pid; firstStarted = $first.started; firstUpdated = $first.updated
    secondPath = $second.path
    started = [Diagnostics.Process]::GetCurrentProcess().StartTime.ToFileTimeUtc()
    files = @(Get-ChildItem -LiteralPath (Join-Path $Root 'sessions') | ForEach-Object Name)
    keys = @($first.PSObject.Properties.Name)
}
'@ @{ WT_SESSION = $sessionId; WT_PROFILE_ID = $profileId; ST_ROOT = (Join-Path $temp 'sessions-state') }
    $r = $recorded.Result
    Assert-True ($r.firstPath -ceq $r.work) 'The session file records the starting directory (with quotes, brackets and Unicode intact)'
    Assert-True ($r.secondPath -ceq $r.temp) 'Changing directory updates the session file'
    Assert-True ($r.firstProfile -ceq $profileId -and $r.firstPid -eq $r.pid -and $r.firstStarted -eq $r.started) 'The session file identifies its profile and shell process'
    Assert-True ($r.firstUpdated -ge $r.before) 'The session file carries an update time'
    Assert-True ((@($r.keys) -join ',') -ceq 'path,profile,pid,started,updated') 'The session file stores only the directory and its identity (no commands)'
    Assert-True (@($r.files).Count -eq 1 -and $r.files[0] -ceq "$sessionId.json") 'One file per terminal session, named after WT_SESSION'

    $notRecorded = Invoke-Child @'
Set-Location -LiteralPath $Work
. $Shim -StateRoot $Root
Emit @{ exists = [IO.Directory]::Exists((Join-Path $Root 'sessions')) }
'@ @{ WT_SESSION = 'not-a-guid'; ST_ROOT = (Join-Path $temp 'no-sessions-state') }
    Assert-True (-not $notRecorded.Result.exists) 'A WT_SESSION that is not a GUID is never turned into a file name'
    $panel = Invoke-Child @'
Set-Location -LiteralPath $Work
. $Shim -StateRoot $Root
Emit @{ exists = [IO.Directory]::Exists((Join-Path $Root 'sessions')) }
'@ @{ WT_SESSION = [guid]::NewGuid().ToString(); WTTOOLS_PANEL = '1'; ST_ROOT = (Join-Path $temp 'panel-state') }
    Assert-True (-not $panel.Result.exists) 'Panel shells record nothing'

    Write-Output "PASS: $script:checks startup checks"
} finally {
    if ([IO.Path]::GetFullPath($temp).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
