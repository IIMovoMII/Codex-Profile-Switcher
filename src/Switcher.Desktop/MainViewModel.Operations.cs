using System.IO;
using CommunityToolkit.Mvvm.Input;
using Switcher.Core.Updates;
using Switcher.Core.Configuration;
using Switcher.Core.Switching;

namespace Switcher.Desktop;

public sealed partial class MainViewModel
{
    [RelayCommand]
    private async Task SwitchProfileAsync(ProfileRowViewModel row)
    {
        var title = row.IsCurrent ? "重新应用账号配置" : "切换账号";
        var progress = new Progress<SwitchProgress>(ReportProgress);
        await RunOperationAsync(title, async token =>
        {
            var result = await _host.Service.SwitchAsync(row.Kind, row.Id, progress: progress, cancellationToken: token);
            return $"已应用“{result.TargetProfileName}”。请重新启动 Codex。 " + string.Join("；", result.Notices);
        });
        Refresh(); await RefreshProcessStatusAsync();
    }

    [RelayCommand]
    private async Task ImportCurrentAsync()
    {
        await RunOperationAsync("导入当前账号", async token =>
        {
            var result = await _host.Service.ImportCurrentProfileAsync(token);
            return $"已导入“{result.Name}”，当前认证与配置保持原样。";
        });
        Refresh();
    }

    [RelayCommand]
    private async Task ReauthorizeAsync(ProfileRowViewModel row)
    {
        if (!row.IsOfficial || !Confirm($"为“{row.Name}”重新打开 Codex 原生登录？请先完全退出 Codex。取消或登录失败时会恢复原状态。", "重新授权")) return;
        await RunOperationAsync("重新授权", async token => { await _host.Service.ReauthorizeOfficialAsync(row.Id, token); return "身份核验通过，最新凭据已保存。"; });
        Refresh();
    }

    [RelayCommand]
    private async Task DeleteProfileAsync(ProfileRowViewModel row)
    {
        if (!Confirm($"删除“{row.Name}”及其保存的凭据？聊天和项目不会删除。正在使用的账号需要先切换到其他账号。", "删除账号")) return;
        await RunOperationAsync("删除账号", async token =>
        {
            await using var lease = await _host.OperationLock.AcquireAsync(DataDirectory, token);
            token.ThrowIfCancellationRequested();
            _host.Profiles.Remove(row.Kind, row.Id, _host.Service.GetLiveProfile()?.Id);
            return "账号档案已删除，聊天和项目已保留。";
        });
        Refresh();
    }

    [RelayCommand]
    private async Task CheckEnvironmentAsync()
    {
        var rows = new List<EnvironmentRow>();
        var result = await RunOperationAsync("环境检查", async token =>
        {
            var available = await _host.Runtime.IsAvailableAsync(token);
            var running = await _host.Runtime.FindRunningProcessNamesAsync(token);
            var overrides = _host.Runtime.GetAuthenticationOverrides();
            var lockBusy = await IsOperationLockBusyAsync(token);
            var recovery = _host.HasPendingRecovery;
            rows.Add(new("terminal", "Codex 命令", available ? "已找到" : "尚未确认", available ? "Codex 命令可执行" : "检查安装路径；仍可维护本地档案", !available));
            rows.Add(new("layers", "Codex 进程", running.Count == 0 ? "已退出" : "仍在运行", running.Count == 0 ? "可执行账号切换" : $"发现 {running.Count} 个进程，退出后可切换账号", running.Count > 0));
            rows.Add(new("folder", "数据目录", Directory.Exists(DataDirectory) ? "可访问" : "尚未创建", DataDirectory));
            rows.Add(new("clock", "未完成操作", recovery ? "需要恢复" : "未发现", recovery ? "下一次业务操作将先执行安全恢复" : "没有待恢复的切换记录", recovery));
            rows.Add(new("settings", "操作锁", lockBusy ? "正在使用" : "可用", lockBusy ? "另一项切换器操作正在进行" : "没有其他写入操作", lockBusy));
            rows.Add(new("info", "认证覆盖", overrides.Count == 0 ? "未发现" : "需要处理", overrides.Count == 0 ? "无认证环境变量覆盖" : string.Join("、", overrides), overrides.Count > 0));
            return "环境检查完成。";
        });
        if (result)
        {
            EnvironmentRows.Clear(); foreach (var row in rows) EnvironmentRows.Add(row);
            ProcessStatus = rows.First(item => item.Label == "Codex 进程").Status;
            EnvironmentMessage = rows.Any(item => item.Warning) ? "部分检查需要处理；请查看上方状态与说明。" : "环境检查完成，可使用账号管理和维护工具。";
        }
    }

