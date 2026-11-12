using System.Windows;
using System.Windows.Controls;
using System.IO;
using System.Diagnostics;
using Microsoft.Win32;
using Switcher.Core.Configuration;
using Switcher.Core.Paths;
using Switcher.Core.Profiles;
using Switcher.Core.Switching;
using Switcher.Infrastructure;

namespace Switcher.Desktop;

public partial class MainWindow : Window
{
    private readonly ApplicationHost _host;
    private readonly MainViewModel _viewModel;

    public MainWindow(ApplicationHost host)
    {
        _host = host;
        InitializeComponent();
        _viewModel = new MainViewModel(host)
        {
            AddApiRequested = AddApiAsync,
            ImportOfficialRequested = ImportOfficialAsync,
            ReauthorizeRequested = ReauthorizeAsync,
            EditRequested = EditProfileAsync,
            RenameRequested = RenameProfileAsync
        };
        DataContext = _viewModel;
    }

    private Task AddApiAsync()
    {
        var dialog = new ApiProfileDialog("添加 API 档案", null, _host.Registry.Load().OfficialProfiles, _host.Paths, _host.Catalogs);
        if (dialog.ShowDialog() != true) return Task.CompletedTask;
        try { _host.Profiles.AddApi(new AddApiProfile(dialog.ProfileName, dialog.BaseUrl, dialog.ApiKey, dialog.CatalogPath, dialog.Settings)); }
        catch (Exception ex) { MessageBox.Show(ex.Message, "添加失败", MessageBoxButton.OK, MessageBoxImage.Error); }
        return Task.CompletedTask;
    }

    private async Task ImportOfficialAsync()
    {
        try
        {
            var nameDialog = new TextInputDialog("添加官方账号", "账号名称（可留空）", "");
            nameDialog.Owner = this;
            if (nameDialog.ShowDialog() != true) return;
            await _host.Service.AddOfficialInteractivelyAsync(string.IsNullOrWhiteSpace(nameDialog.Value) ? null : nameDialog.Value);
        }
        catch (Exception ex) { MessageBox.Show(ex.Message, "导入失败", MessageBoxButton.OK, MessageBoxImage.Error); }
    }

    private async Task ReauthorizeAsync(ProfileRowViewModel row)
    {
        if (row.Kind != ProfileKind.Official) return;
        try { await _host.Service.ReauthorizeOfficialAsync(row.Id); }
        catch (Exception ex) { MessageBox.Show(ex.Message, "重新授权失败", MessageBoxButton.OK, MessageBoxImage.Error); }
    }

    private Task EditProfileAsync(ProfileRowViewModel row)
    {
        try
        {
            var registry = _host.Registry.Load();
            if (row.Kind == ProfileKind.Official)
            {
                var official = (OfficialProfile)registry.Find(ProfileKind.Official, row.Id);
                var settingsDialog = new ProfileSettingsDialog(official);
                if (settingsDialog.ShowDialog() == true) _host.Profiles.UpdateSettings(ProfileKind.Official, official.Id, settingsDialog.Settings);
                return Task.CompletedTask;
            }

            var profile = (ApiProfile)registry.Find(ProfileKind.Api, row.Id);
            var dialog = new ApiProfileDialog("编辑 API 档案", profile, registry.OfficialProfiles, _host.Paths, _host.Catalogs);
            if (dialog.ShowDialog() == true) _host.Profiles.EditApiProfile(profile.Id, dialog.Settings, dialog.BaseUrl, dialog.CatalogMode, dialog.CatalogPath, dialog.SourceOfficialId, dialog.ApiKey);
        }
        catch (Exception ex) { MessageBox.Show(ex.Message, "保存失败", MessageBoxButton.OK, MessageBoxImage.Error); }
        return Task.CompletedTask;
    }

