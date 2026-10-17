using System;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace WtTools;

[SupportedOSPlatform("windows")]
public static class ShellNative
{
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool AllowSetForegroundWindow(uint processId);
}
