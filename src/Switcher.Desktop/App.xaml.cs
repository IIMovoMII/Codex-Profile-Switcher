using System.Windows;
using System.IO;
using Switcher.Infrastructure;
using Switcher.Infrastructure.Configuration;
using Switcher.Desktop.Views;

namespace Switcher.Desktop;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        try
        {
            var options = DesktopStartupOptions.Parse(e.Args);
            var resolver = new DataLocationResolver();
            var resolution = resolver.Resolve(options.CodexHome, options.DataDirectory, options.CodexExecutable);
            if (!resolution.IsValid)
            {
                if (resolution.ExplicitFailure) throw new IOException(resolution.Message + " 请修正启动参数；不会回退到其他目录。");
                ShutdownMode = ShutdownMode.OnExplicitShutdown;
                var recovery = new LocationRecoveryWindow(resolver, resolution);
                if (recovery.ShowDialog() != true) { Shutdown(1); return; }
                resolution = recovery.Resolution;
            }
            var host = ApplicationHost.Create(resolution.Paths with
            {
                ManualModelCatalogOverride = options.RelayModelCatalogPath,
                MonitorDataDirectory = options.MonitorDataDirectory
            }, options.CodexExecutable);
            var window = new MainWindow(host);
            MainWindow = window;
            ShutdownMode = ShutdownMode.OnMainWindowClose;
            window.Show();
        }
        catch (Exception ex)
        {
            MessageBox.Show("切换器启动失败：" + ex.Message, "Codex Profile Switcher", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
        }
    }
}

internal sealed record DesktopStartupOptions(string? CodexHome, string? DataDirectory, string? CodexExecutable,
    string? RelayModelCatalogPath = null, string? MonitorDataDirectory = null)
{
    public static DesktopStartupOptions Parse(string[] args)
    {
        string? home = null;
        string? data = null;
        string? executable = null;
        string? catalog = null;
        string? monitor = null;
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
                case "monitordatadir": monitor = value; break;
                case "relaymodelcatalogpath": catalog = value; break;
                default: index--; break;
            }
        }
        return new DesktopStartupOptions(home, data, executable, catalog, monitor);
    }
}