    private Task RenameProfileAsync(ProfileRowViewModel row)
    {
        var dialog = new TextInputDialog("重命名档案", "名称", row.Name);
        if (dialog.ShowDialog() != true) return Task.CompletedTask;
        try { _host.Profiles.Rename(row.Kind, row.Id, dialog.Value); }
        catch (Exception ex) { MessageBox.Show(ex.Message, "重命名失败", MessageBoxButton.OK, MessageBoxImage.Error); }
        return Task.CompletedTask;
    }
}

internal sealed class TextInputDialog : Window
{
    private readonly TextBox _input;
    public string Value => _input.Text.Trim();
    public TextInputDialog(string title, string label, string value)
    {
        Owner = Application.Current?.MainWindow; Title = title; Width = 420; Height = 170; WindowStartupLocation = WindowStartupLocation.CenterOwner; ResizeMode = ResizeMode.NoResize;
        var grid = new Grid { Margin = new Thickness(18) }; grid.RowDefinitions.Add(new RowDefinition()); grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var stack = new StackPanel(); stack.Children.Add(new TextBlock { Text = label, Margin = new Thickness(0, 0, 0, 6) });
        _input = new TextBox { Text = value, Padding = new Thickness(7) }; stack.Children.Add(_input); grid.Children.Add(stack);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
        var ok = new Button { Content = "确定", IsDefault = true, Padding = new Thickness(14, 6, 14, 6) }; ok.Click += (_, _) => { if (string.IsNullOrWhiteSpace(Value)) { MessageBox.Show("名称不能为空。", Title); return; } DialogResult = true; };
        var cancel = new Button { Content = "取消", IsCancel = true, Padding = new Thickness(14, 6, 14, 6), Margin = new Thickness(8, 0, 0, 0) };
        buttons.Children.Add(ok); buttons.Children.Add(cancel); Grid.SetRow(buttons, 1); grid.Children.Add(buttons); Content = grid; Loaded += (_, _) => { _input.Focus(); _input.SelectAll(); };
    }
}

