#Requires -Version 7.4
# Drives the real `wtpocket restore` picker in a private, windowless console:
# keys are injected into its input buffer and the screen buffer is read back, so
# no desktop, focus or Windows Terminal window is involved.
$ErrorActionPreference = 'Stop'
$env:WTPOCKET_LANG = 'en'
$root = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $root 'artifacts/host/wtpocket.exe'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('wtpocket-console-' + [guid]::NewGuid().ToString('N'))
$utf8 = [Text.UTF8Encoding]::new($false)
$script:checks = 0
function Assert-True($Condition, [string] $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}

# Runs inside a separate pwsh: it must detach from this console to attach to the picker's.
$injector = @'
param([int] $TargetPid, [string] $KeysFile, [string] $OutFile)
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class Con {
    [StructLayout(LayoutKind.Explicit, Size = 20)]
    public struct InputRecord {
        [FieldOffset(0)] public ushort EventType;
        [FieldOffset(4)] public int KeyDown;
        [FieldOffset(8)] public ushort RepeatCount;
        [FieldOffset(10)] public ushort VirtualKey;
        [FieldOffset(12)] public ushort ScanCode;
        [FieldOffset(14)] public ushort Char;
        [FieldOffset(16)] public uint ControlState;
    }
    [DllImport("kernel32.dll")] public static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] public static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool WriteConsoleInputW(IntPtr h, InputRecord[] records, uint count, out uint written);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool ReadConsoleOutputCharacterW(IntPtr h, StringBuilder text, uint length, uint coord, out uint read);
}
"@
$screens = [System.Collections.Generic.List[string]]::new()
function Read-Screen($out) {
    $lines = for ($y = 0; $y -lt 14; $y++) {
        $sb = [Text.StringBuilder]::new(200)
        $read = 0
        [void] [Con]::ReadConsoleOutputCharacterW($out, $sb, 120, [uint32]($y -shl 16), [ref] $read)
        $sb.ToString().TrimEnd()
    }
    ($lines -join "`n").TrimEnd()
}
function Send-Key($in, [uint16] $Vk, [uint16] $Char = 0) {
    foreach ($down in 1, 0) {
        $record = New-Object Con+InputRecord
        $record.EventType = 1; $record.KeyDown = $down; $record.RepeatCount = 1; $record.VirtualKey = $Vk; $record.Char = $Char
        $written = 0
        [void] [Con]::WriteConsoleInputW($in, @($record), 1, [ref] $written)
    }
}
try {
    [void] [Con]::FreeConsole()
    if (-not [Con]::AttachConsole($TargetPid)) { throw "AttachConsole failed: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
    $in = [Con]::CreateFileW('CONIN$', [uint32]3221225472, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    $out = [Con]::CreateFileW('CONOUT$', [uint32]3221225472, 3, [IntPtr]::Zero, 3, 0, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 800
    $codes = @{ Up = 0x26; Down = 0x28; Space = 0x20; Enter = 0x0D; Esc = 0x1B; Home = 0x24; End = 0x23 }
    foreach ($step in (Get-Content -LiteralPath $KeysFile)) {
        if ($step -eq 'SCREEN') { $screens.Add((Read-Screen $out)); continue }
        if ($step.Length -eq 1) { Send-Key $in ([uint16][char]::ToUpper($step[0])) ([uint16]$step[0]) } else { Send-Key $in $codes[$step] }
        Start-Sleep -Milliseconds 200
    }
    [IO.File]::WriteAllText($OutFile, ($screens | ConvertTo-Json -AsArray -Compress), [Text.UTF8Encoding]::new($false))
} catch {
    [IO.File]::WriteAllText($OutFile, ('ERROR: ' + $_), [Text.UTF8Encoding]::new($false))
}
'@

# Starts the picker, plays the key steps, and returns what the console showed plus the exit state.
function Invoke-Picker([string[]] $Steps, [string] $State, [string] $WtExe) {
    $id = [guid]::NewGuid().ToString('N')
    $keysFile = Join-Path $temp "keys-$id.txt"; $outFile = Join-Path $temp "screens-$id.json"
    [IO.File]::WriteAllLines($keysFile, $Steps, $utf8)
    $info = [Diagnostics.ProcessStartInfo]::new($exe)
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true     # a console without a window, never handed to Windows Terminal
    foreach ($argument in @('restore', '--state', $State, '--wt-exe', $WtExe)) { $info.ArgumentList.Add($argument) }
    $picker = [Diagnostics.Process]::Start($info)
    try {
        $helper = Start-Process pwsh -ArgumentList @('-NoLogo', '-NoProfile', '-File', $script:injectorFile, $picker.Id, $keysFile, $outFile) -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $temp "h-$id.out") -RedirectStandardError (Join-Path $temp "h-$id.err")
        if (-not $helper.WaitForExit(60000)) { $helper.Kill(); throw 'The key injector hung.' }
        $exited = $picker.WaitForExit(15000)
        if (-not $exited) { $picker.Kill() }
        $raw = if ([IO.File]::Exists($outFile)) { [IO.File]::ReadAllText($outFile) } else { 'ERROR: no injector output' }
        if ($raw.StartsWith('ERROR')) { throw $raw }
        [pscustomobject]@{ Screens = @(ConvertFrom-Json $raw); Exited = $exited; ExitCode = if ($exited) { $picker.ExitCode } else { -1 } }
    } finally { if (-not $picker.HasExited) { $picker.Kill() } }
}

try {
    [IO.Directory]::CreateDirectory($temp) | Out-Null
    if (-not [IO.File]::Exists($exe)) { throw "Missing $exe. Run scripts/Build.ps1 first." }
    $script:injectorFile = Join-Path $temp 'inject.ps1'
    [IO.File]::WriteAllText($script:injectorFile, $injector, [Text.UTF8Encoding]::new($true))
    $state = Join-Path $temp 'state'
    $sessions = Join-Path $state 'sessions'
    [IO.Directory]::CreateDirectory($sessions) | Out-Null
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $names = 'alpha', 'bravo', 'charlie', 'delta'
    for ($i = 0; $i -lt $names.Count; $i++) {
        $dir = Join-Path $temp $names[$i]
        [IO.Directory]::CreateDirectory($dir) | Out-Null
        $json = [ordered]@{ path = $dir; profile = ''; pid = 0; started = 1; updated = $now - 60 * ($i + 1) } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText((Join-Path $sessions "$i.json"), $json, $utf8)
    }
    $record = Join-Path $temp 'wt-args.txt'
    $fakeWt = Join-Path $temp 'fake-wt.cmd'
    [IO.File]::WriteAllText($fakeWt, "@echo off`r`necho %*> `"$record`"`r`n")

    # Move, select with Space, confirm with Enter: alpha is first (most recent), so Down+Space ticks bravo, then End+Space ticks delta.
    $run = Invoke-Picker @('SCREEN', 'Down', 'Space', 'SCREEN', 'End', 'Space', 'SCREEN', 'Enter') $state $fakeWt
    $first = $run.Screens[0]; $second = $run.Screens[1]; $third = $run.Screens[2]
    Assert-True ($first -match 'Select sessions to reopen' -and $first -match '> \[ \] .*alpha' -and $first -match 'bravo' -and $first -match 'delta') "The picker lists the sessions with the cursor on the first row`n$first"
    if ($env:WTPOCKET_TEST_VERBOSE) { Write-Output $third }
    Assert-True ($second -match '(?m)^  \[ \] .*alpha' -and $second -match '(?m)^> \[x\] .*bravo') "Down moves the cursor and Space ticks the row`n$second"
    Assert-True ($third -match '(?m)^> \[x\] .*delta' -and $third -match '(?m)^  \[x\] .*bravo' -and $third -match 'selected: 2') "End jumps to the last row; several rows can be ticked`n$third"
    Assert-True ($run.Exited -and $run.ExitCode -eq 0) 'Enter confirms and the command exits successfully'
    $args1 = if ([IO.File]::Exists($record)) { [IO.File]::ReadAllText($record).Trim() } else { '' }
    Assert-True ($args1.Contains('bravo') -and $args1.Contains('delta') -and -not $args1.Contains('alpha') -and $args1.Contains(';')) "Both ticked sessions are reopened in one wt command ($args1)"

    # Esc cancels without launching anything.
    Remove-Item -LiteralPath $record -ErrorAction SilentlyContinue
    $run = Invoke-Picker @('SCREEN', 'Space', 'Esc') $state $fakeWt
    Assert-True ($run.Exited -and $run.ExitCode -eq 0 -and -not [IO.File]::Exists($record)) 'Esc cancels without opening anything'

    # Enter with nothing ticked takes the highlighted row; Up wraps around from the top.
    $run = Invoke-Picker @('Up', 'Enter') $state $fakeWt
    $args2 = if ([IO.File]::Exists($record)) { [IO.File]::ReadAllText($record).Trim() } else { '' }
    Assert-True ($run.Exited -and $args2.Contains('delta') -and -not $args2.Contains('alpha') -and -not $args2.Contains(';')) "Up wraps to the last row and Enter opens just that row ($args2)"

    Write-Output "PASS: $script:checks restore console checks (private console, injected keys)."
} finally {
    if ([IO.Path]::GetFullPath($temp).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
