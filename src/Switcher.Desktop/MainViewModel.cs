using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Windows;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.Win32;
using Switcher.Core.Configuration;
using Switcher.Core.Paths;
using Switcher.Core.Profiles;
using Switcher.Core.Switching;
using Switcher.Core.Updates;
using Switcher.Infrastructure;

namespace Switcher.Desktop;

public sealed partial class MainViewModel : ObservableObject
{
    private readonly ApplicationHost _host;
    private UpdateInfo? _lastUpdate;
    private CancellationTokenSource? _operationCancellation;
    private bool _busy;

    public MainViewModel(ApplicationHost host)
    {
        _host = host;
        Profiles = [];
        Refresh();
        try { LogText = string.Join(Environment.NewLine, _host.OperationHistory.ReadRecent()); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Text.DecoderFallbackException) { LogText = "本地操作记录无法读取。"; }
        if (!string.Equals(Environment.GetEnvironmentVariable("CODEX_SWITCHER_DISABLE_UPDATE_CHECK"), "1", StringComparison.Ordinal))
            _ = CheckUpdatesAsync();
    }

    public ObservableCollection<ProfileRowViewModel> Profiles { get; }
    [ObservableProperty] private ProfileRowViewModel? selectedProfile;
    [ObservableProperty] private string currentMode = "未设置";
    [ObservableProperty] private string dataLocation = "";
    [ObservableProperty] private string environmentSummary = "尚未检查。";
    [ObservableProperty] private string operationStatus = "";
    [ObservableProperty] private string updateStatus = "启动时正在检查 GitHub 更新……";
    [ObservableProperty] private string footerStatus = "就绪";
    [ObservableProperty] private string logText = "";
    [ObservableProperty] private int progressPercent;
    [ObservableProperty] private bool isBusy;

    public Func<Task>? AddApiRequested { get; set; }
    public Func<Task>? ImportOfficialRequested { get; set; }
    public Func<ProfileRowViewModel, Task>? ReauthorizeRequested { get; set; }
    public Func<ProfileRowViewModel, Task>? EditRequested { get; set; }
    public Func<ProfileRowViewModel, Task>? RenameRequested { get; set; }

    public string SelectedCatalogPath => SelectedProfile?.CatalogPath ?? "";
    public string SelectedCatalogSource => SelectedProfile?.CatalogSource ?? "";
    public string SelectedCatalogUpdated => SelectedProfile?.CatalogUpdated ?? "";
    public string SelectedCatalogMessage => SelectedProfile?.CatalogMessage ?? "";

    [RelayCommand]
    private void Refresh()
    {
        try
        {
            var selectedId = SelectedProfile?.Id;
            var registry = _host.Registry.Load();
            Profiles.Clear();
            foreach (var profile in _host.Service.ListProfiles())
            {
                var kind = profile is ApiProfile ? ProfileKind.Api : ProfileKind.Official;
                var sourceName = profile is ApiProfile api && api.ModelCatalogMode == "official"
                    ? registry.OfficialProfiles.FirstOrDefault(item => item.Id == api.ModelCatalogSourceOfficialId)?.Name ?? "来源未找到"
                    : "";
                var status = _host.Catalogs.GetStatus(profile, kind, sourceName);
                Profiles.Add(new ProfileRowViewModel(profile, kind, status));
            }
            CurrentMode = _host.Service.GetLiveMode();
            DataLocation = $"CODEX_HOME：{_host.Paths.CodexHome}    数据：{_host.Paths.DataDirectory}";
            FooterStatus = $"{Profiles.Count} 个档案";
            SelectedProfile = Profiles.FirstOrDefault(profile => profile.Id == selectedId) ?? Profiles.FirstOrDefault();
        }
        catch (Exception ex) { OperationStatus = "读取档案失败：" + ex.Message; }
    }

    [RelayCommand]
    private async Task SwitchSelectedAsync()
    {
        if (SelectedProfile is null) { OperationStatus = "请先选择一个账号档案。"; return; }
        await RunOperationAsync("切换账号", async token =>
        {
            var progress = new Progress<SwitchProgress>(ReportProgress);
            var result = await _host.Service.SwitchAsync(SelectedProfile.Kind, SelectedProfile.Id, false, false, progress, token).ConfigureAwait(true);
            AppendLog(result.Notices.Count == 0 ? "账号切换完成。" : string.Join(Environment.NewLine, result.Notices));
        }).ConfigureAwait(true);
        Refresh();
    }