internal sealed class ApiProfileDialog : Window
{
    private readonly TextBox _name = new();
    private readonly TextBox _baseUrl = new();
    private readonly PasswordBox _apiKey = new();
    private readonly TextBox _catalog = new();
    private readonly ComboBox _mode = new();
    private readonly ComboBox _source = new();
    private readonly ComboBox _modelPolicy = new();
    private readonly TextBox _model = new();
    private readonly ComboBox _contextPolicy = new();
    private readonly TextBox _context = new();
    private readonly ComboBox _proxy = new();
    private readonly TextBox _resolvedCatalogPath = new() { IsReadOnly = true, TextWrapping = TextWrapping.Wrap, MaxHeight = 58, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    private readonly TextBlock _catalogStatus = new() { TextWrapping = TextWrapping.Wrap, Foreground = System.Windows.Media.Brushes.DimGray };
    private readonly ApiProfile? _existing;
    private readonly IReadOnlyList<OfficialProfile> _officials;
    private readonly SwitcherPaths _paths;
    private readonly IModelCatalogProvider _catalogs;
    public string ProfileName => _name.Text.Trim();
    public string BaseUrl => _baseUrl.Text.Trim();
    public string ApiKey => string.IsNullOrWhiteSpace(_apiKey.Password) && _existing is not null ? "" : _apiKey.Password;
    public string CatalogPath => _catalog.Text.Trim();
    public string CatalogMode => _mode.SelectedValue?.ToString() ?? "manual";
    public string SourceOfficialId => _source.SelectedValue?.ToString() ?? "";
    public ProfileSettings Settings => new(
        _modelPolicy.SelectedValue?.ToString() switch { "explicit" => SettingChoice<string>.Set(_model.Text.Trim()), "preserve" => SettingChoice<string>.Preserve(), _ => SettingChoice<string>.Inherit() },
        _contextPolicy.SelectedValue?.ToString() switch { "explicit" when int.TryParse(_context.Text, out var context) && context > 0 => SettingChoice<int>.Set(context), "preserve" => SettingChoice<int>.Preserve(), "explicit" => throw new InvalidDataException("上下文窗口必须是正整数。"), _ => SettingChoice<int>.Inherit() },
        _proxy.SelectedValue?.ToString() switch { "system" => SettingChoice<ProxyPolicy>.Set(ProxyPolicy.System), "direct" => SettingChoice<ProxyPolicy>.Set(ProxyPolicy.Direct), "preserve" => SettingChoice<ProxyPolicy>.Preserve(), _ => SettingChoice<ProxyPolicy>.Inherit() });

    public ApiProfileDialog(string title, ApiProfile? profile, IReadOnlyList<OfficialProfile> officials, SwitcherPaths paths, IModelCatalogProvider catalogs)
    {
        _existing = profile; _officials = officials; _paths = paths; _catalogs = catalogs;
        Owner = Application.Current?.MainWindow; Title = title; Width = 720; Height = 720; MinHeight = 520; WindowStartupLocation = WindowStartupLocation.CenterOwner; ResizeMode = ResizeMode.CanResize;
        var grid = new Grid { Margin = new Thickness(18) };
        var row = 0;
        for (var i = 0; i < 13; i++) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        AddRow(grid, row++, "名称", _name); AddRow(grid, row++, "HTTPS API 地址", _baseUrl);
        AddRow(grid, row++, profile is null ? "API Key" : "替换 API Key（可留空）", _apiKey);
        SetupChoice(_modelPolicy, [("inherit", "继承全局"), ("preserve", "保留当前值"), ("explicit", "指定模型")]);
        AddRow(grid, row++, "模型", CreatePair(_modelPolicy, _model));
        SetupChoice(_contextPolicy, [("inherit", "继承全局"), ("preserve", "保留当前值"), ("explicit", "指定窗口")]);
        AddRow(grid, row++, "上下文窗口", CreatePair(_contextPolicy, _context));
        SetupChoice(_proxy, [("inherit", "继承"), ("preserve", "保留当前值"), ("system", "使用系统代理"), ("direct", "直连")]);
        AddRow(grid, row++, "代理策略", _proxy);
        AddRow(grid, row++, "模型目录文件", CreateCatalogEditor());
        _mode.ItemsSource = new[] { new { Value = "manual", Text = "手动维护目录" }, new { Value = "official", Text = "跟随指定官方目录" } }; _mode.DisplayMemberPath = "Text"; _mode.SelectedValuePath = "Value"; AddRow(grid, row++, "维护方式", _mode);
        AddRow(grid, row++, "官方来源", _source);
        AddRow(grid, row++, "实际使用路径", _resolvedCatalogPath);
        AddRow(grid, row++, "目录状态", _catalogStatus);
        var maintenance = new StackPanel { Margin = new Thickness(8, 0, 0, 12) };
        maintenance.Children.Add(new TextBlock
        {
            Text = "API 模式可使用官方账号的已核验本地快照，或手动维护完整 Codex 模型目录。自动同步不会联网，也不会覆盖手动文件；目录中有模型不代表中转站支持调用。",
            TextWrapping = TextWrapping.Wrap,
            Foreground = System.Windows.Media.Brushes.DimGray
        });
        var catalogActions = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
        var openFile = new Button { Content = "打开模型目录文件" };
        openFile.Click += (_, _) => OpenCatalog(false);
        var openFolder = new Button { Content = "打开所在文件夹", Margin = new Thickness(0) };
        openFolder.Click += (_, _) => OpenCatalog(true);
        catalogActions.Children.Add(openFile); catalogActions.Children.Add(openFolder); maintenance.Children.Add(catalogActions);
        Grid.SetRow(maintenance, row++); grid.Children.Add(maintenance);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 14, 0, 0) }; var ok = new Button { Content = "保存", IsDefault = true, Padding = new Thickness(14, 6, 14, 6) }; ok.Click += Save; var cancel = new Button { Content = "取消", IsCancel = true, Padding = new Thickness(14, 6, 14, 6), Margin = new Thickness(8, 0, 0, 0) }; buttons.Children.Add(ok); buttons.Children.Add(cancel); Grid.SetRow(buttons, row); grid.Children.Add(buttons);
        Content = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = grid };
        _source.ItemsSource = officials; _source.DisplayMemberPath = "Name"; _source.SelectedValuePath = "Id";
        if (profile is not null)
        {
            var settings = profile.ToSettings();
            _name.Text = profile.Name; _baseUrl.Text = profile.BaseUrl; _catalog.Text = profile.ModelCatalogJson; _mode.SelectedValue = string.IsNullOrWhiteSpace(profile.ModelCatalogMode) ? "manual" : profile.ModelCatalogMode; _source.SelectedValue = profile.ModelCatalogSourceOfficialId;
            _modelPolicy.SelectedValue = ChoiceName(settings.Model.Kind); _model.Text = settings.Model.Value ?? "";
            _contextPolicy.SelectedValue = ChoiceName(settings.ContextWindow.Kind); _context.Text = settings.ContextWindow.Value.ToString();
            _proxy.SelectedValue = settings.Proxy.Kind == SettingChoiceKind.Explicit ? (settings.Proxy.Value == ProxyPolicy.System ? "system" : "direct") : ChoiceName(settings.Proxy.Kind);
        }
        else { _mode.SelectedValue = "manual"; _modelPolicy.SelectedValue = "inherit"; _contextPolicy.SelectedValue = "inherit"; _proxy.SelectedValue = "inherit"; }
        _mode.SelectionChanged += (_, _) => { _catalog.IsEnabled = CatalogMode == "manual"; UpdateCatalogDisplay(); };
        _source.SelectionChanged += (_, _) => UpdateCatalogDisplay();
        _catalog.TextChanged += (_, _) => UpdateCatalogDisplay();
        UpdateCatalogDisplay();
    }

    private string? ResolveCatalogPath()
    {
        if (CatalogMode == "official")
        {
            var sourceId = SourceOfficialId;
            return string.IsNullOrWhiteSpace(sourceId) ? null : Path.Combine(_paths.ModelCatalogDirectory, sourceId + ".json");
        }
        var configured = CatalogPath;
        return string.IsNullOrWhiteSpace(configured)
            ? _paths.DefaultManualModelCatalogFile
            : Path.GetFullPath(Environment.ExpandEnvironmentVariables(configured));
    }

    private void UpdateCatalogDisplay()
    {
        try
        {
            var path = ResolveCatalogPath();
            _resolvedCatalogPath.Text = path ?? "请选择官方来源账号。";
            if (path is null) { _catalogStatus.Text = "跟随官方目录；来源未指定。"; return; }
            var exists = File.Exists(path);
            var sourceName = CatalogMode == "official"
                ? _officials.FirstOrDefault(official => official.Id == SourceOfficialId)?.Name ?? "来源未找到"
                : "手动维护文件";
            var updated = exists ? File.GetLastWriteTimeUtc(path).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss") : "未找到";
            var state = exists ? "目录文件可用" : "尚未配置，模型列表可能不完整";
            _catalogStatus.Text = $"维护方式：{(CatalogMode == "official" ? "跟随官方目录" : "手动维护目录")}；来源：{sourceName}；更新时间：{updated}；{state}";
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            _resolvedCatalogPath.Text = "无法解析模型目录路径。";
            _catalogStatus.Text = "请检查手动目录路径。";
        }
    }

    private void OpenCatalog(bool folder)
    {
        try
        {
            var path = ResolveCatalogPath();
            if (string.IsNullOrWhiteSpace(path)) { MessageBox.Show("请先选择官方来源账号。", Title, MessageBoxButton.OK, MessageBoxImage.Information); return; }
            if (!folder && CatalogMode == "manual")
                path = _catalogs.EnsureManualCatalogFile(new ApiProfile { ModelCatalogMode = "manual", ModelCatalogJson = CatalogPath });
            var target = folder ? Path.GetDirectoryName(path) : path;
            if (string.IsNullOrWhiteSpace(target)) return;
            if (folder) Directory.CreateDirectory(target);
            else if (!File.Exists(target)) { MessageBox.Show("当前路径还没有模型目录文件。", Title, MessageBoxButton.OK, MessageBoxImage.Information); return; }
            Process.Start(new ProcessStartInfo(folder ? "explorer.exe" : target) { UseShellExecute = true, Arguments = folder ? $"\"{target}\"" : "" });
        }
        catch (Exception ex) { MessageBox.Show("打开模型目录失败：" + ex.Message, Title, MessageBoxButton.OK, MessageBoxImage.Error); }
    }

    private UIElement CreateCatalogEditor()
    {
        var panel = new DockPanel();
        var select = new Button { Content = "选择 JSON…", MinWidth = 96, Margin = new Thickness(8, 0, 0, 0) };
        select.Click += (_, _) =>
        {
            var picker = new OpenFileDialog { Title = "选择完整 Codex 模型目录 JSON", Filter = "JSON 文件|*.json|所有文件|*.*", CheckFileExists = true };
            if (picker.ShowDialog(this) == true) _catalog.Text = picker.FileName;
        };
        DockPanel.SetDock(select, Dock.Right);
        panel.Children.Add(select);
        _catalog.Margin = new Thickness(0);
        panel.Children.Add(_catalog);
        return panel;
    }

    private void Save(object? sender, RoutedEventArgs e)
    {
        if (string.IsNullOrWhiteSpace(ProfileName) || string.IsNullOrWhiteSpace(BaseUrl)) { MessageBox.Show("名称和 HTTPS 地址不能为空。", Title); return; }
        if (_existing is null && string.IsNullOrWhiteSpace(ApiKey)) { MessageBox.Show("API Key 不能为空。", Title); return; }
        if (CatalogMode == "official" && string.IsNullOrWhiteSpace(SourceOfficialId)) { MessageBox.Show("跟随官方目录时必须选择来源账号。", Title); return; }
        DialogResult = true;
    }

    private static void AddRow(Grid grid, int row, string label, UIElement control)
    {
        var panel = new Grid { Margin = new Thickness(0, 0, 0, 10) }; panel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(130) }); panel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }); panel.Children.Add(new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center }); Grid.SetColumn(control, 1); if (control is FrameworkElement element) element.Margin = new Thickness(8, 0, 0, 0); panel.Children.Add(control); Grid.SetRow(panel, row); grid.Children.Add(panel);
    }

    private static string ChoiceName(SettingChoiceKind kind) => kind switch { SettingChoiceKind.PreserveCurrent => "preserve", SettingChoiceKind.Explicit => "explicit", _ => "inherit" };
    private static void SetupChoice(ComboBox combo, (string Value, string Text)[] options)
    {
        combo.ItemsSource = options.Select(option => new { option.Value, option.Text }).ToArray(); combo.DisplayMemberPath = "Text"; combo.SelectedValuePath = "Value";
    }
    private static StackPanel CreatePair(ComboBox choice, TextBox value)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(8, 0, 0, 0) };
        choice.Width = 145; value.Width = 250; value.Margin = new Thickness(8, 0, 0, 0); choice.Margin = new Thickness(0); panel.Children.Add(choice); panel.Children.Add(value); return panel;
    }
}

