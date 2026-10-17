#Requires -Version 7.4
# Real disposable windows on each monitor; no cursor movement or key injection.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Add-Type -Path (Join-Path $root 'src/PanelHost.cs')
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class DragDpiProbe {
    public struct Rect { public int Left, Top, Right, Bottom; }
    public struct Point { public int X, Y; }
    private struct MonitorInfo { public int Size; public Rect Monitor, Work; public uint Flags; }
    private delegate bool MonitorProc(IntPtr monitor, IntPtr dc, IntPtr rect, IntPtr data);
    [DllImport("user32.dll")] private static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonitorProc callback, IntPtr data);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr CreateWindowEx(uint ex, string cls, string title, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
    [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr window);
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] public static extern IntPtr GetThreadDpiAwarenessContext();
    [DllImport("user32.dll")] public static extern bool AreDpiAwarenessContextsEqual(IntPtr a, IntPtr b);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int w, int h, uint flags);
    [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr window);
    public static Rect[] WorkAreas() {
        var result = new List<Rect>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (monitor, dc, rect, data) => {
            var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
            if (GetMonitorInfo(monitor, ref info)) result.Add(info.Work);
            return true;
        }, IntPtr.Zero);
        return result.ToArray();
    }
}
'@
$hostType = [WtTools.PanelHost]
$flags = [Reflection.BindingFlags]'NonPublic,Static'
$panelType = $hostType.GetNestedType('Panel', [Reflection.BindingFlags]::NonPublic)
$dragField = $hostType.GetField('dragPanel', $flags)
$callback = $hostType.GetMethod('Mouse', $flags)
$boundsField = $hostType.GetField('dragBounds', $flags)
$originField = $hostType.GetField('dragOrigin', $flags)
$initialContext = [DragDpiProbe]::SetThreadDpiAwarenessContext([IntPtr]::new(-4))
$buffer = [Runtime.InteropServices.Marshal]::AllocHGlobal(32)
$checks = 0
try {
    foreach ($work in [DragDpiProbe]::WorkAreas()) {
        $window = [DragDpiProbe]::CreateWindowEx(0x08000080, 'BUTTON', 'wttools disposable DPI test', 0x80000000u,
            $work.Left + 120, $work.Top + 120, 240, 180, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
        if ($window -eq [IntPtr]::Zero) { throw 'Could not create DPI fixture' }
        try {
            $box = [DragDpiProbe+Rect]::new()
            [DragDpiProbe]::GetWindowRect($window, [ref]$box) | Out-Null
            $point = [DragDpiProbe+Point]::new()
            $point.X = $box.Left + 100; $point.Y = $box.Top + 100
            $panel = [Activator]::CreateInstance($panelType, $true)
            $panelType.GetField('Window').SetValue($panel, $window)
            $bounds = [Activator]::CreateInstance($boundsField.FieldType)
            foreach ($name in @('Left', 'Top', 'Right', 'Bottom')) { $bounds.$name = $box.$name }
            $boundsField.SetValue($null, $bounds)
            $origin = [Activator]::CreateInstance($originField.FieldType)
            $origin.X = $point.X; $origin.Y = $point.Y
            $originField.SetValue($null, $origin)
            for ($offset = 0; $offset -lt 32; $offset += 4) { [Runtime.InteropServices.Marshal]::WriteInt32($buffer, $offset, 0) }
            [Runtime.InteropServices.Marshal]::WriteInt32($buffer, 0, $point.X + 35)
            [Runtime.InteropServices.Marshal]::WriteInt32($buffer, 4, $point.Y + 25)
            # Windows callbacks may enter with a different DPI context from Run().
            foreach ($context in @(-1, -2, -4)) {
                [DragDpiProbe]::SetThreadDpiAwarenessContext([IntPtr]::new(-4)) | Out-Null
                [DragDpiProbe]::SetWindowPos($window, [IntPtr]::Zero, $box.Left, $box.Top, 0, 0, 0x0015) | Out-Null
                $dragField.SetValue($null, $panel)
                [DragDpiProbe]::SetThreadDpiAwarenessContext([IntPtr]::new($context)) | Out-Null
                $before = [DragDpiProbe]::GetThreadDpiAwarenessContext()
                $null = $callback.Invoke($null, @([int]0, [IntPtr]::new(0x0200), $buffer))
                $restored = [DragDpiProbe]::AreDpiAwarenessContextsEqual($before, [DragDpiProbe]::GetThreadDpiAwarenessContext())
                [DragDpiProbe]::SetThreadDpiAwarenessContext([IntPtr]::new(-4)) | Out-Null
                $actual = [DragDpiProbe+Rect]::new()
                [DragDpiProbe]::GetWindowRect($window, [ref]$actual) | Out-Null
                if ($actual.Left -ne $box.Left + 35 -or $actual.Top -ne $box.Top + 25) {
                    throw "DPI=$([DragDpiProbe]::GetDpiForWindow($window)), caller=$context : expected $($box.Left+35),$($box.Top+25); actual $($actual.Left),$($actual.Top)"
                }
                if (-not $restored) { throw 'Hook leaked its DPI awareness context' }
                $checks += 2
            }
            Write-Output "PASS: monitor at $($work.Left),$($work.Top), DPI=$([DragDpiProbe]::GetDpiForWindow($window)); physical drag offsets under 3 caller DPI contexts."
        } finally {
            [DragDpiProbe]::SetThreadDpiAwarenessContext([IntPtr]::new(-4)) | Out-Null
            $dragField.SetValue($null, $null)
            [DragDpiProbe]::DestroyWindow($window) | Out-Null
        }
    }
    Write-Output "PASS: $checks monitor DPI checks; no input injected."
} finally {
    [DragDpiProbe]::SetThreadDpiAwarenessContext($initialContext) | Out-Null
    [Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)
}
