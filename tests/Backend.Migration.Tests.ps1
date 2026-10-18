#Requires -Version 7.4
# Exercise legacy-backend handoff through `wtpocket open` without opening WT windows.
# The toggle itself fails because no Windows Terminal is focused; that is expected.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $root 'artifacts/host/wtpocket.exe'
$pwshPath = Join-Path $PSHOME 'pwsh.exe'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('wtpocket-migration-' + [guid]::NewGuid().ToString('N'))
$checks = 0
$runningHost = $null
$newHost = $null
function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Get-StatePipeName([string] $State) {
    $key = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value + '|' + [IO.Path]::GetFullPath($State).ToUpperInvariant()
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($key)))
    'wttools-' + $hash.Substring(0, 24)
}
function Start-FixtureHost([string] $PipeName) {
    $start = [Diagnostics.ProcessStartInfo]::new($exe)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    foreach ($argument in @('serve', $PipeName, $testRoot, $pwshPath)) { $start.ArgumentList.Add($argument) }
    [Diagnostics.Process]::Start($start)
}
function Wait-HostInfo([Diagnostics.Process] $Process, [string] $Path) {
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not [IO.File]::Exists($Path)) {
        if ($Process.HasExited -or [DateTime]::UtcNow -ge $deadline) { throw 'Fixture host did not start.' }
        Start-Sleep -Milliseconds 30
    }
}
function Invoke-Open {
    $previous = $env:WT_SESSION
    $env:WT_SESSION = '1'
    try {
        # Capturing through pipes also proves the background host does not inherit them.
        $start = [Diagnostics.ProcessStartInfo]::new($exe)
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in @('open', $testRoot, '--state', $testRoot, '--session', 't', '--pwsh', $pwshPath)) { $start.ArgumentList.Add($argument) }
        $process = [Diagnostics.Process]::Start($start)
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(30000)) { $process.Kill(); throw 'wtpocket open did not return.' }
        $output = $outTask.Result + "`n" + $errTask.Result
        [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output.Trim() }
    } finally {
        if ($null -eq $previous) { Remove-Item Env:WT_SESSION -ErrorAction SilentlyContinue } else { $env:WT_SESSION = $previous }
    }
}
try {
    Assert-True (Test-Path -LiteralPath $exe) 'artifacts/host/wtpocket.exe exists (run scripts/Build.ps1)'
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $pipeName = Get-StatePipeName $testRoot
    $infoPath = Join-Path $testRoot 'host.json'
    $runningHost = Start-FixtureHost $pipeName
    Wait-HostInfo $runningHost $infoPath
    # v0.1.x metadata has exactly these fields. The wire shutdown protocol is
    # unchanged, so a real host with rewritten metadata stands in for a legacy one.
    [IO.File]::WriteAllText($infoPath, (@{ pid = $runningHost.Id; pipeName = $pipeName } | ConvertTo-Json))
    $oldPid = $runningHost.Id

    $result = Invoke-Open
    $hostLog = "log=" + $(if (Test-Path (Join-Path $testRoot "host.log")) { Get-Content (Join-Path $testRoot "host.log") -Raw } else { "none" }) + " info=" + $(if (Test-Path $infoPath) { Get-Content $infoPath -Raw } else { "none" }) + " procs=" + ((Get-Process wtpocket -ErrorAction SilentlyContinue | ForEach-Object Id) -join ",") + " exe=" + $exe + " fg=" + (Get-Item $exe).Length
    Assert-True ($result.ExitCode -ne 0 -and $result.Output -match 'Windows Terminal') "open reports the missing Windows Terminal after the handoff (exit $($result.ExitCode): $($result.Output) log: $hostLog)"
    Assert-True ($runningHost.WaitForExit(5000)) 'Legacy backend handoff uses graceful shutdown'
    $newInfo = Get-Content -LiteralPath $infoPath -Raw | ConvertFrom-Json
    Assert-True ($newInfo.backend -eq 'rust') 'The replacement host records the rust backend'
    Assert-True ($newInfo.pid -ne $oldPid) 'The replacement host is a new process'
    $runningHost.Dispose()
    $runningHost = $null
    $newHost = Get-Process -Id $newInfo.pid
    Assert-True (-not $newHost.HasExited) 'The replacement host is running'

    $result = Invoke-Open
    Assert-True ($result.ExitCode -ne 0 -and $result.Output -match 'Windows Terminal') 'A repeat open still reaches the host'
    Assert-True ((Get-Content -LiteralPath $infoPath -Raw | ConvertFrom-Json).pid -eq $newInfo.pid) 'Subsequent opens preserve the running Rust host'

    $result = & $exe stop --state $testRoot 2>&1 | Out-String
    Assert-True ($LASTEXITCODE -eq 0) 'stop succeeds'
    Assert-True ($newHost.WaitForExit(5000)) 'Replacement backend stops cleanly'
    Assert-True (-not (Test-Path -LiteralPath $infoPath)) 'stop removes host metadata'

    # Stale metadata from a crashed legacy host must not block startup.
    [IO.File]::WriteAllText($infoPath, (@{ pid = [int]::MaxValue; pipeName = $pipeName } | ConvertTo-Json))
    $newHost.Dispose()
    $result = Invoke-Open
    Assert-True ($result.ExitCode -ne 0 -and $result.Output -match 'Windows Terminal') 'open reaches a fresh host despite stale legacy metadata'
    $newInfo = Get-Content -LiteralPath $infoPath -Raw | ConvertFrom-Json
    Assert-True ($newInfo.backend -eq 'rust') 'Stale legacy metadata does not prevent Rust startup'
    $newHost = Get-Process -Id $newInfo.pid
    $null = & $exe stop --state $testRoot 2>&1
    Assert-True ($newHost.WaitForExit(5000)) 'Host started from stale metadata stops cleanly'
    Write-Output "PASS: $checks backend migration checks (no Terminal windows)."
} finally {
    $null = & $exe stop --state $testRoot 2>&1
    foreach ($process in @($runningHost, $newHost)) {
        if ($process) {
            if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
            $process.Dispose()
        }
    }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