    [RelayCommand] private Task PrepareHistoryAsync() => PrepareHistoryCoreAsync(false);
    [RelayCommand] private Task FullHistoryAsync() => PrepareHistoryCoreAsync(true);
    private async Task PrepareHistoryCoreAsync(bool full)
    {
        if (!Confirm("将检查并整理共享聊天的兼容信息，必要时写入历史文件与数据库，并保留恢复备份。请先退出 Codex。继续？", full ? "完整历史检查与准备" : "增量历史准备")) return;
        var progress = new Progress<SwitchProgress>(ReportProgress);
        await RunOperationAsync(full ? "完整历史检查与准备" : "增量历史准备", async token =>
        {
            var result = await _host.Service.PrepareHistoryAsync(full, progress, token);
            if (!result.Prepared) throw new InvalidOperationException(result.Message);
            return result.Message;
        });
        HistoryMessage = OperationStatus;
    }

    [RelayCommand] private Task ProjectScanAsync() => RunProjectAsync(false);
    [RelayCommand] private Task ProjectRepairAsync() => RunProjectAsync(true);
    private async Task RunProjectAsync(bool repair)
    {
        if (repair && !Confirm("修复聊天与项目的关联，并保留对应备份。请先退出 Codex。继续？", "修复项目归属")) return;
        var progress = new Progress<SwitchProgress>(ReportProgress);
        var success = await RunOperationAsync(repair ? "项目归属修复" : "项目归属检查", async token => (await _host.Service.PrepareProjectProjectionAsync(repair, false, progress, token)).Message);
        ProjectMessage = OperationStatus;
        CanRepairProject = success && !repair; OnPropertyChanged(nameof(CanRepairProject));
    }

    [RelayCommand] private Task DesktopScanAsync() => RunDesktopAsync(false);
    [RelayCommand] private Task DesktopRepairAsync() => RunDesktopAsync(true);
    private async Task RunDesktopAsync(bool repair)
    {
        if (repair && !Confirm("整理当前账号的桌面状态与共享项目关联，并保留恢复材料。请先退出 Codex。继续？", "修复桌面兼容状态")) return;
        var success = await RunOperationAsync(repair ? "桌面兼容修复" : "桌面兼容检查", async token => (await _host.Service.PrepareDesktopStateAsync(repair, token)).Message);
        DesktopMessage = OperationStatus;
        CanRepairDesktop = success && !repair; OnPropertyChanged(nameof(CanRepairDesktop));
    }