    [RelayCommand]
    private async Task ImportCurrentAsync()
    {
        await RunOperationAsync("导入当前账号", async token =>
        {
            token.ThrowIfCancellationRequested();
            var profile = await _host.Service.ImportCurrentProfileAsync(token).ConfigureAwait(true);
            AppendLog($"已导入当前{(profile is ApiProfile ? "API" : "官方")}档案：{profile.Name}。原文件未修改。 ");
        }).ConfigureAwait(true);
        Refresh();
    }

    [RelayCommand]
    private async Task AddApiAsync() { if (AddApiRequested is not null) await AddApiRequested().ConfigureAwait(true); Refresh(); }
    [RelayCommand]
    private async Task ImportOfficialAsync() { if (ImportOfficialRequested is not null) await ImportOfficialRequested().ConfigureAwait(true); Refresh(); }
    private bool CanReauthorizeSelected() => SelectedProfile?.Kind == ProfileKind.Official;

    [RelayCommand(CanExecute = nameof(CanReauthorizeSelected))]
    private async Task ReauthorizeSelectedAsync() { if (SelectedProfile is not null && ReauthorizeRequested is not null) await ReauthorizeRequested(SelectedProfile).ConfigureAwait(true); Refresh(); }
    [RelayCommand]
    private async Task EditSelectedAsync() { if (SelectedProfile is not null && EditRequested is not null) await EditRequested(SelectedProfile).ConfigureAwait(true); Refresh(); }
    [RelayCommand]
    private async Task RenameSelectedAsync() { if (SelectedProfile is not null && RenameRequested is not null) await RenameRequested(SelectedProfile).ConfigureAwait(true); Refresh(); }

    [RelayCommand]
    private void DeleteSelected()
    {
        if (SelectedProfile is null) return;
        var answer = MessageBox.Show($"确认删除档案“{SelectedProfile.Name}”？已保存的凭据文件也会删除。", "删除档案", MessageBoxButton.YesNo, MessageBoxImage.Warning);
        if (answer != MessageBoxResult.Yes) return;
        try
        {
            _host.Profiles.Remove(SelectedProfile.Kind, SelectedProfile.Id, CurrentMode == SelectedProfile.Kind.ToLegacyValue() ? FindActiveId(SelectedProfile.Kind) : null);
            Refresh();
        }
        catch (Exception ex) { OperationStatus = "删除失败：" + ex.Message; }
    }

    [RelayCommand]
    private void OpenCatalog()
    {
        if (SelectedProfile is null) return;
        try { OpenPath(EnsureOpenableCatalog(SelectedProfile), false); }
        catch (Exception ex) { OperationStatus = "打开模型目录失败：" + ex.Message; }
    }
    [RelayCommand]
    private void OpenCatalogFolder()
    {
        if (SelectedProfile is null) return;
        try { OpenPath(EnsureOpenableCatalog(SelectedProfile), true); }
        catch (Exception ex) { OperationStatus = "打开模型目录文件夹失败：" + ex.Message; }
    }
    [RelayCommand]
    private void OpenReleasePage() => OpenUrl(_lastUpdate?.ReleaseUrl ?? "https://github.com/IIMovoMII/Codex-Profile-Switcher/releases");

    [RelayCommand]
    private async Task CheckEnvironmentAsync()
    {
        await RunOperationAsync("环境检查", async token =>
        {
            var available = await _host.Runtime.IsAvailableAsync(token).ConfigureAwait(true);
            var running = await _host.Runtime.FindRunningProcessNamesAsync(token).ConfigureAwait(true);
            var overrides = _host.Runtime.GetAuthenticationOverrides();
            var lockBusy = await IsOperationLockBusyAsync(token).ConfigureAwait(true);
            var recoveryPending = _host.HasPendingRecovery;
            EnvironmentSummary = $"CODEX_HOME：{_host.Paths.CodexHome}{Environment.NewLine}" +
                $"数据目录：{_host.Paths.DataDirectory}{Environment.NewLine}" +
                $"Codex 命令：{(available ? "可用" : "未确认（可继续维护档案）")}{Environment.NewLine}" +
                $"运行中的 Codex 进程：{(running.Count == 0 ? "未发现" : string.Join(", ", running))}{Environment.NewLine}" +
                $"切换互斥锁：{(lockBusy ? "正在使用" : "可用")}{Environment.NewLine}" +
                $"待恢复操作记录：{(recoveryPending ? "存在，下一次业务操作会先尝试恢复" : "未发现")}{Environment.NewLine}" +
                $"认证环境变量覆盖：{(overrides.Count == 0 ? "未发现" : string.Join(", ", overrides))}";
            OperationStatus = "环境检查完成。";
            AppendLog($"环境检查完成：Codex {(available ? "可用" : "未确认")}，运行进程 {running.Count} 个，互斥锁 {(lockBusy ? "占用" : "可用")}，恢复记录 {(recoveryPending ? "存在" : "无")}。");
        }).ConfigureAwait(true);
    }

