#Requires -Version 7.4
# Opens dedicated test terminal windows and closes only those windows.
[CmdletBinding()]
param([switch] $ExerciseKeyboard, [int] $MonitorIndex = -1)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class WtToolsWindowProbe {
    private delegate bool EnumProc(IntPtr window, IntPtr data);
    private delegate bool MonitorProc(IntPtr monitor, IntPtr dc, IntPtr rect, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonitorProc callback, IntPtr data);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr window);
    private struct MonitorInfo { public int Size; public Rect Monitor, Work; public uint Flags; }
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr data);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern int GetWindowText(IntPtr window, StringBuilder text, int size);
    public static string WindowTitle(IntPtr window) { var title = new StringBuilder(1024); GetWindowText(window, title, 1024); return title.ToString(); }
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint from, uint to, bool attach);
    [DllImport("user32.dll")] private static extern bool PeekMessage(out Message message, IntPtr window, uint min, uint max, uint remove);
    [DllImport("kernel32.dll")] private static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] private static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    public struct Rect { public int Left, Top, Right, Bottom; }
    public static Rect[] WorkAreas() {
        var result = new List<Rect>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (monitor, dc, rect, data) => {
            var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
            if (GetMonitorInfo(monitor, ref info)) result.Add(info.Work);
            return true;
        }, IntPtr.Zero);
        return result.ToArray();
    }
    private struct Message { public IntPtr Window; public uint Id; public IntPtr WParam, LParam; public uint Time; public int X, Y; public uint Private; }
    public static IntPtr[] Find(string fragment) {
        var result = new List<IntPtr>();
        EnumWindows((window, _) => {
            var title = new StringBuilder(1024);
            GetWindowText(window, title, 1024);
            if (title.ToString().Contains(fragment, StringComparison.Ordinal)) {
                GetWindowThreadProcessId(window, out uint pid);
                try {
                    using var process = System.Diagnostics.Process.GetProcessById((int)pid);
                    if (process.ProcessName.Equals("WindowsTerminal", StringComparison.OrdinalIgnoreCase)) result.Add(window);
                } catch (ArgumentException) { }
            }
            return true;
        }, IntPtr.Zero);
        return result.ToArray();
    }
    public static void AltF(IntPtr expected) {
        if (GetForegroundWindow() != expected) throw new InvalidOperationException("Test panel lost focus; refusing to send keys.");
        keybd_event(0x12, 0, 0, UIntPtr.Zero);
        keybd_event(0x46, 0, 0, UIntPtr.Zero);
        keybd_event(0x46, 0, 2, UIntPtr.Zero);
        keybd_event(0x12, 0, 2, UIntPtr.Zero);
    }
    public static void Focus(IntPtr window) {
        PeekMessage(out _, IntPtr.Zero, 0, 0, 0);
        ShowWindow(window, 9);
        uint current = GetCurrentThreadId();
        uint foreground = GetWindowThreadProcessId(GetForegroundWindow(), out _);
        bool attached = foreground != current && foreground != 0 && AttachThreadInput(current, foreground, true);
        try { SetForegroundWindow(window); }
        finally { if (attached) AttachThreadInput(current, foreground, false); }
    }
    public static string Describe(IntPtr window) {
        GetWindowThreadProcessId(window, out uint pid);
        GetWindowRect(window, out var rect);
        return $"hwnd={window}, pid={pid}, visible={IsWindowVisible(window)}, rect={rect.Left},{rect.Top},{rect.Right},{rect.Bottom}";
    }
}
'@
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('wttools-live-' + [guid]::NewGuid().ToString('N'))
[WtToolsWindowProbe]::SetThreadDpiAwarenessContext([IntPtr]::new(-4)) | Out-Null
$sourceTitle = 'wttools-test-source-' + [guid]::NewGuid().ToString('N')
$source = [IntPtr]::Zero; $panel = [IntPtr]::Zero; $hostProcess = $null
$secondPanel = [IntPtr]::Zero
$script:checks = 0
function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Wait-For([scriptblock] $Condition, [string] $Message) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt 15) {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "Timeout: $Message"
}
function Send-Request([hashtable] $Request) {
    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [IO.Pipes.PipeDirection]::InOut)
    try {
        $pipe.Connect(3000)
        $writer = [IO.StreamWriter]::new($pipe, [Text.UTF8Encoding]::new($false), 1024, $true)
        $writer.AutoFlush = $true
        $reader = [IO.StreamReader]::new($pipe)
        $writer.WriteLine(($Request | ConvertTo-Json -Compress))
        $pending = $reader.ReadLineAsync()
        if (-not $pending.Wait(15000)) { throw 'IPC response timeout' }
        $reply = $pending.Result | ConvertFrom-Json
        if (-not $reply.ok) { throw $reply.error }
    } finally { $pipe.Dispose() }
}
# PowerShell also treats the curly single quotes as string delimiters.
function Literal([string] $Value) { "'" + [regex]::Replace($Value, "['‘’‚‛]", '$0$0') + "'" }
try {
    $special = Join-Path $testRoot "中文 a'b’; calc; ‘b; [x] ``literal"
    [IO.Directory]::CreateDirectory($special) | Out-Null
    $module = Join-Path $root 'powershell/WtTools.psm1'
    Import-Module $module
    Enable-WtTools -StateRoot $testRoot
    $pipeName = & (Get-Module WtTools) { Get-WtToolsPipeName }
    $report = Join-Path $testRoot 'panel-location.json'
    $trigger = Join-Path $testRoot 'trigger'
    $fixture = Join-Path $testRoot 'Fixture.psm1'
    $fixtureCode = @'
Import-Module __MODULE__ -Global
$ExecutionContext.InvokeCommand.LocationChangedAction = {
    param($sender, $eventArgs)
    [IO.File]::WriteAllText(__REPORT__, (@{directory=$eventArgs.NewPath.ProviderPath; pid=$PID} | ConvertTo-Json -Compress))
    Start-Sleep -Seconds 8
}
'@.Replace('__MODULE__', (Literal $module)).Replace('__REPORT__', (Literal $report))
    [IO.File]::WriteAllText($fixture, $fixtureCode)
    $start = [Diagnostics.ProcessStartInfo]::new((Join-Path $root 'artifacts/host/wttools-host.exe'))
    $start.UseShellExecute = $false
    foreach ($argument in @($pipeName, $testRoot, $fixture, (Join-Path $PSHOME 'pwsh.exe'))) { $start.ArgumentList.Add($argument) }
    $hostProcess = [Diagnostics.Process]::Start($start)
    Wait-For { Test-Path -LiteralPath (Join-Path $testRoot 'host.json') } 'test host starts'

    $knownPanels = @([WtToolsWindowProbe]::Find('wttools Panel · '))
    $sourceCode = "Import-Module $(Literal $module); Enable-WtTools -StateRoot $(Literal $testRoot); " +
        "Set-Location -LiteralPath $(Literal $special); " +
        "while (-not (Test-Path -LiteralPath $(Literal $trigger))) { Start-Sleep -Milliseconds 100 }; " +
        '& (Get-Module WtTools) { param($window) Send-WtToolsRequest @{ action=''toggle''; directory=(Get-Location).ProviderPath; sourceWindow=$window } } ' +
        "([long](Get-Content -LiteralPath $(Literal $trigger)))"
    $start = [Diagnostics.ProcessStartInfo]::new('wt.exe')
    $start.UseShellExecute = $false
    foreach ($argument in @('-w', $sourceTitle, 'new-tab', '--title', $sourceTitle, '--suppressApplicationTitle',
        (Join-Path $PSHOME 'pwsh.exe'), '-NoLogo', '-NoProfile', '-NoExit', '-EncodedCommand',
        [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($sourceCode)))) { $start.ArgumentList.Add($argument) }
    $launcher = [Diagnostics.Process]::Start($start); $launcher.Dispose()
    Wait-For { [WtToolsWindowProbe]::Find($sourceTitle).Count -gt 0 } 'source terminal opens'
    $source = [WtToolsWindowProbe]::Find($sourceTitle)[0]
    $workAreas = [WtToolsWindowProbe]::WorkAreas()
    if ($MonitorIndex -ge 0) {
        if ($MonitorIndex -ge $workAreas.Count) { throw "Monitor index $MonitorIndex is unavailable" }
        $work = $workAreas[$MonitorIndex]
        [WtToolsWindowProbe]::SetWindowPos($source, [IntPtr]::Zero, $work.Left + 40, $work.Top + 40,
            [Math]::Min(1200, $work.Right - $work.Left - 80), [Math]::Min(800, $work.Bottom - $work.Top - 80), 0x0004) | Out-Null
        Start-Sleep -Milliseconds 800
    }
    $sourceBox = [WtToolsWindowProbe+Rect]::new()
    [WtToolsWindowProbe]::GetWindowRect($source, [ref] $sourceBox) | Out-Null
    [IO.File]::WriteAllText($trigger, $source.ToInt64().ToString())
    Wait-For { @([WtToolsWindowProbe]::Find('wttools Panel · ') | Where-Object { $_ -notin $knownPanels }).Count -gt 0 } 'panel HWND first appears'
    $firstPanelWindow = @([WtToolsWindowProbe]::Find('wttools Panel · ') | Where-Object { $_ -notin $knownPanels })[0]
    $firstMonitor = [WtToolsWindowProbe]::MonitorFromWindow($firstPanelWindow, 2)
    Wait-For { Test-Path -LiteralPath $report } 'panel reports its initial directory'
    $initial = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    Assert-True ($initial.directory -ceq $special) 'Panel inherits exact current source directory, including Unicode and punctuation'
    $newPanels = @([WtToolsWindowProbe]::Find('wttools Panel · ') | Where-Object { $_ -notin $knownPanels })
    Assert-True ($newPanels.Count -eq 1) 'Exactly one panel is created'
    $panel = $newPanels[0]
    $panelWindowName = [regex]::Match([WtToolsWindowProbe]::WindowTitle($panel), 'wttools Panel · [0-9a-f]{8}').Value
    Assert-True ([WtToolsWindowProbe]::IsWindowVisible($panel)) 'New panel is visible'
    Assert-True ($firstMonitor -eq [WtToolsWindowProbe]::MonitorFromWindow($source, 2)) 'First observed panel HWND is already on the source monitor'
    Write-Output "Monitor index=$MonitorIndex, source DPI=$([WtToolsWindowProbe]::GetDpiForWindow($source)), panel DPI=$([WtToolsWindowProbe]::GetDpiForWindow($panel))"
    $box = [WtToolsWindowProbe+Rect]::new()
    [WtToolsWindowProbe]::GetWindowRect($panel, [ref] $box) | Out-Null
    Assert-True (($box.Right - $box.Left) -ge 640 -and ($box.Bottom - $box.Top) -ge 360) 'Panel has a usable medium size'
    Start-Sleep -Milliseconds 1500
    $stableBox = [WtToolsWindowProbe+Rect]::new()
    [WtToolsWindowProbe]::GetWindowRect($panel, [ref] $stableBox) | Out-Null
    $expectedWidth = [Math]::Max(640, [int][Math]::Truncate(($sourceBox.Right - $sourceBox.Left) * 0.68))
    $expectedHeight = [Math]::Max(360, [int][Math]::Truncate(($sourceBox.Bottom - $sourceBox.Top) * 0.60))
    Assert-True ([Math]::Abs(($stableBox.Right - $stableBox.Left) - $expectedWidth) -le 4 -and [Math]::Abs(($stableBox.Bottom - $stableBox.Top) - $expectedHeight) -le 4) "First-launch dimensions use physical pixels without a second DPI multiplier: expected $expectedWidth x $expectedHeight, actual $($stableBox.Right - $stableBox.Left) x $($stableBox.Bottom - $stableBox.Top)"
    [WtToolsWindowProbe]::SetThreadDpiAwarenessContext([IntPtr]::new(-4)) | Out-Null
    [WtToolsWindowProbe]::SetWindowPos($panel, [IntPtr]::Zero, $stableBox.Left + 20, $stableBox.Top + 20, 700, 420, 0x0004) | Out-Null
    Start-Sleep -Milliseconds 200
    $expectedMoved = [WtToolsWindowProbe+Rect]::new()
    [WtToolsWindowProbe]::GetWindowRect($panel, [ref] $expectedMoved) | Out-Null

    # The fixture is still running a blocking command inside the panel. Alt+F
    # must be handled by the host, not by PSReadLine at an idle prompt.
    if ($ExerciseKeyboard) {
        [WtToolsWindowProbe]::Focus($panel)
        Wait-For { [WtToolsWindowProbe]::GetForegroundWindow() -eq $panel } 'panel receives focus'
        [WtToolsWindowProbe]::AltF($panel)
    } else {
        Send-Request @{ action = 'toggle'; directory = $special; sourceWindow = $panel.ToInt64() }
    }
    Wait-For { -not [WtToolsWindowProbe]::IsWindowVisible($panel) } 'host hides a busy panel'
    Assert-True ([bool](Get-Process -Id $initial.pid -ErrorAction SilentlyContinue)) 'Hidden panel shell remains alive'
    if ($ExerciseKeyboard) { Wait-For { [WtToolsWindowProbe]::GetForegroundWindow() -eq $source } 'focus returns to source terminal' }
    Send-Request @{ action = 'toggle'; directory = $special; sourceWindow = $source.ToInt64() }
    Wait-For { [WtToolsWindowProbe]::IsWindowVisible($panel) } 'existing panel reopens'
    Assert-True (@([WtToolsWindowProbe]::Find('wttools Panel · ') | Where-Object { $_ -notin $knownPanels }).Count -eq 1) 'Reopening does not create another shell'
    $movedBox = [WtToolsWindowProbe+Rect]::new()
    [WtToolsWindowProbe]::GetWindowRect($panel, [ref] $movedBox) | Out-Null
    Assert-True ($movedBox.Left -eq $expectedMoved.Left -and $movedBox.Top -eq $expectedMoved.Top -and [Math]::Abs(($movedBox.Right - $movedBox.Left) - ($expectedMoved.Right - $expectedMoved.Left)) -le 4) "User-moved position and size survive hide/show: expected $($expectedMoved | ConvertTo-Json -Compress), actual $($movedBox | ConvertTo-Json -Compress)"
    Send-Request @{ action = 'toggle'; directory = $special; sourceWindow = $source.ToInt64(); sessionId = 'second-shell-session' }
    $secondPanel = @([WtToolsWindowProbe]::Find('wttools Panel · ') | Where-Object { $_ -notin $knownPanels -and $_ -ne $panel })[0]
    Assert-True ($secondPanel -ne [IntPtr]::Zero -and [WtToolsWindowProbe]::IsWindowVisible($secondPanel)) 'Two shell sessions in the same WT window receive separate panels'
    Send-Request @{ action = 'toggle'; directory = $special; sourceWindow = $secondPanel.ToInt64() }
    Send-Request @{ action = 'toggle'; directory = $special; sourceWindow = $source.ToInt64(); sessionId = 'second-shell-session' }
    Assert-True ([WtToolsWindowProbe]::IsWindowVisible($panel) -and [WtToolsWindowProbe]::IsWindowVisible($secondPanel)) 'Each session reuses its own panel without hiding another session'
    # A new active tab changes the top-level title. Panel ownership must survive
    # that change and the maintenance timer, using the HWND property instead.
    $addedTabTitle = 'wttools-test-added-tab-' + [guid]::NewGuid().ToString('N')
    $tabDone = Join-Path $testRoot 'close-added-tab'
    $tabCode = "while (-not [IO.File]::Exists($(Literal $tabDone))) { Start-Sleep -Milliseconds 100 }"
    $tabStart = [Diagnostics.ProcessStartInfo]::new('wt.exe')
    $tabStart.UseShellExecute = $false
    foreach ($argument in @('-w', $panelWindowName, 'new-tab', '--title', $addedTabTitle, '--suppressApplicationTitle',
        (Join-Path $PSHOME 'pwsh.exe'), '-NoLogo', '-NoProfile', '-EncodedCommand',
        [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($tabCode)))) { $tabStart.ArgumentList.Add($argument) }
    $tabLauncher = [Diagnostics.Process]::Start($tabStart); $tabLauncher.Dispose()
    Wait-For { [WtToolsWindowProbe]::WindowTitle($panel).Contains($addedTabTitle) } 'added tab becomes active in the panel'
    Start-Sleep -Milliseconds 2200
    Send-Request @{ action = 'toggle'; directory = $special; sourceWindow = $panel.ToInt64() }
    Assert-True (-not [WtToolsWindowProbe]::IsWindowVisible($panel)) 'A changed active-tab title does not break hiding'
    Send-Request @{ action = 'toggle'; directory = $special; sourceWindow = $source.ToInt64() }
    Assert-True ([WtToolsWindowProbe]::IsWindowVisible($panel)) 'The owner reuses the same HWND after adding a tab'
    [IO.File]::WriteAllText($tabDone, 'done')
    Wait-For { -not [WtToolsWindowProbe]::WindowTitle($panel).Contains($addedTabTitle) } 'added test tab exits without a multi-tab close dialog'
    Send-Request @{ action = 'toggle'; directory = $special; sourceWindow = $panel.ToInt64() }
    [WtToolsWindowProbe]::PostMessage($source, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    Wait-For { -not [WtToolsWindowProbe]::IsWindow($source) } 'test source closes'
    Wait-For { [WtToolsWindowProbe]::IsWindowVisible($panel) } 'orphaned hidden panel is revealed'
    Assert-True ([WtToolsWindowProbe]::IsWindowVisible($panel)) 'Closing the owner never strands its hidden panel'
    Send-Request @{ action = 'shutdown' }
    Assert-True ($hostProcess.WaitForExit(5000)) 'Host shuts down while preserving the panel'
    Write-Output "PASS: $script:checks live Windows Terminal checks."
    if (-not $ExerciseKeyboard) { Write-Output 'Keyboard/focus assertions skipped; run -ExerciseKeyboard in an idle desktop to exercise them.' }
} finally {
    if ($tabDone) { [IO.File]::WriteAllText($tabDone, 'done'); Start-Sleep -Milliseconds 350 }
    foreach ($window in @($secondPanel, $panel, $source)) {
        if ($window -ne [IntPtr]::Zero -and [WtToolsWindowProbe]::IsWindow($window)) {
            [WtToolsWindowProbe]::PostMessage($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        }
    }
    if ($hostProcess -and -not $hostProcess.HasExited) { $hostProcess.Kill(); $hostProcess.WaitForExit() }
    Remove-Module WtTools -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
    }
}