    [RelayCommand]
    private async Task CheckUpdatesAsync()
    {
        if (IsCheckingUpdates) return;
        IsCheckingUpdates = true; UpdateTitle = "正在检查更新"; UpdateStatus = "正在连接 GitHub Releases…";
        try
        {
            _lastUpdate = await _updates.CheckAsync(); _downloadedInstaller = null;
            UpdateTitle = _lastUpdate.IsNewer ? "发现新版本 · " + _lastUpdate.LatestVersion : "更新检查完成";
            if (System.Version.TryParse(_lastUpdate.LatestVersion, out var announced) &&
                System.Version.TryParse(ReleaseAnnouncement.CurrentVersion, out var installed) && announced >= installed &&
                !string.IsNullOrWhiteSpace(ReleaseAnnouncement.Normalize(_lastUpdate.ReleaseNotes)))
            {
                ReleaseNotesTitle = (_lastUpdate.IsNewer ? "新版本公告 · v" : "当前版本公告 · v") + _lastUpdate.LatestVersion;
                ReleaseNotesText = ReleaseAnnouncement.ForDisplay(_lastUpdate.ReleaseNotes);
            }
            UpdateStatus = _lastUpdate.Message + " · 更新来源 GitHub Releases";
            LastUpdateCheck = DateTime.Now.ToString("MM-dd HH:mm");
        }
        catch (Exception ex) { UpdateTitle = "更新检查暂未完成"; UpdateStatus = Safe(ex.Message) + " 可点击“重新检查”重试。"; AppendLog("更新检查失败：" + UpdateStatus); }
        finally { IsCheckingUpdates = false; NotifyUpdateActions(); }
    }

    [RelayCommand]
    private async Task DownloadUpdateAsync()
    {
        if (!CanDownload || _lastUpdate is null || IsBusy) return;
        var info = _lastUpdate;
        if (!Confirm($"从 GitHub 下载 {info.LatestVersion} 并校验 SHA-256？下载完成后可另行选择安装。", "下载更新")) return;
        var progress = new Progress<SwitchProgress>(ReportProgress);
        string? installer = null;
        var success = await RunOperationAsync("下载更新", async token =>
        {
            installer = await _updates.DownloadAndVerifyAsync(info, Path.Combine(DataDirectory, "updates"), progress, token);
            _downloadedInstaller = installer;
            return "安装包已下载，SHA-256 校验通过。点击“安装更新”后启动安装程序。";
        });
        if (success) { _downloadedInstaller = installer; UpdateStatus = OperationStatus; }
        NotifyUpdateActions();
    }
    [RelayCommand]
    private async Task InstallUpdateAsync()
    {
        if (_downloadedInstaller is null || !Confirm("安装包已经过校验。现在启动安装程序？", "安装更新")) return;
        var installer = _downloadedInstaller;
        await RunOperationAsync("启动安装程序", async token => { await _updates.LaunchInstallerAsync(installer, token); return "已打开安装程序，请按安装向导完成更新。"; });
    }
    private void NotifyUpdateActions() { OnPropertyChanged(nameof(CanDownload)); OnPropertyChanged(nameof(CanInstall)); OnPropertyChanged(nameof(HasNewVersion)); }

    [RelayCommand]
    private void LoadPreferences()
    {
        try
        {
            _savedPreferences = _preferences.Load();
            AutoCheckUpdates = _savedPreferences.CheckUpdatesOnStartup;
            DefaultOfficialProxy = _savedPreferences.OfficialProxy.ToString().ToLowerInvariant();
            DefaultApiProxy = _savedPreferences.ApiProxy.ToString().ToLowerInvariant();
            DefaultContextWindow = _savedPreferences.ContextWindow;
            PreferencesMessage = "默认策略只在账号选择“沿用默认策略”时使用。";
        }
        catch (Exception ex) { PreferencesMessage = Safe("设置读取失败，未覆盖原文件：" + ex.Message); }
    }
    [RelayCommand]
    private void SavePreferences()
    {
        if (_savedPreferences is null) { PreferencesMessage = "请先重新读取设置，解决文件格式问题后再保存。"; return; }
        try
        {
            ProxyPolicy Policy(string value) => value switch { "system" => ProxyPolicy.System, "direct" => ProxyPolicy.Direct, _ => ProxyPolicy.Preserve };
            _savedPreferences = _preferences.Save(new(AutoCheckUpdates, Policy(DefaultOfficialProxy), Policy(DefaultApiProxy), DefaultContextWindow, _savedPreferences.Revision));
            PreferencesMessage = "默认策略已保存；下次切换或重新应用时使用。";
        }
        catch (Exception ex) { PreferencesMessage = Safe("保存失败：" + ex.Message); }
    }
    [RelayCommand]
    private void SaveAutoCheck()
    {
        if (_savedPreferences is null) { AutoCheckUpdates = true; return; }
        try { _savedPreferences = _preferences.Save(_savedPreferences with { CheckUpdatesOnStartup = AutoCheckUpdates }); }
        catch (Exception ex) { AutoCheckUpdates = _savedPreferences.CheckUpdatesOnStartup; UpdateStatus = Safe("更新偏好未保存：" + ex.Message); }
    }

