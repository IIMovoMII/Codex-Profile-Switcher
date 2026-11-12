using System.Windows;
using Switcher.Infrastructure;

namespace Switcher.Desktop;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        try
        {
            var options = DesktopStartupOptions.Parse(e.Args);
            var paths = Switcher.Core.Paths.SwitcherPaths.FromEnvironment(options.CodexHome, options.DataDirectory, options.CodexExecutable);
            var host = ApplicationHost.Create(paths, options.CodexExecutable);
            var window = new MainWindow(host);
            MainWindow = window;
            window.Show();
        }
        catch (Exception ex)
        {
            MessageBox.Show("切换器启动失败：" + ex.Message, "Codex Profile Switcher", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
        }
    }
}

internal sealed record DesktopStartupOptions(string? CodexHome, string? DataDirectory, string? CodexExecutable)
{
    public static DesktopStartupOptions Parse(string[] args)
    {
        string? home = null;
        string? data = null;
        string? executable = null;
        for (var index = 0; index < args.Length; index++)
        {
            var name = args[index].TrimStart('-').ToLowerInvariant().Replace("-", "", StringComparison.Ordinal);
            if (name is "noshow" or "unsafeallowrunningcodex" or "libraryonly" or "fullhistoryscan") continue;
            if (index + 1 >= args.Length) continue;
            var value = args[++index];
            switch (name)
            {
                case "codexhome": home = value; break;
                case "datadir": case "datadirectory": data = value; break;
                case "codexexe": case "codexexecutable": executable = value; break;
                case "monitordatadir": case "relaymodelcatalogpath": _ = value; break;
                default: index--; break;
            }
        }
        return new DesktopStartupOptions(home, data, executable);
    }
}
