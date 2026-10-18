#Requires -Version 7.4
$ErrorActionPreference = 'Stop'
# Messages are asserted in English regardless of the machine's display language.
$env:WTPOCKET_LANG = 'en'
$root = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $root 'artifacts/host/wtpocket.exe'
$pwshPath = Join-Path $PSHOME 'pwsh.exe'
$script:checks = 0
function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
# The host starts without WT, rejects an invalid request, survives it, then shuts
# down cleanly. This test never creates or closes user terminal windows.
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('wttools-tests-' + [guid]::NewGuid().ToString('N'))
$hostProcess = $null
$duplicate = $null
# `wtpocket stop --state` finds the host by the pipe name derived from the state
# directory (sha256 of SID|UPPERCASED path), so the test host must use that name.
function Get-StatePipeName([string] $State) {
    $key = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value + '|' + [IO.Path]::GetFullPath($State).ToUpperInvariant()
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($key)))
    'wttools-' + $hash.Substring(0, 24)
}
$pipeName = Get-StatePipeName $testRoot
function Send-TestRequest([hashtable] $Request) {
    Send-TestJson ($Request | ConvertTo-Json -Compress)
}
function Send-TestJson([string] $Json) {
    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [IO.Pipes.PipeDirection]::InOut)
    try {
        $pipe.Connect(3000)
        $reader = [IO.StreamReader]::new($pipe)
        $writer = [IO.StreamWriter]::new($pipe, [Text.UTF8Encoding]::new($false), 1024, $true)
        $writer.AutoFlush = $true
        $writer.WriteLine($Json)
        $pending = $reader.ReadLineAsync()
        if (-not $pending.Wait(5000)) { throw 'Host response timeout' }
        return $pending.Result | ConvertFrom-Json
    } finally { $pipe.Dispose() }
}
function Start-TestHost {
    $info = [Diagnostics.ProcessStartInfo]::new($exe)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    foreach ($argument in @('serve', $pipeName, $testRoot, $pwshPath)) { $info.ArgumentList.Add($argument) }
    $info
}
function Invoke-Cli([string[]] $Arguments) {
    $output = & $exe @Arguments 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output.Trim() }
}
function Wait-HostInfo([Diagnostics.Process] $Process, [string] $Path) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $Path) -and $timer.Elapsed.TotalSeconds -lt 15) {
        if ($Process.HasExited) { throw "Host exited early with code $($Process.ExitCode)." }
        Start-Sleep -Milliseconds 20
    }
}
try {
    Assert-True (Test-Path -LiteralPath $exe) 'artifacts/host/wtpocket.exe exists (run scripts/Build.ps1)'
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $hostInfo = Join-Path $testRoot 'host.json'
    $start = Start-TestHost
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $hostProcess = [Diagnostics.Process]::Start($start)
    Wait-HostInfo $hostProcess $hostInfo
    Assert-True (Test-Path -LiteralPath $hostInfo) 'Host starts without dependencies or a build step'
    $startupMs = $timer.ElapsedMilliseconds
    $info = Get-Content -LiteralPath $hostInfo -Raw | ConvertFrom-Json
    Assert-True ($info.backend -eq 'rust') 'The tested host is the Rust backend'
    Assert-True ($info.pipeName -eq $pipeName) 'host.json records the pipe name derived from the state directory'
    $response = Send-TestRequest @{ action = 'toggle'; directory = $testRoot; sourceWindow = 0 }
    Assert-True (-not $response.ok -and $response.error -match 'Windows Terminal') 'Host rejects invalid source HWND'
    $response = Send-TestRequest @{ action = 'unknown' }
    Assert-True (-not $response.ok) 'Host rejects unsupported actions and keeps serving'
    $response = Send-TestJson '{broken-json'
    Assert-True (-not $response.ok) 'Malformed JSON receives an error without stopping the host'
    $response = Send-TestJson ('{"sourceWindow":"' + ('x' * 60000) + '"}')
    Assert-True (-not $response.ok -and $response.error.Length -le 1024) 'Client strings cannot expand an error beyond the pipe output buffer'
    $response = Send-TestJson ('x' * 65537)
    Assert-True (-not $response.ok -and $response.error -match '64 KiB') 'Oversized requests are bounded'
    $abandoned = [IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [IO.Pipes.PipeDirection]::InOut)
    $abandoned.Connect(3000)
    $abandoned.Dispose()
    $response = Send-TestRequest @{ action = 'unknown' }
    Assert-True (-not $response.ok) 'Host recovers from a client disconnecting without a request'

    $idle = [IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [IO.Pipes.PipeDirection]::InOut)
    try {
        $idle.Connect(3000)
        $idleReader = [IO.StreamReader]::new($idle)
        $pendingIdle = $idleReader.ReadLineAsync()
        Assert-True ($pendingIdle.Wait(17000) -and ($pendingIdle.Result | ConvertFrom-Json).error -match 'timed out') 'Idle clients time out without blocking the host indefinitely'
    } finally { $idle.Dispose() }
    $duplicate = [Diagnostics.Process]::Start($start)
    try {
        Assert-True ($duplicate.WaitForExit(3000) -and $duplicate.ExitCode -eq 0) 'A second host for the same pipe exits without replacing the running host'
        Assert-True ((Get-Content -LiteralPath $hostInfo -Raw | ConvertFrom-Json).pid -eq $hostProcess.Id) 'Duplicate startup preserves existing host metadata'
    } finally { if (-not $duplicate.HasExited) { $duplicate.Kill() }; $duplicate.Dispose(); $duplicate = $null }
    $actualHostId = (Get-Content -LiteralPath $hostInfo -Raw | ConvertFrom-Json).pid
    $actualHost = Get-Process -Id $actualHostId
    $workingSet = [math]::Round($actualHost.WorkingSet64 / 1MB, 1)
    $response = Send-TestRequest @{ action = 'shutdown' }
    Assert-True $response.ok 'Host acknowledges shutdown'
    Assert-True ($hostProcess.WaitForExit(5000)) 'Host exits after shutdown'
    Assert-True (-not (Test-Path -LiteralPath $hostInfo)) 'Host removes its running metadata'

    # CLI surface.
    $result = Invoke-Cli @('version')
    Assert-True ($result.ExitCode -eq 0 -and $result.Output -match '^wtpocket \d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$') 'version prints "wtpocket <semver>"'
    $result = Invoke-Cli @('bogus')
    Assert-True ($result.ExitCode -ne 0 -and $result.Output -match 'Unknown command') 'An unknown command exits non-zero'

    $hostProcess = [Diagnostics.Process]::Start((Start-TestHost))
    Wait-HostInfo $hostProcess $hostInfo
    Assert-True (Test-Path -LiteralPath $hostInfo) 'A host can be restarted on the same state directory'
    $result = Invoke-Cli @('stop', '--state', $testRoot)
    Assert-True ($result.ExitCode -eq 0 -and $result.Output -match 'Stopped') 'stop reports that it stopped the running host'
    Assert-True ($hostProcess.WaitForExit(5000)) 'stop shuts the host process down'
    Assert-True (-not (Test-Path -LiteralPath $hostInfo)) 'stop leaves no host metadata behind'
    $result = Invoke-Cli @('stop', '--state', $testRoot)
    Assert-True ($result.ExitCode -eq 0 -and $result.Output -match 'not running') 'A second stop reports not running and succeeds'
    Write-Output "PASS: $script:checks checks. Host startup=${startupMs}ms, working set=${workingSet}MiB."
} finally {
    foreach ($process in @($hostProcess, $duplicate)) {
        if ($process -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
    }
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedTestRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
