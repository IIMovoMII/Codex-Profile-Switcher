using System.Collections.ObjectModel;
using System.IO;
using System.Text.Json;
using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using Microsoft.Win32;
using Switcher.Core.Configuration;
using Switcher.Core.Profiles;
using Switcher.Infrastructure;
using Switcher.Infrastructure.Models;

namespace Switcher.Desktop.ViewModels;

public sealed record ChoiceOption(string Id, string Label);
public sealed record ProfileEditRequest(string? Id, ProfileKind Kind, string Name, string BaseUrl, string ApiKey,
    ProfileSettings Settings, string ManualPath, string CatalogMode, string SourceOfficialId, string? ExpectedProfile);

public sealed partial class ProfileEditorViewModel : ObservableObject
{
    private readonly ApplicationHost _host;
    private readonly ProfileEntry? _original;
    private readonly string _initialState;
    private int _catalogGeneration;
    public ProfileEditorViewModel(ApplicationHost host, ProfileEntry? original, ProfileKind kind, int tab = 0)
    {
        _host = host; _original = original; Kind = kind;
        Officials = host.Registry.Load().OfficialProfiles;
        var settings = original?.ToSettings() ?? ProfileSettings.Unspecified;
        profileName = original?.Name ?? "";
        baseUrl = original is ApiProfile api ? api.BaseUrl : "";
        modelPolicy = PolicyName(settings.Model.Kind); modelId = settings.Model.Value ?? "";
        contextPolicy = PolicyName(settings.ContextWindow.Kind); contextWindow = settings.ContextWindow.Kind == SettingChoiceKind.Explicit ? settings.ContextWindow.Value.ToString() : "";
        proxyPolicy = settings.Proxy.Kind == SettingChoiceKind.Explicit ? settings.Proxy.Value.ToString().ToLowerInvariant() : PolicyName(settings.Proxy.Kind);
        manualPath = original is ApiProfile manual ? manual.ModelCatalogJson : "";
        catalogMode = original is ApiProfile catalog && catalog.ModelCatalogMode == "official" ? "official" : "manual";
        sourceOfficialId = original is ApiProfile source ? source.ModelCatalogSourceOfficialId : "";
        selectedTab = tab;
        ExpectedProfile = original is null ? null : JsonSerializer.Serialize(original, original.GetType());
        _initialState = StateSignature();
        _ = RefreshCatalogAsync();
    }

