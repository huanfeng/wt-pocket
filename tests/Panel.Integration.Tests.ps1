#Requires -Version 7.4
# Opens dedicated test terminal windows and closes only those windows.
# The source terminal runs the shipped Startup.ps1 Alt+F handler against
# artifacts/host/wtpocket.exe with an isolated state directory.
#   -ExerciseKeyboard       focus the panel and press real Alt+F (needs an idle desktop)
#   -MonitorIndex N         place the source terminal on monitor N first
#   -VerifyTitleBarRestore  opt-in: temporarily adds WTPocket's key binding to the real
#                           Windows Terminal settings.json (always restored from a backup,
#                           hash verified) and checks an orphaned panel regains its tab row.
[CmdletBinding()]
param([switch] $ExerciseKeyboard, [int] $MonitorIndex = -1, [switch] $VerifyTitleBarRestore)
$ErrorActionPreference = 'Stop'
# Messages are asserted in English regardless of the machine's display language.
$env:WTPOCKET_LANG = 'en'
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
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('wtpocket-live-' + [guid]::NewGuid().ToString('N'))
[WtToolsWindowProbe]::SetThreadDpiAwarenessContext([IntPtr]::new(-4)) | Out-Null
$sourceTitle = 'wttools-test-source-' + [guid]::NewGuid().ToString('N')
$source = [IntPtr]::Zero; $panel = [IntPtr]::Zero
$secondPanel = [IntPtr]::Zero
$hostPid = 0
$tabDone = $null
$settingsFile = $null; $settingsBackup = $null; $settingsHash = $null; $settingsSiblings = @()
$script:checks = 0
function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
}
function Wait-For([scriptblock] $Condition, [string] $Message, [int] $Seconds = 15) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $Seconds) {
        if (& $Condition) { return }
        Start-Sleep -Milliseconds 100
    }
    throw "Timeout: $Message"
}
function Send-Request([hashtable] $Request) {
    $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', $script:pipeName, [IO.Pipes.PipeDirection]::InOut)
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
# Windows Terminal's settings.json, in the same order wtpocket detects them.
function Find-TerminalSettings {
    $local = $env:LOCALAPPDATA
    @(
        (Join-Path $local 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $local 'Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json'),
        (Join-Path $local 'Microsoft\Windows Terminal\settings.json')
    ) | Where-Object { [IO.File]::Exists($_) } | Select-Object -First 1
}
function Get-TabItemCount([IntPtr] $Window) {
    try {
        $element = [Windows.Automation.AutomationElement]::FromHandle($Window)
        $condition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty, [Windows.Automation.ControlType]::TabItem)
        return $element.FindAll([Windows.Automation.TreeScope]::Descendants, $condition).Count
    } catch { return -1 }
}
# Brings a test window to the foreground; returns whether Windows allowed it.
function Request-Foreground([IntPtr] $Window, [int] $Seconds = 5) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.Elapsed.TotalSeconds -lt $Seconds) {
        [WtToolsWindowProbe]::Focus($Window)
        Start-Sleep -Milliseconds 150
        if ([WtToolsWindowProbe]::GetForegroundWindow() -eq $Window) { return $true }
    }
    return $false
}
try {
    $exe = Join-Path $root 'artifacts/host/wtpocket.exe'
    $startup = Join-Path $root 'artifacts/host/Startup.ps1'
    foreach ($required in @($exe, $startup)) {
        if (-not [IO.File]::Exists($required)) { throw "Missing $required. Run scripts/Build.ps1 first." }
    }
    if ($VerifyTitleBarRestore) { Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes }
    $special = Join-Path $testRoot "中文 a'b’; calc; ‘b; [x] ``literal"
    [IO.Directory]::CreateDirectory($special) | Out-Null
    $report = Join-Path $testRoot 'panel-location.json'
    $trigger = Join-Path $testRoot 'trigger'
    $openResult = Join-Path $testRoot 'open-result.txt'
    $fixture = Join-Path $testRoot 'Fixture.ps1'
    $wrapper = Join-Path $testRoot 'PanelShell.cmd'
    $pwshPath = Join-Path $PSHOME 'pwsh.exe'

    # The host starts panels as `<shell> -NoLogo -NoProfile -NoExit -EncodedCommand <bootstrap>`.
    # The wrapper stands in for pwsh.exe: it runs the real bootstrap, but first installs a
    # location handler that reports the panel's directory and keeps the shell busy.
    $fixtureCode = @'
$ExecutionContext.InvokeCommand.LocationChangedAction = {
    param($sender, $eventArgs)
    [IO.File]::WriteAllText(__REPORT__, (@{directory=$eventArgs.NewPath.ProviderPath; pid=$PID} | ConvertTo-Json -Compress))
    Start-Sleep -Seconds 8
}
$encoded = [regex]::Match($env:WTPOCKET_TEST_ARGS, '-EncodedCommand\s+(\S+)').Groups[1].Value
Invoke-Expression ([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded)))
'@.Replace('__REPORT__', (Literal $report))
    [IO.File]::WriteAllText($fixture, $fixtureCode, [Text.UTF8Encoding]::new($true))
    [IO.File]::WriteAllText($wrapper, "@echo off`r`nset `"WTPOCKET_TEST_ARGS=%*`"`r`n`"$pwshPath`" -NoLogo -NoProfile -NoExit -Command `". '$fixture'`"`r`n")

    if ($VerifyTitleBarRestore) {
        $settingsFile = Find-TerminalSettings
        if (-not $settingsFile) { Write-Output 'SKIPPED: -VerifyTitleBarRestore found no Windows Terminal settings.json.'; return }
        $settingsHash = (Get-FileHash -LiteralPath $settingsFile -Algorithm SHA256).Hash
        $settingsBackup = Join-Path $testRoot 'settings.json.backup'
        [IO.Directory]::CreateDirectory($testRoot) | Out-Null
        Copy-Item -LiteralPath $settingsFile -Destination $settingsBackup
        Assert-True ((Get-FileHash -LiteralPath $settingsBackup -Algorithm SHA256).Hash -eq $settingsHash) 'Settings backup is byte-identical'
        $settingsSiblings = @(Get-ChildItem -LiteralPath (Split-Path $settingsFile) | ForEach-Object Name)
        # Only the key binding is added: the profile and install destination are isolated temp files.
        $installOutput = & $exe install --state $testRoot --destination (Join-Path $testRoot 'app') `
            --profile (Join-Path $testRoot 'profile.ps1') --terminal-settings $settingsFile 2>&1
        if ($LASTEXITCODE -ne 0) { throw "wtpocket install failed: $(($installOutput | Out-String).Trim())" }
        Assert-True ((Get-Content -LiteralPath $settingsFile -Raw).Contains('User.WTPocket.ExitFocus')) 'Installer added the focus-mode exit key binding'
    }

    $knownPanels = @([WtToolsWindowProbe]::Find('wttools Panel · '))
    # A fixed session id (the handler only generates one when none is set) lets the
    # later pipe requests address the same panel the handler created.
    $liveSession = 'live-test-' + [guid]::NewGuid().ToString('N')
    # Exactly what the Alt+F handler in Startup.ps1 does, run from a real terminal.
    $sourceCode = "`$global:ErrorView = 'ConciseView'; " +
        ". $(Literal $startup) -StateRoot $(Literal $testRoot); " +
        "`$global:WtPocketState.Pwsh = $(Literal $wrapper); `$global:WtPocketState.SessionId = $(Literal $liveSession); " +
        "`$ast = [Management.Automation.Language.Parser]::ParseFile($(Literal $startup), [ref] `$null, [ref] `$null); " +
        "`$call = `$ast.Find({ param(`$n) `$n -is [Management.Automation.Language.CommandAst] -and `$n.GetCommandName() -eq 'Set-PSReadLineKeyHandler' }, `$true); " +
        "`$handler = `$call.CommandElements[`$call.CommandElements.Count - 1].ScriptBlock.GetScriptBlock(); " +
        "Set-Location -LiteralPath $(Literal $special); " +
        "while (-not (Test-Path -LiteralPath $(Literal $trigger))) { Start-Sleep -Milliseconds 100 }; " +
        "`$records = @(& `$handler 3>&1 2>&1); " +
        "[IO.File]::WriteAllText($(Literal $openResult), ((`$records | Out-String) + 'handler-finished'))"
    $start = [Diagnostics.ProcessStartInfo]::new('wt.exe')
    $start.UseShellExecute = $false
    foreach ($argument in @('-w', $sourceTitle, 'new-tab', '--title', $sourceTitle, '--suppressApplicationTitle',
        $pwshPath, '-NoLogo', '-NoProfile', '-NoExit', '-EncodedCommand',
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
    # `wtpocket open` reads the focused window itself, so the source must be foreground.
    if (-not (Request-Foreground $source)) {
        Write-Output 'SKIPPED: Windows denied foreground activation of the test terminal (run on an interactive desktop); no panel assertions were made.'
        return
    }
    $sourceBox = [WtToolsWindowProbe+Rect]::new()
    [WtToolsWindowProbe]::GetWindowRect($source, [ref] $sourceBox) | Out-Null
    [IO.File]::WriteAllText($trigger, 'go')
    try {
        Wait-For { @([WtToolsWindowProbe]::Find('wttools Panel · ') | Where-Object { $_ -notin $knownPanels }).Count -gt 0 } 'panel HWND first appears'
    } catch {
        $detail = if ([IO.File]::Exists($openResult)) { [IO.File]::ReadAllText($openResult) } else { '(handler has not returned yet or produced no result)' }
        throw "$($_.Exception.Message). Alt+F handler output: $detail"
    }
    $firstPanelWindow = @([WtToolsWindowProbe]::Find('wttools Panel · ') | Where-Object { $_ -notin $knownPanels })[0]
    $firstMonitor = [WtToolsWindowProbe]::MonitorFromWindow($firstPanelWindow, 2)
    Wait-For { Test-Path -LiteralPath $report } 'panel reports its initial directory'
    $initial = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    Assert-True ($initial.directory -ceq $special) 'Panel inherits exact current source directory, including Unicode and punctuation'
    $newPanels = @([WtToolsWindowProbe]::Find('wttools Panel · ') | Where-Object { $_ -notin $knownPanels })
    Assert-True ($newPanels.Count -eq 1) 'Exactly one panel is created'
    $panel = $newPanels[0]
    # The host is started by `open`; its identity is published in host.json.
    $hostInfo = Get-Content -LiteralPath (Join-Path $testRoot 'host.json') -Raw | ConvertFrom-Json
    $hostPid = [int] $hostInfo.pid
    $script:pipeName = $hostInfo.pipeName
    Assert-True ($hostInfo.backend -eq 'rust' -and $hostPid -gt 0 -and $script:pipeName) 'open starts the Rust host and publishes host.json'
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

    # A live panel is in focus mode (no tab row). This is what makes the later
    # TabItem check meaningful; if UI Automation cannot tell, that check is skipped.
    $titleBarCheckable = $false
    if ($VerifyTitleBarRestore) {
        $focusModeTabs = Get-TabItemCount $panel
        $titleBarCheckable = $focusModeTabs -eq 0
        if (-not $titleBarCheckable) { Write-Output "NOTE: UI Automation reported $focusModeTabs TabItem controls in the focus-mode panel; the title-bar check will be SKIPPED." }
    }

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
    Send-Request @{ action = 'toggle'; directory = $special; sourceWindow = $source.ToInt64(); sessionId = $liveSession }
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
        $pwshPath, '-NoLogo', '-NoProfile', '-EncodedCommand',
        [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($tabCode)))) { $tabStart.ArgumentList.Add($argument) }
    $tabLauncher = [Diagnostics.Process]::Start($tabStart); $tabLauncher.Dispose()
    Wait-For { [WtToolsWindowProbe]::WindowTitle($panel).Contains($addedTabTitle) } 'added tab becomes active in the panel'
    Start-Sleep -Milliseconds 2200
    Send-Request @{ action = 'toggle'; directory = $special; sourceWindow = $panel.ToInt64() }
    Assert-True (-not [WtToolsWindowProbe]::IsWindowVisible($panel)) 'A changed active-tab title does not break hiding'
    Send-Request @{ action = 'toggle'; directory = $special; sourceWindow = $source.ToInt64(); sessionId = $liveSession }
    Assert-True ([WtToolsWindowProbe]::IsWindowVisible($panel)) 'The owner reuses the same HWND after adding a tab'
    [IO.File]::WriteAllText($tabDone, 'done')
    Wait-For { -not [WtToolsWindowProbe]::WindowTitle($panel).Contains($addedTabTitle) } 'added test tab exits without a multi-tab close dialog'
    Send-Request @{ action = 'toggle'; directory = $special; sourceWindow = $panel.ToInt64() }
    [WtToolsWindowProbe]::PostMessage($source, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    Wait-For { -not [WtToolsWindowProbe]::IsWindow($source) } 'test source closes'
    Wait-For { [WtToolsWindowProbe]::IsWindowVisible($panel) } 'orphaned hidden panel is revealed'
    Assert-True ([WtToolsWindowProbe]::IsWindowVisible($panel)) 'Closing the owner never strands its hidden panel'

    if ($VerifyTitleBarRestore) {
        # The host focuses the orphan and sends ctrl+shift+alt+F24 (setFocusMode:false).
        $sawForeground = $false; $tabs = 0
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while ($timer.Elapsed.TotalSeconds -lt 12 -and $tabs -le 0) {
            if ([WtToolsWindowProbe]::GetForegroundWindow() -eq $panel) { $sawForeground = $true }
            $tabs = Get-TabItemCount $panel
            Start-Sleep -Milliseconds 250
        }
        if (-not $titleBarCheckable) {
            Write-Output 'SKIPPED: title-bar restore (UI Automation cannot distinguish focus mode in this environment).'
        } elseif ($tabs -le 0 -and -not $sawForeground) {
            Write-Output 'SKIPPED: title-bar restore (Windows did not let the host focus the orphaned panel, so the key chord could not be sent).'
        } else {
            Assert-True ($tabs -gt 0) "An orphaned panel regains its tab row (setFocusMode:false) after its source terminal closes (TabItem count $tabs, panel was foreground: $sawForeground, visible: $([WtToolsWindowProbe]::IsWindowVisible($panel)))"
        }
    }

    & $exe stop --state $testRoot | Out-Null
    Assert-True ($LASTEXITCODE -eq 0) 'wtpocket stop succeeds'
    Wait-For { -not (Get-Process -Id $hostPid -ErrorAction SilentlyContinue) } 'host exits after stop' 5
    Assert-True ([WtToolsWindowProbe]::IsWindow($panel)) 'Stopping the host preserves the panel'
    Write-Output "PASS: $script:checks live Windows Terminal checks."
    if (-not $ExerciseKeyboard) { Write-Output 'Keyboard/focus assertions skipped; run -ExerciseKeyboard in an idle desktop to exercise them.' }
} finally {
    if ($tabDone) { [IO.File]::WriteAllText($tabDone, 'done'); Start-Sleep -Milliseconds 350 }
    foreach ($window in @($secondPanel, $panel, $source)) {
        if ($window -ne [IntPtr]::Zero -and [WtToolsWindowProbe]::IsWindow($window)) {
            [WtToolsWindowProbe]::PostMessage($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        }
    }
    # Only the host this test created (its pid comes from the isolated state directory).
    if ($hostPid -eq 0 -and [IO.File]::Exists((Join-Path $testRoot 'host.json'))) {
        try { $hostPid = [int] (Get-Content -LiteralPath (Join-Path $testRoot 'host.json') -Raw | ConvertFrom-Json).pid } catch { }
    }
    if ($hostPid -gt 0) { Stop-Process -Id $hostPid -Force -ErrorAction SilentlyContinue }
    # Always put the user's Windows Terminal settings back, byte for byte.
    $restoreError = $null
    if ($settingsBackup) {
        try {
            if ((Get-FileHash -LiteralPath $settingsFile -Algorithm SHA256).Hash -ne $settingsHash) {
                Copy-Item -LiteralPath $settingsBackup -Destination $settingsFile -Force
            }
            if ((Get-FileHash -LiteralPath $settingsFile -Algorithm SHA256).Hash -ne $settingsHash) {
                $restoreError = "settings.json hash differs from the backup after restore: $settingsFile (backup kept at $settingsBackup)"
            } else {
                # Remove only the .bak files the installer created during this run.
                Get-ChildItem -LiteralPath (Split-Path $settingsFile) -Filter 'settings.json.wtpocket-*.bak' |
                    Where-Object { $_.Name -notin $settingsSiblings } | Remove-Item -Force -ErrorAction SilentlyContinue
            }
        } catch { $restoreError = "could not restore settings.json: $_ (backup at $settingsBackup)" }
    }
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $prefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and -not $restoreError) {
        # Closing terminals is asynchronous; their shells hold the directory until they exit.
        for ($attempt = 0; $attempt -lt 25 -and [IO.Directory]::Exists($resolved); $attempt++) {
            Start-Sleep -Milliseconds 200
            Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if ($restoreError) { Write-Error "FAIL: $restoreError" }
    elseif ($settingsBackup) { Write-Output 'Windows Terminal settings.json restored; hash matches the backup.' }
}
