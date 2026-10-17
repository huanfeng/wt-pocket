using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace WtTools
{
    public sealed class PanelRequest
    {
        public string action { get; set; } = "toggle";
        public string directory { get; set; } = "";
        public long sourceWindow { get; set; }
        public string sessionId { get; set; } = "";
    }

    public static class PanelGeometry
    {
        // Dimensions are physical screen pixels; fit even on small displays.
        public static int[] Center(int left, int top, int right, int bottom,
            int workLeft, int workTop, int workRight, int workBottom)
        {
            int availableWidth = Math.Max(1, workRight - workLeft);
            int availableHeight = Math.Max(1, workBottom - workTop);
            int width = Math.Min(availableWidth, Math.Max(640, (int)((right - left) * .68)));
            int height = Math.Min(availableHeight, Math.Max(360, (int)((bottom - top) * .60)));
            int x = Math.Clamp(left + (right - left - width) / 2, workLeft, workRight - width);
            int y = Math.Clamp(top + (bottom - top - height) / 2, workTop, workBottom - height);
            return new[] { x, y, width, height };
        }
    }

    public static class PanelHost
    {
        private sealed class Panel
        {
            public IntPtr Window;
            public IntPtr Source;
            public string Title = "";
            public int[] Bounds;
        }

        private static readonly ConcurrentDictionary<string, Panel> Panels = new ConcurrentDictionary<string, Panel>();
        private static readonly SemaphoreSlim Gate = new SemaphoreSlim(1, 1);
        private static readonly Native.HookProc KeyboardCallback = Keyboard;
        private static readonly Native.HookProc MouseCallback = Mouse;
        private static string stateRoot = "";
        private static string modulePath = "";
        private static string shellPath = "";
        private static bool fDown;
        private static uint messageThread;
        private static Panel dragPanel;
        private static Native.Point dragOrigin;
        private static Native.Rect dragBounds;

        public static void Run(string pipeName, string dataDirectory, string module, string shell)
        {
            using var singleton = new Mutex(true, @"Local\" + pipeName, out bool first);
            if (!first) return;
            stateRoot = dataDirectory;
            modulePath = module;
            shellPath = shell;
            Directory.CreateDirectory(stateRoot);
            // Keep sizing consistent across monitors with different scaling factors.
            Native.SetThreadDpiAwarenessContext(new IntPtr(-4));
            messageThread = Native.GetCurrentThreadId();
            Native.PeekMessage(out _, IntPtr.Zero, 0, 0, 0); // Create the message queue before the pipe starts.
            IntPtr hook = Native.SetWindowsHookEx(13, KeyboardCallback, Native.GetModuleHandle(null), 0);
            if (hook == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
            IntPtr mouseHook = Native.SetWindowsHookEx(14, MouseCallback, Native.GetModuleHandle(null), 0);
            if (mouseHook == IntPtr.Zero) { Native.UnhookWindowsHookEx(hook); throw new System.ComponentModel.Win32Exception(); }
            using var stop = new CancellationTokenSource();
            string infoPath = Path.Combine(stateRoot, "host.json");
            File.WriteAllText(infoPath, JsonSerializer.Serialize(new { pid = Environment.ProcessId, pipeName }));
            Task server = Serve(pipeName, stop.Token);
            using var maintenance = new Timer(_ => RecoverOrphans(), null, 2000, 2000);
            try
            {
                while (Native.GetMessage(out var message, IntPtr.Zero, 0, 0) > 0)
                {
                    Native.TranslateMessage(ref message);
                    Native.DispatchMessage(ref message);
                }
            }
            finally
            {
                stop.Cancel();
                Native.UnhookWindowsHookEx(hook);
                Native.UnhookWindowsHookEx(mouseHook);
                foreach (Panel panel in Panels.Values)
                    if (IsPanel(panel)) { Native.ShowWindow(panel.Window, 5); Native.RemoveProp(panel.Window, panel.Title); }
                try { server.GetAwaiter().GetResult(); } catch (OperationCanceledException) { }
                File.Delete(infoPath);
                singleton.ReleaseMutex();
            }
        }

        private static async Task Serve(string pipeName, CancellationToken stop)
        {
            while (!stop.IsCancellationRequested)
            {
                using var pipe = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1,
                    PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                try
                {
                    await pipe.WaitForConnectionAsync(stop).ConfigureAwait(false);
                    using var timeout = CancellationTokenSource.CreateLinkedTokenSource(stop);
                    timeout.CancelAfter(TimeSpan.FromSeconds(15));
                    using var reader = new StreamReader(pipe, new UTF8Encoding(false), false, 1024, true);
                    using var writer = new StreamWriter(pipe, new UTF8Encoding(false), 1024, true) { AutoFlush = true };
                    string json = await ReadRequest(reader, timeout.Token).ConfigureAwait(false);
                    bool shutdown = false;
                    object response;
                    try
                    {
                        var request = JsonSerializer.Deserialize<PanelRequest>(json)
                            ?? throw new ArgumentException("Empty request.");
                        if (request.action == "shutdown") shutdown = true;
                        else if (request.action == "toggle") await Toggle(request, timeout.Token).ConfigureAwait(false);
                        else throw new ArgumentException("Unknown action.");
                        response = new { ok = true };
                    }
                    catch (Exception error)
                    {
                        Log(error.Message);
                        response = new { ok = false, error = error.Message };
                    }
                    await writer.WriteLineAsync(JsonSerializer.Serialize(response).AsMemory(), timeout.Token).ConfigureAwait(false);
                    if (shutdown)
                    {
                        Native.PostThreadMessage(messageThread, 0x0012, IntPtr.Zero, IntPtr.Zero);
                        return;
                    }
                }
                catch (OperationCanceledException) when (!stop.IsCancellationRequested) { Log("Client timed out."); }
                catch (IOException error) { Log(error.Message); }
            }
        }

        private static async Task<string> ReadRequest(StreamReader reader, CancellationToken stop)
        {
            var text = new StringBuilder();
            var character = new char[1];
            while (await reader.ReadAsync(character.AsMemory(), stop).ConfigureAwait(false) != 0)
            {
                if (character[0] == '\n') return text.ToString();
                if (text.Length >= 65536) throw new IOException("Request exceeds 64 KiB.");
                text.Append(character[0]);
            }
            throw new IOException("Client disconnected before completing a request.");
        }

        private static async Task Toggle(PanelRequest request, CancellationToken stop)
        {
            await Gate.WaitAsync(stop).ConfigureAwait(false);
            try
            {
                IntPtr source = new IntPtr(request.sourceWindow);
                if (!IsTerminal(source)) throw new ArgumentException("Run Open-WtPanel in a foreground Windows Terminal window.");
                Panel existing = Panels.Values.FirstOrDefault(p => p.Window == source && IsPanel(p));
                if (existing != null) { Hide(existing); return; }
                if (!Path.IsPathFullyQualified(request.directory) || !Directory.Exists(request.directory))
                    throw new DirectoryNotFoundException("The current directory no longer exists or is not an absolute filesystem path.");

                string session = string.IsNullOrWhiteSpace(request.sessionId) ? source.ToString() : request.sessionId;
                if (!Panels.TryGetValue(session, out Panel panel) || !IsPanel(panel))
                {
                    panel = new Panel { Source = source, Title = "wttools Panel · " + Guid.NewGuid().ToString("N").Substring(0, 8) };
                    // Choose the monitor before WT creates its HWND. Moving a new
                    // window afterwards triggers an asynchronous DPI resize in WT.
                    panel.Bounds = InitialBounds(source);
                    // Avoid passing user paths through WT's semicolon command parser.
                    string command = Bootstrap(request.directory, modulePath, stateRoot);
                    var start = new ProcessStartInfo("wt.exe") { UseShellExecute = false, CreateNoWindow = true };
                    string position = FormattableString.Invariant($"{panel.Bounds[0]},{panel.Bounds[1]}");
                    foreach (string argument in new[] { "-w", panel.Title, "--focus", "--pos", position, "--size", "80,20", "new-tab", "--title", panel.Title,
                        "--suppressApplicationTitle", shellPath, "-NoLogo", "-NoProfile", "-NoExit", "-EncodedCommand", command })
                        start.ArgumentList.Add(argument);
                    using (Process launcher = Process.Start(start)) { }
                    for (int attempt = 0; attempt < 100; attempt++)
                    {
                        panel.Window = FindPanel(panel.Title);
                        if (panel.Window != IntPtr.Zero) break;
                        await Task.Delay(80, stop).ConfigureAwait(false);
                    }
                    if (panel.Window == IntPtr.Zero)
                        throw new TimeoutException("Windows Terminal did not create the panel within 8 seconds. Check wt.exe and your Terminal profile.");
                    if (!Native.SetProp(panel.Window, panel.Title, new IntPtr(1)))
                        throw new System.ComponentModel.Win32Exception();
                    // The HWND exists before Terminal completes its initial layout.
                    // Seed a modest cell size on the correct monitor above,
                    // then apply exact physical bounds after startup settles.
                    await Task.Delay(600, stop).ConfigureAwait(false);
                    Panels[session] = panel;
                }
                panel.Source = source;
                Show(panel);
            }
            finally { Gate.Release(); }
        }

        // Public so path quoting can be verified without opening any windows.
        public static string Bootstrap(string directory, string module, string dataDirectory = null)
        {
            string code = "$env:WTTOOLS_PANEL = '1'; " +
                "foreach ($p in @($PROFILE.AllUsersAllHosts,$PROFILE.AllUsersCurrentHost,$PROFILE.CurrentUserAllHosts,$PROFILE.CurrentUserCurrentHost)) " +
                "{ if (Test-Path -LiteralPath $p) { . $p } }; " +
                "Import-Module " + Quote(module) + "; Enable-WtTools -Panel" +
                (dataDirectory == null ? "" : " -StateRoot " + Quote(dataDirectory)) + "; " +
                "Set-Location -LiteralPath " + Quote(directory);
            return Convert.ToBase64String(Encoding.Unicode.GetBytes(code));
        }

        private static string Quote(string text) => "'" + text.Replace("'", "''") + "'";

        private static int[] InitialBounds(IntPtr source)
        {
            IntPtr previousDpi = Native.SetThreadDpiAwarenessContext(new IntPtr(-4));
            try
            {
                if (!Native.GetWindowRect(source, out var parent))
                    throw new InvalidOperationException("Cannot read the source terminal bounds.");
                var monitor = new Native.MonitorInfo { Size = Marshal.SizeOf<Native.MonitorInfo>() };
                if (!Native.GetMonitorInfo(Native.MonitorFromWindow(source, 2), ref monitor))
                    throw new InvalidOperationException("Cannot read the source monitor work area.");
                var work = monitor.Work;
                return PanelGeometry.Center(parent.Left, parent.Top, parent.Right, parent.Bottom,
                    work.Left, work.Top, work.Right, work.Bottom);
            }
            finally { if (previousDpi != IntPtr.Zero) Native.SetThreadDpiAwarenessContext(previousDpi); }
        }

        private static void Show(Panel panel)
        {
            // IPC continuations run on pool threads, independently of the message loop.
            IntPtr previousDpi = Native.SetThreadDpiAwarenessContext(new IntPtr(-4));
            try
            {
                if (!Native.GetWindowRect(panel.Source, out var parent)) return;
                var monitor = new Native.MonitorInfo { Size = Marshal.SizeOf<Native.MonitorInfo>() };
                if (!Native.GetMonitorInfo(Native.MonitorFromWindow(panel.Bounds == null ? panel.Source : panel.Window, 2), ref monitor)) return;
                var work = monitor.Work;
                int[] box = panel.Bounds ?? PanelGeometry.Center(parent.Left, parent.Top, parent.Right, parent.Bottom,
                    work.Left, work.Top, work.Right, work.Bottom);
                box[2] = Math.Min(box[2], work.Right - work.Left);
                box[3] = Math.Min(box[3], work.Bottom - work.Top);
                box[0] = Math.Clamp(box[0], work.Left, work.Right - box[2]);
                box[1] = Math.Clamp(box[1], work.Top, work.Bottom - box[3]);
                Native.ShowWindow(panel.Window, 9); // Restore a minimized/maximized panel before sizing.
                Native.SetWindowPos(panel.Window, IntPtr.Zero, box[0], box[1], box[2], box[3], 0x0040);
                Native.Focus(panel.Window);
            }
            finally
            {
                if (previousDpi != IntPtr.Zero) Native.SetThreadDpiAwarenessContext(previousDpi);
            }
        }

        private static void Hide(Panel panel)
        {
            if (!IsPanel(panel)) return;
            IntPtr previousDpi = Native.SetThreadDpiAwarenessContext(new IntPtr(-4));
            try
            {
                if (Native.GetWindowRect(panel.Window, out var rect))
                    panel.Bounds = new[] { rect.Left, rect.Top, rect.Right - rect.Left, rect.Bottom - rect.Top };
            }
            finally { if (previousDpi != IntPtr.Zero) Native.SetThreadDpiAwarenessContext(previousDpi); }
            Native.ShowWindow(panel.Window, 0);
            if (Native.IsWindow(panel.Source)) Native.Focus(panel.Source);
        }

        private static IntPtr Keyboard(int code, IntPtr message, IntPtr data)
        {
            if (code >= 0)
            {
                var key = Marshal.PtrToStructure<Native.KeyboardData>(data);
                if (key.Key == 0x46) // F; remapped/synthetic keyboard input works too.
                {
                    bool up = message.ToInt64() == 0x0101 || message.ToInt64() == 0x0105;
                    if (up) { bool handled = fDown; fDown = false; if (handled) return new IntPtr(1); }
                    else if (fDown) return new IntPtr(1); // Consume repeats even after focus returned to the owner.
                    else if ((key.Flags & 0x20) != 0 && !Native.ModifierDown(0x10) && !Native.ModifierDown(0x11)
                        && !Native.ModifierDown(0x5B) && !Native.ModifierDown(0x5C))
                    {
                        IntPtr foreground = Native.GetForegroundWindow();
                        Panel panel = Panels.Values.FirstOrDefault(p => p.Window == foreground);
                        if (panel != null)
                        {
                            if (!fDown)
                                Task.Run(async () =>
                                {
                                    await Gate.WaitAsync().ConfigureAwait(false);
                                    try { Hide(panel); } catch (Exception error) { Log(error.Message); }
                                    finally { Gate.Release(); }
                                });
                            fDown = true;
                            return new IntPtr(1);
                        }
                    }
                }
            }
            return Native.CallNextHookEx(IntPtr.Zero, code, message, data);
        }

        private static IntPtr Mouse(int code, IntPtr message, IntPtr data)
        {
            if (code < 0) return Native.CallNextHookEx(IntPtr.Zero, code, message, data);
            // A native callback can enter with a different DPI context from
            // the message loop. Keep hit testing, bounds and movement in the
            // same physical coordinate space for every callback.
            IntPtr previousDpi = Native.SetThreadDpiAwarenessContext(new IntPtr(-4));
            try { return MouseInPhysicalCoordinates(code, message, data); }
            finally
            {
                if (previousDpi != IntPtr.Zero) Native.SetThreadDpiAwarenessContext(previousDpi);
            }
        }

        private static IntPtr MouseInPhysicalCoordinates(int code, IntPtr message, IntPtr data)
        {
            if (code >= 0)
            {
                int kind = message.ToInt32();
                var mouse = Marshal.PtrToStructure<Native.MouseData>(data);
                if (kind == 0x0201 && Native.ModifierDown(0x12) // Alt + left button
                    && !Native.ModifierDown(0x10) && !Native.ModifierDown(0x11)
                    && !Native.ModifierDown(0x5B) && !Native.ModifierDown(0x5C))
                {
                    IntPtr window = Native.GetAncestor(Native.WindowFromPhysicalPoint(mouse.Position), 2);
                    Panel panel = Panels.Values.FirstOrDefault(p => p.Window == window
                        && Native.GetProp(p.Window, p.Title) == new IntPtr(1));
                    if (panel != null && Native.GetWindowRect(window, out dragBounds))
                    {
                        dragPanel = panel;
                        dragOrigin = mouse.Position;
                        return new IntPtr(1);
                    }
                }
                if (dragPanel != null)
                {
                    if (kind == 0x0200 || kind == 0x0202)
                    {
                        // Queue to WT's thread; never block the global input hook
                        // behind a busy terminal. Mouse coordinates are physical pixels.
                        Native.SetWindowPos(dragPanel.Window, IntPtr.Zero,
                            dragBounds.Left + mouse.Position.X - dragOrigin.X,
                            dragBounds.Top + mouse.Position.Y - dragOrigin.Y,
                            0, 0, 0x4015); // ASYNCWINDOWPOS | NOACTIVATE | NOZORDER | NOSIZE
                        if (kind == 0x0202)
                        {
                            dragPanel = null;
                            return new IntPtr(1);
                        }
                        // Do not swallow WM_MOUSEMOVE: the low-level hook runs
                        // before Windows updates the cursor. Blocking it freezes
                        // the pointer and makes relative motion snap the panel back.
                    }
                }
            }
            return Native.CallNextHookEx(IntPtr.Zero, code, message, data);
        }

        private static void RecoverOrphans()
        {
            if (!Gate.Wait(0)) return;
            try
            {
                foreach (var pair in Panels)
                {
                    if (!IsPanel(pair.Value)) Panels.TryRemove(pair.Key, out _);
                    else if (!IsTerminal(pair.Value.Source))
                    {
                        Native.ShowWindow(pair.Value.Window, 5); // Never strand a live shell when its owner closes.
                        Native.RemoveProp(pair.Value.Window, pair.Value.Title);
                        Panels.TryRemove(pair.Key, out _);
                    }
                }
            }
            catch (Exception error) { Log(error.Message); }
            finally { Gate.Release(); }
        }

        private static bool IsPanel(Panel panel) => IsTerminal(panel.Window) && Native.GetProp(panel.Window, panel.Title) == new IntPtr(1);
        private static bool IsTerminal(IntPtr window)
        {
            if (window == IntPtr.Zero || !Native.IsWindow(window)) return false;
            Native.GetWindowThreadProcessId(window, out uint pid);
            try { using var process = Process.GetProcessById((int)pid); return process.ProcessName.Equals("WindowsTerminal", StringComparison.OrdinalIgnoreCase); }
            catch (ArgumentException) { return false; }
            catch (InvalidOperationException) { return false; }
            catch (System.ComponentModel.Win32Exception) { return false; }
        }

        private static string Title(IntPtr window)
        {
            var title = new StringBuilder(1024);
            Native.GetWindowText(window, title, title.Capacity);
            return title.ToString();
        }

        private static IntPtr FindPanel(string title)
        {
            IntPtr found = IntPtr.Zero;
            Native.EnumWindows((window, _) =>
            {
                if (Title(window).Contains(title, StringComparison.Ordinal) && IsTerminal(window))
                { found = window; return false; }
                return true;
            }, IntPtr.Zero);
            return found;
        }

        private static void Log(string message)
        {
            try { File.AppendAllText(Path.Combine(stateRoot, "host.log"), DateTimeOffset.Now + " " + message + Environment.NewLine); }
            catch (IOException) { }
        }
    }

    internal static class Native
    {
        public delegate IntPtr HookProc(int code, IntPtr message, IntPtr data);
        public delegate bool EnumProc(IntPtr window, IntPtr data);
        [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] public struct MonitorInfo { public int Size; public Rect Monitor, Work; public uint Flags; }
        [StructLayout(LayoutKind.Sequential)] public struct Message { public IntPtr Window; public uint Id; public IntPtr WParam, LParam; public uint Time; public int X, Y; public uint Private; }
        [StructLayout(LayoutKind.Sequential)] public struct KeyboardData { public uint Key, Scan, Flags, Time; public UIntPtr Extra; }
        [StructLayout(LayoutKind.Sequential)] public struct Point { public int X, Y; }
        [StructLayout(LayoutKind.Sequential)] public struct MouseData { public Point Position; public uint Data, Flags, Time; public UIntPtr Extra; }
        [DllImport("user32.dll")] public static extern IntPtr WindowFromPhysicalPoint(Point point);
        [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr window, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool SetProp(IntPtr window, string name, IntPtr value);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr GetProp(IntPtr window, string name);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr RemoveProp(IntPtr window, string name);
        [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
        [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr GetModuleHandle(string name);
        [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SetWindowsHookEx(int kind, HookProc callback, IntPtr module, uint thread);
        [DllImport("user32.dll")] public static extern bool UnhookWindowsHookEx(IntPtr hook);
        [DllImport("user32.dll")] public static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr message, IntPtr data);
        [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int key);
        public static bool ModifierDown(int key) => (GetAsyncKeyState(key) & 0x8000) != 0;
        [DllImport("user32.dll")] public static extern int GetMessage(out Message message, IntPtr window, uint min, uint max);
        [DllImport("user32.dll")] public static extern bool PeekMessage(out Message message, IntPtr window, uint min, uint max, uint remove);
        [DllImport("user32.dll")] public static extern bool TranslateMessage(ref Message message);
        [DllImport("user32.dll")] public static extern IntPtr DispatchMessage(ref Message message);
        [DllImport("user32.dll")] public static extern bool PostThreadMessage(uint thread, uint message, IntPtr wParam, IntPtr lParam);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr window);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr window);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr window, out Rect rect);
        [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr window, int command);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
        [DllImport("user32.dll")] private static extern bool AttachThreadInput(uint from, uint to, bool attach);
        public static void Focus(IntPtr window)
        {
            if (SetForegroundWindow(window)) return;
            // A low-level hook receives the shortcut outside the foreground
            // process. Briefly share its input queue when returning focus.
            PeekMessage(out _, IntPtr.Zero, 0, 0, 0);
            uint current = GetCurrentThreadId();
            uint foreground = GetWindowThreadProcessId(GetForegroundWindow(), out _);
            bool attached = foreground != 0 && foreground != current && AttachThreadInput(current, foreground, true);
            try { SetForegroundWindow(window); }
            finally { if (attached) AttachThreadInput(current, foreground, false); }
        }
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr window, StringBuilder title, int count);
        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr data);
    }
}