    public ProfileKind Kind { get; }
    public bool IsApi => Kind == ProfileKind.Api;
    public bool IsOfficial => !IsApi;
    public bool IsNew => _original is null;
    public bool IsExistingOfficial => IsOfficial && !IsNew;
    public string? ProfileId => _original?.Id;
    public string? ExpectedProfile { get; }
    public string Title => IsNew ? IsApi ? "添加 API 账号" : "添加官方账号" : ProfileName;
    public string Subtitle => IsNew ? IsApi ? "保存一个独立的 API 连接，稍后可在账号列表中切换。" : "使用 Codex 原生登录流程，保存独立账号。" : "账号配置单独保存，应用后生效。";
    public string IconKind => IsApi ? "layers" : "user";
    public string SaveLabel => IsNew ? IsApi ? "保存账号" : "登录并保存" : "保存设置";
    public string KeyLabel => IsNew ? "API Key" : "替换 API Key（留空保留原密钥）";
    public string SaveHint => IsNew ? IsApi ? "保存后可在账号列表中切换。" : "首次设置时会初始化官方账号；已有账号时仅保存档案。" : "下次切换或重新应用到此账号时生效。";
    public string OfficialIdentity => _original is OfficialProfile profile ? $"本地身份已登记 · {profile.Owner[..Math.Min(10, profile.Owner.Length)]}…" : "点击“登录并保存”后打开 Codex 原生登录。取消或失败时恢复原状态。";
    public bool HasChanges => StateSignature() != _initialState;
    public bool CanSpecifyModel => ModelPolicy == "explicit";
    public bool CanSpecifyContext => ContextPolicy == "explicit";
    public IReadOnlyList<OfficialProfile> Officials { get; }
    public bool HasNoOfficials => Officials.Count == 0;
    public ObservableCollection<CatalogModelChoice> Models { get; } = [];
    public IReadOnlyList<ChoiceOption> ContextChoices { get; } = [new("preserve", "保留 Codex 当前设置"), new("inherit", "沿用默认策略"), new("explicit", "为此账号指定窗口")];
    public IReadOnlyList<ChoiceOption> ProxyChoices { get; } = [new("preserve", "保留 Codex 当前设置"), new("inherit", "沿用默认策略"), new("system", "使用系统代理"), new("direct", "直连")];
    [ObservableProperty] private string profileName;
    [ObservableProperty] private string baseUrl;
    [ObservableProperty] private string apiKey = "";
    [ObservableProperty] private string modelPolicy;
    [ObservableProperty] private string modelId;
    [ObservableProperty] private string contextPolicy;
    [ObservableProperty] private string contextWindow;
    [ObservableProperty] private string proxyPolicy;
    [ObservableProperty] private string manualPath;
    [ObservableProperty] private string catalogMode;
    [ObservableProperty] private string sourceOfficialId;
    [ObservableProperty] private int selectedTab;
    [ObservableProperty] private string resolvedCatalogPath = "";
    [ObservableProperty] private string catalogSource = "手动维护文件";
    [ObservableProperty] private string catalogUpdated = "尚未保存目录";
    [ObservableProperty] private string catalogStatus = "正在读取本地目录…";
    [ObservableProperty] private string validationMessage = "";
    [ObservableProperty] private bool catalogExists;
    [ObservableProperty] private bool isCatalogLoading;

    public ProfileEditRequest CreateRequest()
    {
        if (!(IsNew && IsOfficial) && string.IsNullOrWhiteSpace(ProfileName)) throw new InvalidDataException("请填写账号名称。");
        if (IsApi) ProfileRegistry.ValidateRelayBaseUrl(BaseUrl.Trim());
        if (IsNew && IsApi && string.IsNullOrWhiteSpace(ApiKey)) throw new InvalidDataException("请填写 API Key。");
        if (ModelPolicy == "explicit" && string.IsNullOrWhiteSpace(ModelId)) throw new InvalidDataException("请填写模型 ID。");
        if (ContextPolicy == "explicit" && (!int.TryParse(ContextWindow, out var parsed) || parsed <= 0)) throw new InvalidDataException("上下文窗口必须是正整数。");
        if (IsApi && CatalogMode == "official" && !Officials.Any(item => item.Id == SourceOfficialId)) throw new InvalidDataException("请选择一个已登记的官方目录来源。");
        var settings = new ProfileSettings(
            ModelPolicy switch { "explicit" => SettingChoice<string>.Set(ModelId.Trim()), "preserve" => SettingChoice<string>.Preserve(), _ => SettingChoice<string>.Inherit() },
            ContextPolicy switch { "explicit" => SettingChoice<int>.Set(int.Parse(ContextWindow)), "preserve" => SettingChoice<int>.Preserve(), _ => SettingChoice<int>.Inherit() },
            ProxyPolicy switch { "system" => SettingChoice<Switcher.Core.Configuration.ProxyPolicy>.Set(Switcher.Core.Configuration.ProxyPolicy.System), "direct" => SettingChoice<Switcher.Core.Configuration.ProxyPolicy>.Set(Switcher.Core.Configuration.ProxyPolicy.Direct), "preserve" => SettingChoice<Switcher.Core.Configuration.ProxyPolicy>.Preserve(), _ => SettingChoice<Switcher.Core.Configuration.ProxyPolicy>.Inherit() });
        return new ProfileEditRequest(ProfileId, Kind, ProfileName.Trim(), BaseUrl.Trim(), ApiKey, settings, ManualPath.Trim(), CatalogMode, SourceOfficialId, ExpectedProfile);
    }

