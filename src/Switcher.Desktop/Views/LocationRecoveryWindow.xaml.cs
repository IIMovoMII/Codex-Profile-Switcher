using System.IO;
using System.Windows;
using Microsoft.Win32;
using Switcher.Infrastructure.Configuration;

namespace Switcher.Desktop.Views;

public partial class LocationRecoveryWindow : Window
{
    private readonly DataLocationResolver _resolver;
    public LocationResolution Resolution { get; private set; }
    private string? _selectedHome;
    private string? _selectedData;

    public LocationRecoveryWindow(DataLocationResolver resolver, LocationResolution resolution)
    {
        InitializeComponent(); _resolver = resolver; Resolution = resolution; Display();
    }

    private void Display()
    {
        DataPath.Text = Resolution.Paths.DataDirectory; HomePath.Text = Resolution.Paths.CodexHome;
        ResultText.Text = Resolution.Message; UseButton.IsEnabled = Resolution.IsValid;
        HeadingText.Text = Resolution.IsValid ? "已找到有效的数据位置" : "自动定位暂时不可用";
    }

    private string? Choose(string title, string path)
    {
        var dialog = new OpenFolderDialog { Title = title, Multiselect = false };
        var initial = path;
        while (!Directory.Exists(initial))
        {
            initial = Path.GetDirectoryName(initial);
            if (string.IsNullOrEmpty(initial)) break;
        }
        if (!string.IsNullOrEmpty(initial)) dialog.InitialDirectory = initial;
        return dialog.ShowDialog(this) == true ? dialog.FolderName : null;
    }

    private void ChooseData(object sender, RoutedEventArgs args)
    {
        var selected = Choose("选择原有的账号数据文件夹", DataPath.Text);
        if (selected is null) return;
        _selectedData = selected;
        Resolution = _resolver.Resolve(_selectedHome, _selectedData, Resolution.Paths.CodexExecutable); Display();
    }

    private void ChooseHome(object sender, RoutedEventArgs args)
    {
        var selected = Choose("选择 Codex 聊天与项目文件夹", HomePath.Text);
        if (selected is null) return;
        _selectedHome = selected;
        Resolution = _resolver.Resolve(_selectedHome, _selectedData ?? DataPath.Text, Resolution.Paths.CodexExecutable); Display();
    }

    private void Retry(object sender, RoutedEventArgs args)
    {
        _selectedHome = _selectedData = null;
        Resolution = _resolver.Resolve(codexExecutable: Resolution.Paths.CodexExecutable); Display();
    }

    private void UseLocations(object sender, RoutedEventArgs args)
    {
        try
        {
            _resolver.Remember(Resolution.Paths);
            Resolution = Resolution with { Paths = Resolution.Paths with { DataDirectoryOrigin = "手动选择后验证通过", CodexHomeOrigin = "手动选择后验证通过" } };
            DialogResult = true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { ResultText.Text = "位置未保存：" + ex.Message; }
    }
}