    private async Task<bool> RunOperationAsync(string title, Func<CancellationToken, Task<string>> operation)
    {
        if (IsBusy) return false;
        IsBusy = true; IsCancelling = false; ProgressPercent = 0; ResultIcon = "refresh"; OperationStatus = title + "…";
        using var cancellation = new CancellationTokenSource(); _operationCancellation = cancellation;
        try
        {
            var message = await Task.Run(() => operation(cancellation.Token));
            OperationStatus = Safe(message); ProgressPercent = 100; ResultIcon = "success"; AppendLog(title + "：" + OperationStatus);
            FooterStatus = title + "完成 · " + DateTime.Now.ToString("HH:mm"); return true;
        }
        catch (OperationCanceledException) { ResultIcon = "info"; OperationStatus = title + "已取消；安全收尾或恢复已结束。"; AppendLog(OperationStatus); return false; }
        catch (Exception ex) { ResultIcon = "warning"; OperationStatus = Safe(title + "失败：" + ex.Message); AppendLog(OperationStatus); return false; }
        finally { _operationCancellation = null; await MaintainStorageAsync(); IsBusy = false; IsCancelling = false; }
    }
    private void ReportProgress(SwitchProgress value) { ProgressPercent = value.Percent ?? ProgressPercent; OperationStatus = Safe(value.Stage + "：" + value.Message); }
    [RelayCommand] private void CancelOperation() { if (_operationCancellation is null) return; IsCancelling = true; OperationStatus = "正在取消，等待安全收尾…"; _operationCancellation.Cancel(); }
    private async Task RefreshProcessStatusAsync()
    {
        try { var running = await _host.Runtime.FindRunningProcessNamesAsync(CancellationToken.None); ProcessStatus = running.Count == 0 ? "已退出" : "运行中"; }
        catch { ProcessStatus = "暂不可确认"; }
    }
    private async Task<bool> IsOperationLockBusyAsync(CancellationToken token)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromMilliseconds(150));
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(token, timeout.Token);
        try { await using var lease = await _host.OperationLock.AcquireAsync(DataDirectory, linked.Token); return false; }
        catch (OperationCanceledException) when (!token.IsCancellationRequested) { return true; }
    }

    [RelayCommand]
    private async Task RecheckDataLocationsAsync()
    {
        var resolution = await Task.Run(() => new Infrastructure.Configuration.DataLocationResolver().Verify(_host.Paths));
        LocationMessage = resolution.Message; HasUnavailableLocations = !resolution.IsValid;
    }

    [RelayCommand]
    private void SelectFallbackFolder()
    {
        var resolution = new Infrastructure.Configuration.DataLocationResolver().Verify(_host.Paths);
        LocationMessage = resolution.Message; HasUnavailableLocations = !resolution.IsValid;
        if (DataDirectoryOrigin.StartsWith("启动参数", StringComparison.Ordinal) || CodexHomeOrigin.StartsWith("启动参数", StringComparison.Ordinal))
        { LocationMessage += " 当前路径由启动参数指定，请修正参数后重新启动；不会回退到其他目录。"; return; }
        if (!resolution.IsValid && !IsBusy) SelectFallbackLocations?.Invoke(resolution);
    }

    [RelayCommand]
    private async Task MaintainStorageAsync()
    {
        var result = await _host.Storage.TryMaintainAsync(_downloadedInstaller);
        StorageMessage = result?.Message ?? "其他操作正在使用存储或部分文件不可访问，将在下次自动检查。";
    }
}