    [RelayCommand]
    private Task PrepareHistoryAsync() => PrepareHistoryCoreAsync(false);
    [RelayCommand]
    private Task FullHistoryAsync() => PrepareHistoryCoreAsync(true);

    [RelayCommand]
    private Task ProjectScanAsync() => RunProjectProjectionAsync(false);

    [RelayCommand]
    private Task ProjectRepairAsync() => RunProjectProjectionAsync(true);

    [RelayCommand]
    private async Task CheckUpdatesAsync()
    {
        try
        {
            _lastUpdate = await _host.Updates.CheckAsync().ConfigureAwait(true);
            UpdateStatus = _lastUpdate.Message + (_lastUpdate.IsNewer ? " 可打开发行页查看安装包。" : "");
        }
        catch (Exception ex) { UpdateStatus = "更新检查失败：" + ex.Message; }
    }

    [RelayCommand]
    private async Task DownloadAndInstallUpdateAsync()
    {
        if (_lastUpdate is null || !_lastUpdate.IsNewer) { OperationStatus = "当前没有可安装的新版本。"; return; }
        if (string.IsNullOrWhiteSpace(_lastUpdate.InstallerUrl) || string.IsNullOrWhiteSpace(_lastUpdate.ChecksumUrl))
        {
            MessageBox.Show("GitHub Release 缺少安装包或 SHA-256 清单。请打开项目发行页查看。", "无法安装更新", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }
        if (MessageBox.Show($"下载并校验版本 {_lastUpdate.LatestVersion} 的安装包？", "更新 Codex Profile Switcher", MessageBoxButton.YesNo, MessageBoxImage.Question) != MessageBoxResult.Yes) return;
        try
        {
            var folder = Path.Combine(Path.GetTempPath(), "CodexProfileSwitcher-Updates");
            var installer = await _host.Updates.DownloadAndVerifyAsync(_lastUpdate, folder, new Progress<SwitchProgress>(ReportProgress)).ConfigureAwait(true);
            if (MessageBox.Show("安装包 SHA-256 校验通过。现在启动安装程序？", "更新已准备", MessageBoxButton.YesNo, MessageBoxImage.Information) == MessageBoxResult.Yes)
                await _host.Updates.LaunchInstallerAsync(installer).ConfigureAwait(true);
        }
        catch (Exception ex) { UpdateStatus = "更新下载失败：" + ex.Message; }
    }

    private async Task PrepareHistoryCoreAsync(bool full)
    {
        await RunOperationAsync(full ? "完整历史扫描" : "历史兼容准备", async token =>
        {
            var result = await _host.Service.PrepareHistoryAsync(full, new Progress<SwitchProgress>(ReportProgress), token).ConfigureAwait(true);
            AppendLog(result.Message);
        }).ConfigureAwait(true);
    }

    private async Task RunProjectProjectionAsync(bool repair)
    {
        await RunOperationAsync(repair ? "项目归属修复" : "项目归属检查", async token =>
        {
            var result = await _host.Service.PrepareProjectProjectionAsync(repair, false, new Progress<SwitchProgress>(ReportProgress), token).ConfigureAwait(true);
            AppendLog(result.Message);
        }).ConfigureAwait(true);
    }

    private async Task RunOperationAsync(string title, Func<CancellationToken, Task> operation)
    {
        if (_busy) { OperationStatus = "已有操作正在进行。"; return; }
        _busy = true; IsBusy = true; ProgressPercent = 0; OperationStatus = title + "……";
        using var cancellation = new CancellationTokenSource();
        _operationCancellation = cancellation;
        try { await Task.Run(() => operation(cancellation.Token), cancellation.Token).ConfigureAwait(true); OperationStatus = title + "完成。"; }
        catch (OperationCanceledException) { OperationStatus = title + "已取消；必要的恢复步骤已完成。"; AppendLog(OperationStatus); }
        catch (Exception ex) { OperationStatus = title + "失败：" + ex.Message; AppendLog(OperationStatus); }
        finally { _operationCancellation = null; _busy = false; IsBusy = false; }
    }

    [RelayCommand]
    private void CancelOperation() => _operationCancellation?.Cancel();

    partial void OnSelectedProfileChanged(ProfileRowViewModel? value)
    {
        ReauthorizeSelectedCommand.NotifyCanExecuteChanged();
        OnPropertyChanged(nameof(SelectedCatalogPath));
        OnPropertyChanged(nameof(SelectedCatalogSource));
        OnPropertyChanged(nameof(SelectedCatalogUpdated));
        OnPropertyChanged(nameof(SelectedCatalogMessage));
    }

    private void ReportProgress(SwitchProgress value) { ProgressPercent = value.Percent ?? ProgressPercent; OperationStatus = value.Stage + "：" + value.Message; AppendLog(OperationStatus); }
    private void AppendLog(string value)
    {
        var display = value.Replace('\r', ' ').Replace('\n', ' ');
        try { _host.OperationHistory.Append(display); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Text.DecoderFallbackException) { FooterStatus = "本地操作记录不可写"; }
        var entries = string.IsNullOrWhiteSpace(LogText) ? Array.Empty<string>() : LogText.Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries).TakeLast(199).ToArray();
        LogText = string.Join(Environment.NewLine, entries.Append(display));
    }

