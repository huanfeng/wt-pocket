using System;
using System.IO;
using System.Runtime.Versioning;

[assembly: SupportedOSPlatform("windows10.0.15063")]

internal static class Program
{
    private static int Main(string[] args)
    {
        if (!OperatingSystem.IsWindows() || args.Length != 4) return 2;
        try
        {
            WtTools.PanelHost.Run(args[0], args[1], args[2], args[3]);
            return 0;
        }
        catch (Exception error)
        {
            Directory.CreateDirectory(args[1]);
            File.AppendAllText(Path.Combine(args[1], "host.log"), error + Environment.NewLine);
            return 1;
        }
    }
}
