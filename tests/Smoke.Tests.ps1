#Requires -Version 7.4
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$modulePath = Join-Path $root 'powershell/WtTools.psm1'
$script:checks = 0
function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
# The host starts without WT, rejects an invalid request, survives it, then shuts
# down cleanly. This test never creates or closes user terminal windows.
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('wttools-tests-' + [guid]::NewGuid().ToString('N'))
$pipeName = 'wttools-tests-' + [guid]::NewGuid().ToString('N')
$hostProcess = $null
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
try {
    New-Item -ItemType Directory -Path $testRoot | Out-Null
    $compiledHost = Join-Path $root 'artifacts/host/wttools-host.exe'
    $timer = [Diagnostics.Stopwatch]::StartNew()
    if (Test-Path -LiteralPath $compiledHost) {
        $start = [Diagnostics.ProcessStartInfo]::new($compiledHost)
        $start.UseShellExecute = $false
        foreach ($argument in @($pipeName, $testRoot, $modulePath, (Join-Path $PSHOME 'pwsh.exe'))) { $start.ArgumentList.Add($argument) }
        $hostProcess = [Diagnostics.Process]::Start($start)
    } else {
        $hostScript = (Join-Path $root 'scripts/Start-WtToolsHost.ps1').Replace("'", "''")
        $code = "& '$hostScript' -PipeName '$pipeName' -StateRoot '$($testRoot.Replace("'", "''"))'"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
        $hostProcess = Start-Process (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-NoLogo', '-NoProfile', '-EncodedCommand', $encoded) `
            -WindowStyle Hidden -RedirectStandardError (Join-Path $testRoot 'stderr.txt') -PassThru
    }
    $hostInfo = Join-Path $testRoot 'host.json'
    while (-not (Test-Path -LiteralPath $hostInfo) -and $timer.Elapsed.TotalSeconds -lt 15) {
        if ($hostProcess.HasExited) { throw (Get-Content (Join-Path $testRoot 'stderr.txt') -Raw) }
        Start-Sleep -Milliseconds 100
    }
    Assert-True (Test-Path -LiteralPath $hostInfo) 'Host starts without dependencies or a build step'
    Assert-True ((Get-Content -LiteralPath $hostInfo -Raw | ConvertFrom-Json).backend -eq 'rust') 'The tested host is the Rust backend'
    $startupMs = $timer.ElapsedMilliseconds
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
    } finally { if (-not $duplicate.HasExited) { $duplicate.Kill() }; $duplicate.Dispose() }
    $actualHostId = (Get-Content -LiteralPath $hostInfo -Raw | ConvertFrom-Json).pid
    $actualHost = Get-Process -Id $actualHostId
    $workingSet = [math]::Round($actualHost.WorkingSet64 / 1MB, 1)
    $response = Send-TestRequest @{ action = 'shutdown' }
    Assert-True $response.ok 'Host acknowledges shutdown'
    Assert-True ($hostProcess.WaitForExit(5000)) 'Host exits after shutdown'
    Assert-True (-not (Test-Path -LiteralPath $hostInfo)) 'Host removes its running metadata'
    Write-Output "PASS: $script:checks checks. Host startup=${startupMs}ms, working set=${workingSet}MiB."
} finally {
    if ($hostProcess -and -not $hostProcess.HasExited) { $hostProcess.Kill(); $hostProcess.WaitForExit() }
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolvedTestRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