internal sealed class ProfileSettingsDialog : Window
{
    private readonly ComboBox _modelPolicy = new();
    private readonly TextBox _model = new();
    private readonly ComboBox _contextPolicy = new();
    private readonly TextBox _context = new();
    private readonly ComboBox _proxy = new();

    public ProfileSettings Settings => new(
        _modelPolicy.SelectedValue?.ToString() switch { "explicit" => SettingChoice<string>.Set(_model.Text.Trim()), "preserve" => SettingChoice<string>.Preserve(), _ => SettingChoice<string>.Inherit() },
        _contextPolicy.SelectedValue?.ToString() switch { "explicit" when int.TryParse(_context.Text, out var value) && value > 0 => SettingChoice<int>.Set(value), "preserve" => SettingChoice<int>.Preserve(), "explicit" => throw new InvalidDataException("上下文窗口必须是正整数。"), _ => SettingChoice<int>.Inherit() },
        _proxy.SelectedValue?.ToString() switch { "system" => SettingChoice<ProxyPolicy>.Set(ProxyPolicy.System), "direct" => SettingChoice<ProxyPolicy>.Set(ProxyPolicy.Direct), "preserve" => SettingChoice<ProxyPolicy>.Preserve(), _ => SettingChoice<ProxyPolicy>.Inherit() });