    [RelayCommand]
    private void ChooseCatalog()
    {
        var dialog = new OpenFileDialog { Title = "选择完整 Codex 模型目录 JSON", Filter = "JSON 文件|*.json|所有文件|*.*", CheckFileExists = true };
        if (dialog.ShowDialog() == true) ManualPath = dialog.FileName;
    }

    [RelayCommand]
    private async Task RefreshCatalogAsync()
    {
        var generation = ++_catalogGeneration;
        if (!IsApi) { CatalogStatus = "官方模型列表由 Codex 原生维护和更新。"; return; }
        var mode = CatalogMode; var manual = ManualPath; var source = SourceOfficialId;
        ResolvedCatalogPath = mode == "official" ? string.IsNullOrWhiteSpace(source) ? "" : Path.Combine(_host.Paths.ModelCatalogDirectory, source + ".json") : Environment.ExpandEnvironmentVariables(string.IsNullOrWhiteSpace(manual) ? _host.Paths.DefaultManualModelCatalogFile : manual);
        CatalogSource = mode == "official" ? Officials.FirstOrDefault(item => item.Id == source)?.Name ?? "尚未选择官方来源" : "手动维护文件";
        CatalogUpdated = "尚无有效目录";
        IsCatalogLoading = true;
        try
        {
            var result = await Task.Run(() =>
            {
                var path = mode == "official" ? string.IsNullOrWhiteSpace(source) ? "" : Path.Combine(_host.Paths.ModelCatalogDirectory, source + ".json")
                    : Path.GetFullPath(Environment.ExpandEnvironmentVariables(string.IsNullOrWhiteSpace(manual) ? _host.Paths.DefaultManualModelCatalogFile : manual));
                var exists = !string.IsNullOrWhiteSpace(path) && File.Exists(path);
                var models = exists ? CatalogChoiceReader.Read(path) : [];
                return (path, exists, models, updated: exists ? File.GetLastWriteTime(path).ToString("yyyy-MM-dd HH:mm") : "尚无有效目录");
            });
            if (generation != _catalogGeneration) return;
            ResolvedCatalogPath = result.path; CatalogExists = result.exists; CatalogUpdated = result.updated;
            CatalogSource = mode == "official" ? Officials.FirstOrDefault(item => item.Id == source)?.Name ?? "尚未选择官方来源" : "手动维护文件";
            CatalogStatus = result.models.Count > 0 ? $"有效 · {result.models.Count} 个模型" : result.exists ? "目录中暂无模型，列表可能不完整；仍可保存和切换。" : "目录尚未配置，模型列表可能不完整；仍可保存和切换。";
            Models.Clear(); foreach (var model in result.models) Models.Add(model);
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or UnauthorizedAccessException or JsonException or ArgumentException)
        {
            if (generation != _catalogGeneration) return;
            CatalogStatus = "目录暂不可用：" + ex.Message; CatalogExists = false; Models.Clear();
        }
        finally { if (generation == _catalogGeneration) IsCatalogLoading = false; }
    }

    partial void OnProfileNameChanged(string value) => OnPropertyChanged(nameof(Title));
    partial void OnModelPolicyChanged(string value) => OnPropertyChanged(nameof(CanSpecifyModel));
    partial void OnContextPolicyChanged(string value) => OnPropertyChanged(nameof(CanSpecifyContext));
    partial void OnManualPathChanged(string value) => _ = RefreshCatalogAsync();
    partial void OnCatalogModeChanged(string value) => _ = RefreshCatalogAsync();
    partial void OnSourceOfficialIdChanged(string value) => _ = RefreshCatalogAsync();
    private string StateSignature() => JsonSerializer.Serialize(new { ProfileName, BaseUrl, ApiKey, ModelPolicy, ModelId, ContextPolicy, ContextWindow, ProxyPolicy, ManualPath, CatalogMode, SourceOfficialId });
    private static string PolicyName(SettingChoiceKind kind) => kind switch { SettingChoiceKind.Explicit => "explicit", SettingChoiceKind.PreserveCurrent => "preserve", _ => "inherit" };
}