    private async Task<bool> IsOperationLockBusyAsync(CancellationToken cancellationToken)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromMilliseconds(150));
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, timeout.Token);
        try
        {
            await using var lease = await _host.OperationLock.AcquireAsync(_host.Paths.DataDirectory, linked.Token).ConfigureAwait(true);
            return false;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested) { return true; }
    }

    private string? FindActiveId(ProfileKind kind) { var registry = _host.Registry.Load(); return kind == ProfileKind.Api ? registry.ActiveApiProfileId : registry.ActiveOfficialProfileId; }

    private string EnsureOpenableCatalog(ProfileRowViewModel row)
    {
        if (row.Kind != ProfileKind.Api) return _host.Service.ResolveModelCatalogPath(row.Kind, row.Id);
        var profile = (ApiProfile)_host.Registry.Load().Find(ProfileKind.Api, row.Id);
        return profile.ModelCatalogMode == "official"
            ? _host.Service.ResolveModelCatalogPath(ProfileKind.Api, row.Id)
            : _host.Service.EnsureManualModelCatalogFile(row.Id);
    }

    private static void OpenPath(string? path, bool folder)
    {
        if (string.IsNullOrWhiteSpace(path)) return;
        var target = folder ? Path.GetDirectoryName(path) : path;
        if (string.IsNullOrWhiteSpace(target)) return;
        if (!File.Exists(target) && !Directory.Exists(target)) { MessageBox.Show("文件或文件夹尚不存在。", "模型目录", MessageBoxButton.OK, MessageBoxImage.Information); return; }
        Process.Start(new ProcessStartInfo(folder ? "explorer.exe" : target) { UseShellExecute = true, Arguments = folder ? $"\"{target}\"" : "" });
    }
    private static void OpenUrl(string url) => Process.Start(new ProcessStartInfo(url) { UseShellExecute = true });
}

public sealed class ProfileRowViewModel(ProfileEntry profile, ProfileKind kind, CatalogDisplay status)
{
    public string Id => profile.Id;
    public string Name => profile.Name;
    public ProfileKind Kind => kind;
    public string KindLabel => kind == ProfileKind.Api ? "API" : "官方";
    public string CatalogMode => status.Mode;
    public string CatalogPolicy => profile is ApiProfile api ? api.ModelCatalogMode : "official-native";
    public string CatalogPath => status.Path;
    public string CatalogSource => !string.IsNullOrWhiteSpace(status.SourceName) ? status.SourceName :
        kind == ProfileKind.Official ? "Codex 原生目录" : CatalogPolicy == "official" ? "指定官方来源不可用" : "手动维护文件";
    public string CatalogUpdated => DateTimeOffset.TryParse(status.UpdatedUtc, out var updated)
        ? updated.ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss") : "未找到";
    public string CatalogMessage => status.Message + (string.IsNullOrWhiteSpace(status.SourceName) ? "" : $" 来源：{status.SourceName}");
    public string Summary => kind == ProfileKind.Api ? $"中转地址：{((ApiProfile)profile).BaseUrl}" : $"账号标识：{((OfficialProfile)profile).Owner[..Math.Min(12, ((OfficialProfile)profile).Owner.Length)]}……";
}
