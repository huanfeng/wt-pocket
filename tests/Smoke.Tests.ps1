#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Add-Type -Path (Join-Path $root 'src/PanelHost.cs')
$script:checks = 0
function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}

# Fit on small displays, secondary displays with negative coordinates, and when
# the source window straddles displays. Never place any part outside the work area.
foreach ($sample in @(
    @(0, 0, 1920, 1080, 0, 0, 1920, 1040),
    @(-1920, 0, 0, 1080, -1920, 0, 0, 1040),
    @(0, 0, 400, 250, 0, 0, 400, 230),
    @(1500, -100, 3400, 1400, 1920, 0, 3840, 1080)
)) {
    $box = [WtTools.PanelGeometry]::Center.Invoke($sample)
    Assert-True ($box[0] -ge $sample[4] -and $box[1] -ge $sample[5]) 'Panel starts within work area'
    Assert-True ($box[0] + $box[2] -le $sample[6] -and $box[1] + $box[3] -le $sample[7]) 'Panel ends within work area'
    Assert-True ($box[2] -gt 0 -and $box[3] -gt 0) 'Panel has positive dimensions'
}

$hostilePath = 'D:\中文 path\a''b; $(throw "injection") [x] `literal'
$modulePath = Join-Path $root 'powershell/WtTools.psm1'
$bootstrap = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String(
    [WtTools.PanelHost]::Bootstrap($hostilePath, $modulePath)))
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($bootstrap, [ref]$tokens, [ref]$parseErrors)
Assert-True ($parseErrors.Count -eq 0) 'Bootstrap is valid PowerShell'
$location = $ast.FindAll({ param($node)
    $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Set-Location'
}, $true)[0]
Assert-True ($location.CommandElements[-1].Value -ceq $hostilePath) 'Special characters remain a literal path'
Assert-True ($location.CommandElements[-2].ParameterName -eq 'LiteralPath') 'Path uses LiteralPath'

# The host starts without WT, rejects an invalid request, survives it, then shuts
# down cleanly. This test never creates or closes user terminal windows.
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('wttools-tests-' + [guid]::NewGuid().ToString('N'))
$pipeName = 'wttools-tests-' + [guid]::NewGuid().ToString('N')
$hostProcess = $null
function Send-TestRequest([hashtable] $Request) {
    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [IO.Pipes.PipeDirection]::InOut)
    try {
        $pipe.Connect(3000)
        $reader = [IO.StreamReader]::new($pipe)
        $writer = [IO.StreamWriter]::new($pipe, [Text.UTF8Encoding]::new($false), 1024, $true)
        $writer.AutoFlush = $true
        $writer.WriteLine(($Request | ConvertTo-Json -Compress))
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
    $startupMs = $timer.ElapsedMilliseconds
    $response = Send-TestRequest @{ action = 'toggle'; directory = $testRoot; sourceWindow = 0 }
    Assert-True (-not $response.ok -and $response.error -match 'Windows Terminal') 'Host rejects invalid source HWND'
    $response = Send-TestRequest @{ action = 'unknown' }
    Assert-True (-not $response.ok) 'Host rejects unsupported actions and keeps serving'
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