    public ProfileSettingsDialog(OfficialProfile profile)
    {
        Owner = Application.Current?.MainWindow; Title = "官方账号配置"; Width = 590; Height = 330; WindowStartupLocation = WindowStartupLocation.CenterOwner; ResizeMode = ResizeMode.NoResize;
        var settings = profile.ToSettings();
        var grid = new Grid { Margin = new Thickness(18) };
        for (var i = 0; i < 4; i++) grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        SetupChoice(_modelPolicy, [("inherit", "继承全局"), ("preserve", "保留当前值"), ("explicit", "指定模型")]);
        AddSettingRow(grid, 0, "模型", CreateSettingPair(_modelPolicy, _model));
        SetupChoice(_contextPolicy, [("inherit", "继承全局"), ("preserve", "保留当前值"), ("explicit", "指定窗口")]);
        AddSettingRow(grid, 1, "上下文窗口", CreateSettingPair(_contextPolicy, _context));
        SetupChoice(_proxy, [("inherit", "继承"), ("preserve", "保留当前值"), ("system", "使用系统代理"), ("direct", "直连")]);
        AddSettingRow(grid, 2, "代理策略", _proxy);
        _modelPolicy.SelectedValue = ChoiceName(settings.Model.Kind); _model.Text = settings.Model.Value ?? "";
        _contextPolicy.SelectedValue = ChoiceName(settings.ContextWindow.Kind); _context.Text = settings.ContextWindow.Value.ToString();
        _proxy.SelectedValue = settings.Proxy.Kind == SettingChoiceKind.Explicit ? (settings.Proxy.Value == ProxyPolicy.System ? "system" : "direct") : ChoiceName(settings.Proxy.Kind);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 12, 0, 0) };
        var save = new Button { Content = "保存", IsDefault = true, Padding = new Thickness(14, 6, 14, 6) };
        save.Click += (_, _) => { try { _ = Settings; DialogResult = true; } catch (Exception ex) { MessageBox.Show(ex.Message, Title, MessageBoxButton.OK, MessageBoxImage.Error); } };
        var cancel = new Button { Content = "取消", IsCancel = true, Padding = new Thickness(14, 6, 14, 6), Margin = new Thickness(8, 0, 0, 0) };
        buttons.Children.Add(save); buttons.Children.Add(cancel); Grid.SetRow(buttons, 3); grid.Children.Add(buttons);
        Content = grid;
    }

    private static void AddSettingRow(Grid grid, int row, string label, UIElement control)
    {
        var panel = new Grid { Margin = new Thickness(0, 0, 0, 12) };
        panel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(130) });
        panel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        panel.Children.Add(new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center });
        Grid.SetColumn(control, 1);
        if (control is FrameworkElement element) element.Margin = new Thickness(8, 0, 0, 0);
        panel.Children.Add(control); Grid.SetRow(panel, row); grid.Children.Add(panel);
    }

    private static void SetupChoice(ComboBox combo, (string Value, string Text)[] options)
    {
        combo.ItemsSource = options.Select(option => new { option.Value, option.Text }).ToArray(); combo.DisplayMemberPath = "Text"; combo.SelectedValuePath = "Value";
    }

    private static StackPanel CreateSettingPair(ComboBox policy, TextBox value)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(8, 0, 0, 0) };
        policy.Width = 170; value.Width = 270; value.Margin = new Thickness(8, 0, 0, 0); panel.Children.Add(policy); panel.Children.Add(value); return panel;
    }

    private static string ChoiceName(SettingChoiceKind kind) => kind switch { SettingChoiceKind.PreserveCurrent => "preserve", SettingChoiceKind.Explicit => "explicit", _ => "inherit" };
}
