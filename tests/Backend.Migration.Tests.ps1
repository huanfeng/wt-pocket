#Requires -Version 7.4
# Exercise legacy-backend handoff on the real pipe without opening WT windows.
[CmdletBinding()]
param([string] $LegacyHostPath)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('wtpocket-migration-' + [guid]::NewGuid().ToString('N'))
$checks = 0
$runningHost = $null
function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Invoke-InvalidRequest {
    $rejected = $false
    try { & (Get-Module WtTools) { Send-WtToolsRequest @{ action = 'unknown' } } }
    catch { $rejected = $_.Exception.Message -match 'Unknown action' }
    Assert-True $rejected 'The module receives a response from the replacement backend'
}
try {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    Import-Module (Join-Path $root 'powershell/WtTools.psm1')
    & (Get-Module WtTools) { param($state) $script:StateRoot = $state } $testRoot
    $pipeName = & (Get-Module WtTools) { Get-WtToolsPipeName }
    $infoPath = Join-Path $testRoot 'host.json'
    if (-not $LegacyHostPath) { $LegacyHostPath = Join-Path $root 'artifacts/host/wttools-host.exe' }
    $start = [Diagnostics.ProcessStartInfo]::new($LegacyHostPath)
    $start.UseShellExecute = $false
    foreach ($argument in @($pipeName, $testRoot, (Join-Path $root 'powershell/WtTools.psm1'), (Join-Path $PSHOME 'pwsh.exe'))) { $start.ArgumentList.Add($argument) }
    $runningHost = [Diagnostics.Process]::Start($start)
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while (-not [IO.File]::Exists($infoPath)) {
        if ($runningHost.HasExited -or [DateTime]::UtcNow -ge $deadline) { throw 'Fixture host did not start.' }
        Start-Sleep -Milliseconds 30
    }
    # v0.1.x metadata has exactly these fields. The wire shutdown protocol is
    # unchanged; exercising it with a real host requires no old build/runtime.
    [IO.File]::WriteAllText($infoPath, (@{ pid=$runningHost.Id; pipeName=$pipeName } | ConvertTo-Json))
    $oldPid = $runningHost.Id
    Invoke-InvalidRequest
    Assert-True ($runningHost.WaitForExit(5000)) 'Legacy backend handoff uses graceful shutdown'
    $newInfo = Get-Content -LiteralPath $infoPath -Raw | ConvertFrom-Json
    Assert-True ($newInfo.backend -eq 'rust' -and $newInfo.pid -ne $oldPid) 'First new-shell request starts the Rust backend'
    $runningHost.Dispose()
    $runningHost = Get-Process -Id $newInfo.pid
    Invoke-InvalidRequest
    Assert-True ((Get-Content -LiteralPath $infoPath -Raw | ConvertFrom-Json).pid -eq $newInfo.pid) 'Subsequent requests preserve the running Rust host'
    Stop-WtTools -StateRoot $testRoot
    Assert-True ($runningHost.WaitForExit(5000)) 'Replacement backend stops cleanly'

    [IO.File]::WriteAllText($infoPath, (@{ pid=[int]::MaxValue; pipeName=$pipeName } | ConvertTo-Json))
    Invoke-InvalidRequest
    $newInfo = Get-Content -LiteralPath $infoPath -Raw | ConvertFrom-Json
    Assert-True ($newInfo.backend -eq 'rust') 'Stale legacy metadata does not prevent Rust startup'
    $runningHost.Dispose()
    $runningHost = Get-Process -Id $newInfo.pid
    Stop-WtTools -StateRoot $testRoot
    Assert-True ($runningHost.WaitForExit(5000)) 'Host started from stale metadata stops cleanly'
    Write-Output "PASS: $checks backend migration checks (no Terminal windows)."
} finally {
    if (Get-Module WtTools) { Stop-WtTools -StateRoot $testRoot; Remove-Module WtTools }
    if ($runningHost) {
        if (-not $runningHost.HasExited) { $runningHost.Kill(); $runningHost.WaitForExit() }
        $runningHost.Dispose()
    }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
