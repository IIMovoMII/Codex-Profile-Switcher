using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Switcher.Core.Configuration;
using Switcher.Core.Profiles;
using Switcher.Core.Switching;
using Switcher.Core.Updates;
using Switcher.Desktop.ViewModels;
using Switcher.Infrastructure;
using Switcher.Infrastructure.Configuration;
using Switcher.Infrastructure.Switching;
using Switcher.Infrastructure.Storage;

namespace Switcher.Desktop;

public sealed partial class MainViewModel : ObservableObject
{
    private readonly ApplicationHost _host;
    private readonly DesktopPreferencesStore _preferences;
    private readonly IUpdateService _updates;
    private DesktopPreferences? _savedPreferences;
    private CancellationTokenSource? _operationCancellation;
    private UpdateInfo? _lastUpdate;
    private string? _downloadedInstaller;
    private readonly List<ProfileRowViewModel> _allProfiles = [];

    public MainViewModel(ApplicationHost host, IUpdateService? updates = null)
    {
        _host = host; _preferences = new(host.Paths); _updates = updates ?? host.Updates;
        Refresh(); ReadRecords(); LoadPreferences();
    }

    public string Version => "v" + (typeof(MainViewModel).Assembly.GetName().Version?.ToString(3) ?? "0.3.9");
    public string CodexHome => _host.Paths.CodexHome;
    public string DataDirectory => _host.Paths.DataDirectory;
    public string ManualCatalogFile => _host.Paths.DefaultManualModelCatalogFile;
    public string SnapshotsDirectory => _host.Paths.ModelCatalogDirectory;
    public string BackupsDirectory => _host.Paths.HistoryBackupsDirectory;
    public string DataDirectoryOrigin => _host.Paths.DataDirectoryOrigin;
    public string CodexHomeOrigin => _host.Paths.CodexHomeOrigin;
    public string StoragePolicy => StorageMaintenanceService.PolicyDescription;
    public Action<LocationResolution>? SelectFallbackLocations { get; set; }
    public ObservableCollection<ProfileRowViewModel> Profiles { get; } = [];
    public ObservableCollection<EnvironmentRow> EnvironmentRows { get; } = [];
    public ObservableCollection<string> Records { get; } = [];
    public IReadOnlyList<ChoiceOption> DefaultProxyChoices { get; } = [new("preserve", "保留 Codex 当前设置"), new("system", "使用系统代理"), new("direct", "直连")];
    public bool HasProfiles => Profiles.Count > 0;
    public bool HasNoProfiles => Profiles.Count == 0;
    public bool IsIdle => !IsBusy;
    public bool IsProgressIndeterminate => IsBusy && ProgressPercent == 0;
    public bool HasEditor => Editor is not null;
    public bool HasRecords => Records.Count > 0;
    public bool CanDownload => _lastUpdate is { IsNewer: true, InstallerUrl: not null, ChecksumUrl: not null } && _downloadedInstaller is null;
    public bool CanInstall => _downloadedInstaller is not null;
    public bool HasNewVersion => _lastUpdate?.IsNewer == true;
    public bool CanRepairProject { get; private set; }
    public bool CanRepairDesktop { get; private set; }
    public Func<string, string, bool> Confirm { get; set; } = (message, title) => MessageBox.Show(message, title, MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes;

    [ObservableProperty] private string currentPage = "accounts";
    [ObservableProperty] private string searchText = "";
    [ObservableProperty] private string accountFilter = "all";
    [ObservableProperty] private string currentAccount = "尚未导入当前账号";
    [ObservableProperty] private string processStatus = "尚未检查";
    [ObservableProperty] private string footerStatus = "就绪";
    [ObservableProperty] private string operationStatus = "可在账号卡片中切换账号或修改模型设置。";
    [ObservableProperty] private int progressPercent;
    [ObservableProperty] private string resultIcon = "info";
    [ObservableProperty] private bool isBusy;
    [ObservableProperty] private bool isCancelling;
    [ObservableProperty] private bool isCheckingUpdates;
    [ObservableProperty] private string environmentMessage = "点击“重新检查”读取当前运行环境。";
    [ObservableProperty] private string projectMessage = "检查聊天与项目的关联。";
    [ObservableProperty] private string desktopMessage = "检查账号界面状态与共享项目的兼容情况。";
    [ObservableProperty] private string historyMessage = "增量准备共享聊天；需要写入时会先保留备份。";
    [ObservableProperty] private string updateTitle = "检查应用更新";
    [ObservableProperty] private string updateStatus = "更新来源 GitHub Releases。";
    [ObservableProperty] private string releaseNotesTitle = "当前版本公告 · v" + ReleaseAnnouncement.CurrentVersion;
    [ObservableProperty] private string releaseNotesText = ReleaseAnnouncement.ForDisplay(ReleaseAnnouncement.CurrentMarkdown);
    [ObservableProperty] private string lastUpdateCheck = "尚未检查";
    [ObservableProperty] private string preferencesMessage = "默认策略只在账号选择“沿用默认策略”时使用。";
    [ObservableProperty] private string locationMessage = "应用自动使用默认或已找到的有效目录，无需手动填写。";
    [ObservableProperty] private bool hasUnavailableLocations;
    [ObservableProperty] private string storageMessage = "启动和业务操作结束后自动检查存储保留策略。";
    [ObservableProperty] private bool autoCheckUpdates = true;
    [ObservableProperty] private string defaultOfficialProxy = "preserve";
    [ObservableProperty] private string defaultApiProxy = "preserve";
    [ObservableProperty] private string defaultContextWindow = "";
    [ObservableProperty] private int settingsTab;
    [ObservableProperty] private ProfileEditorViewModel? editor;

    public async Task InitializeAsync()
    {
        await RefreshProcessStatusAsync();
        await RecheckDataLocationsAsync();
        await MaintainStorageAsync();
        if (AutoCheckUpdates && Environment.GetEnvironmentVariable("CODEX_SWITCHER_DISABLE_UPDATE_CHECK") != "1") await CheckUpdatesAsync();
    }

    [RelayCommand]
    private void Refresh()
    {
        try
        {
            var registry = _host.Registry.Load();
            ProfileEntry? live = null;
            try { live = _host.Service.GetLiveProfile(); CurrentAccount = live is null ? "当前身份未登记 · 可导入当前账号" : live.Name + (live is ApiProfile ? " · API" : " · 官方"); }
            catch { CurrentAccount = "当前身份暂不可确认 · 请检查环境"; }
            _allProfiles.Clear();
            foreach (var profile in registry.AllProfiles().OrderByDescending(item => item.Id == live?.Id).ThenBy(item => item.Name, StringComparer.CurrentCultureIgnoreCase))
            {
                var kind = profile is ApiProfile ? ProfileKind.Api : ProfileKind.Official;
                var source = profile is ApiProfile api ? registry.OfficialProfiles.FirstOrDefault(item => item.Id == api.ModelCatalogSourceOfficialId)?.Name : "";
                _allProfiles.Add(new(profile, kind, _host.Catalogs.GetStatus(profile, kind, source), profile.Id == live?.Id));
            }
            ApplyFilter();
        }
        catch (Exception ex) { OperationStatus = Safe("读取档案失败：" + ex.Message); }
    }

    private void ApplyFilter()
    {
        Profiles.Clear();
        foreach (var row in _allProfiles.Where(item => (AccountFilter == "all" || AccountFilter == (item.IsOfficial ? "official" : "api")) &&
                     (string.IsNullOrWhiteSpace(SearchText) || item.Name.Contains(SearchText.Trim(), StringComparison.CurrentCultureIgnoreCase) || item.Endpoint.Contains(SearchText.Trim(), StringComparison.OrdinalIgnoreCase)))) Profiles.Add(row);
        OnPropertyChanged(nameof(HasProfiles)); OnPropertyChanged(nameof(HasNoProfiles));
    }
    partial void OnSearchTextChanged(string value) => ApplyFilter();
    partial void OnAccountFilterChanged(string value) => ApplyFilter();
    partial void OnIsBusyChanged(bool value) { OnPropertyChanged(nameof(IsIdle)); OnPropertyChanged(nameof(IsProgressIndeterminate)); }
    partial void OnProgressPercentChanged(int value) => OnPropertyChanged(nameof(IsProgressIndeterminate));
    partial void OnEditorChanged(ProfileEditorViewModel? value) => OnPropertyChanged(nameof(HasEditor));

    [RelayCommand] private void Navigate(string page) => CurrentPage = page;
    [RelayCommand] private void ShowUpdates() { SettingsTab = 0; CurrentPage = "settings"; if (LastUpdateCheck == "尚未检查" && Environment.GetEnvironmentVariable("CODEX_SWITCHER_DISABLE_UPDATE_CHECK") != "1") _ = CheckUpdatesAsync(); }
    [RelayCommand] private void AddApi() => OpenEditor(null, ProfileKind.Api, 0);
    [RelayCommand] private void AddOfficial() => OpenEditor(null, ProfileKind.Official, 0);
    [RelayCommand] private void EditProfile(ProfileRowViewModel row) => OpenEditor(row.Id, row.Kind, 0);
    [RelayCommand] private void ModelSettings(ProfileRowViewModel row) => OpenEditor(row.Id, row.Kind, 1);
    private void OpenEditor(string? id, ProfileKind kind, int tab)
    {
        if (IsBusy) return;
        try { Editor = new(_host, id is null ? null : _host.Registry.Load().Find(kind, id), kind, tab); }
        catch (Exception ex) { OperationStatus = Safe("无法打开账号配置：" + ex.Message); }
    }
    [RelayCommand]
    private void CloseEditor()
    {
        if (IsBusy || Editor is null) return;
        if (Editor.HasChanges && !Confirm("放弃本次尚未保存的修改？", "关闭账号配置")) return;
        Editor.ApiKey = ""; Editor = null;
    }

    [RelayCommand]
    private async Task SaveEditorAsync()
    {
        if (Editor is null || IsBusy) return;
        var editor = Editor;
        ProfileEditRequest request;
        try { request = editor.CreateRequest(); editor.ValidationMessage = ""; }
        catch (Exception ex) { editor.ValidationMessage = Safe(ex.Message); return; }
        var saved = await RunOperationAsync("保存账号", async token =>
        {
            if (request.Kind == ProfileKind.Official && request.Id is null)
            {
                var profile = await _host.Service.AddOfficialInteractivelyAsync(request.Name, cancellationToken: token);
                await using var settingsLease = await _host.OperationLock.AcquireAsync(DataDirectory, CancellationToken.None);
                _host.Profiles.UpdateSettings(ProfileKind.Official, profile.Id, request.Settings);
                return "官方账号已保存。";
            }
            await using var lease = await _host.OperationLock.AcquireAsync(DataDirectory, token);
            token.ThrowIfCancellationRequested();
            if (request.Id is not null)
            {
                var current = _host.Registry.Load().Find(request.Kind, request.Id);
                if (JsonSerializer.Serialize(current, current.GetType()) != request.ExpectedProfile) throw new IOException("此账号已被其他窗口修改，请关闭配置面板并重新打开。未覆盖外部修改。");
            }
            if (request.Kind == ProfileKind.Api)
            {
                if (request.Id is null) _host.Profiles.AddApi(new(request.Name, request.BaseUrl, request.ApiKey, request.ManualPath, request.Settings, request.CatalogMode, request.SourceOfficialId));
                else _host.Profiles.EditApiProfile(request.Id, request.Settings, request.BaseUrl, request.CatalogMode, request.ManualPath, request.SourceOfficialId, request.ApiKey, request.Name);
            }
            else _host.Profiles.UpdateSettings(request.Kind, request.Id!, request.Settings, request.Name);
            return "账号配置已保存；下次切换或重新应用时生效。";
        });
        if (saved) { editor.ApiKey = ""; Editor = null; Refresh(); }
        else editor.ValidationMessage = OperationStatus;
    }

    [RelayCommand]
    private void OpenEditorCatalog(string target)
    {
        if (Editor is null) return;
        try { OpenLocalPath(Editor.ResolvedCatalogPath, target == "folder"); }
        catch (Exception ex) { Editor.ValidationMessage = Safe("无法打开目录：" + ex.Message); }
    }

    [RelayCommand]
    private void OpenDataLocation(string target)
    {
        var path = target switch { "home" => CodexHome, "catalogs" => SnapshotsDirectory, "backups" => BackupsDirectory, _ => DataDirectory };
        try { OpenLocalPath(path); }
        catch (Exception ex) { OperationStatus = Safe(ex.Message); }
    }
    [RelayCommand] private void OpenReleasePage() => OpenUrl(_lastUpdate?.ReleaseUrl ?? "https://github.com/IIMovoMII/Codex-Profile-Switcher/releases");
    [RelayCommand] private void CopyRecords() { try { Clipboard.SetText(string.Join(Environment.NewLine, Records)); FooterStatus = "操作记录已复制"; } catch { FooterStatus = "暂时无法访问剪贴板"; } }
    [RelayCommand] private void ReadRecords()
    {
        try { Records.Clear(); foreach (var line in _host.OperationHistory.ReadRecent().Reverse()) Records.Add(Safe(line)); OnPropertyChanged(nameof(HasRecords)); }
        catch (Exception ex) { FooterStatus = Safe("记录暂不可读：" + ex.Message); }
    }
    private void AppendLog(string text)
    {
        try { _host.OperationHistory.Append(Safe(text)); ReadRecords(); }
        catch { FooterStatus = "操作结果已显示，本地记录暂不可写"; }
    }
    private static string Safe(string value) => OperationHistoryStore.SanitizeMessage(value);
    private static void OpenUrl(string url) => Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
    private static void OpenLocalPath(string path, bool parent = false)
    {
        if (string.IsNullOrWhiteSpace(path)) throw new FileNotFoundException("尚未配置目录路径。请先保存或选择一个目录文件。");
        var full = Path.GetFullPath(path); var target = parent ? Path.GetDirectoryName(full)! : full;
        if (!File.Exists(target) && !Directory.Exists(target)) throw new FileNotFoundException("文件或文件夹尚不存在。可选择现有的完整模型目录 JSON 文件。");
        if (Directory.Exists(target)) Process.Start(new ProcessStartInfo("explorer.exe") { UseShellExecute = true, ArgumentList = { target } });
        else Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
    }
}

public sealed record EnvironmentRow(string Icon, string Label, string Status, string Detail, bool Warning = false);
public sealed class ProfileRowViewModel(ProfileEntry profile, ProfileKind kind, CatalogDisplay status, bool isCurrent = false)
{
    public string Id => profile.Id;
    public string Name => profile.Name;
    public ProfileKind Kind => kind;
    public bool IsOfficial => Kind == ProfileKind.Official;
    public bool IsCurrent => isCurrent;
    public bool IsNotCurrent => !isCurrent;
    public string KindLabel => IsOfficial ? "官方" : "API";
    public string IconKind => IsOfficial ? "user" : "layers";
    public string Endpoint => profile is ApiProfile api && Uri.TryCreate(api.BaseUrl, UriKind.Absolute, out var uri) ? uri.Authority : "";
    public string ModelSummary => profile.ToSettings().Model.Kind switch { SettingChoiceKind.Explicit => "模型：" + profile.ToSettings().Model.Value, SettingChoiceKind.PreserveCurrent => "模型：保留当前设置", _ => "模型：沿用默认策略" };
    public string Summary => string.IsNullOrWhiteSpace(Endpoint) ? ModelSummary : Endpoint + " · " + ModelSummary;
    public string CatalogMode => status.Mode;
    public string CatalogPolicy => profile is ApiProfile api ? api.ModelCatalogMode : "official-native";
    public string CatalogPath => status.Path;
    public string CatalogSource => !string.IsNullOrWhiteSpace(status.SourceName) ? status.SourceName : IsOfficial ? "Codex 原生目录" : CatalogPolicy == "official" ? "指定官方来源不可用" : "手动维护文件";
    public string CatalogUpdated => DateTimeOffset.TryParse(status.UpdatedUtc, out var time) ? time.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss") : "未找到";
    public string CatalogMessage => status.Message + (string.IsNullOrWhiteSpace(status.SourceName) ? "" : " 来源：" + status.SourceName);
}
