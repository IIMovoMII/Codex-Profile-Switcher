using System.Text.Json;
using System.Text.Json.Serialization;
using Switcher.Core.Configuration;

namespace Switcher.Core.Profiles;

public sealed class ProfileRegistry
{
    [JsonPropertyName("version")] public int Version { get; set; } = 1;
    [JsonPropertyName("codex_home")] public string CodexHome { get; set; } = "";
    [JsonPropertyName("created_utc")] public string CreatedUtc { get; set; } = "";
    [JsonPropertyName("updated_utc")] public string UpdatedUtc { get; set; } = "";
    [JsonPropertyName("active_api_profile_id")] public string ActiveApiProfileId { get; set; } = "";
    [JsonPropertyName("active_official_profile_id")] public string ActiveOfficialProfileId { get; set; } = "";
    [JsonPropertyName("api_profiles")] public List<ApiProfile> ApiProfiles { get; set; } = [];
    [JsonPropertyName("official_profiles")] public List<OfficialProfile> OfficialProfiles { get; set; } = [];
    [JsonExtensionData] public Dictionary<string, JsonElement>? UnknownFields { get; set; }

    public static ProfileRegistry Create(string codexHome, DateTimeOffset now)
    {
        var timestamp = now.ToUniversalTime().ToString("O");
        return new ProfileRegistry { CodexHome = codexHome, CreatedUtc = timestamp, UpdatedUtc = timestamp };
    }

    public IEnumerable<ProfileEntry> AllProfiles() => ApiProfiles.Cast<ProfileEntry>().Concat(OfficialProfiles);

    public ProfileEntry Find(ProfileKind kind, string selector)
    {
        var candidates = kind == ProfileKind.Api ? ApiProfiles.Cast<ProfileEntry>() : OfficialProfiles;
        var matches = candidates.Where(p => string.Equals(p.Id, selector, StringComparison.Ordinal) ||
                                                   string.Equals(p.Name, selector, StringComparison.Ordinal)).ToArray();
        return matches.Length switch
        {
            0 => throw new KeyNotFoundException($"找不到 {kind.ToLegacyValue()} 档案：{selector}"),
            > 1 => throw new InvalidOperationException($"档案名称重复，请改用 ID：{selector}"),
            _ => matches[0]!
        };
    }

    public ProfileEntry GetSelected(ProfileKind kind, string? selector = null)
    {
        if (!string.IsNullOrWhiteSpace(selector)) return Find(kind, selector);
        var activeId = kind == ProfileKind.Api ? ActiveApiProfileId : ActiveOfficialProfileId;
        var profiles = kind == ProfileKind.Api ? ApiProfiles.Cast<ProfileEntry>().ToArray() : OfficialProfiles.Cast<ProfileEntry>().ToArray();
        if (!string.IsNullOrWhiteSpace(activeId)) return Find(kind, activeId);
        return profiles.Length switch
        {
            1 => profiles[0],
            0 => throw new InvalidOperationException($"尚未登记 {kind.ToLegacyValue()} 档案。"),
            _ => throw new InvalidOperationException($"已登记多个 {kind.ToLegacyValue()} 档案，请明确指定 --profile。")
        };
    }

    public void Validate(string expectedCodexHome)
    {
        if (Version != 1) throw new InvalidDataException($"不支持的档案注册表版本：{Version}");
        if (!PathEquals(CodexHome, expectedCodexHome)) throw new InvalidDataException("档案注册表属于另一个 CODEX_HOME。");
        if (ApiProfiles is null || OfficialProfiles is null) throw new InvalidDataException("档案数组缺失。");
        foreach (var p in ApiProfiles)
        {
            p.Validate(ProfileKind.Api);
            if (string.IsNullOrWhiteSpace(p.BaseUrl)) throw new InvalidDataException("API 档案缺少中转地址。");
            ValidateRelayBaseUrl(p.BaseUrl);
            if (p.ModelCatalogMode is not ("" or "manual" or "official")) throw new InvalidDataException("API 档案模型目录维护方式无效。");
            if (p.ModelCatalogMode == "official" && string.IsNullOrWhiteSpace(p.ModelCatalogSourceOfficialId)) throw new InvalidDataException("跟随官方模型目录时必须指定官方账号来源。");
        }
        foreach (var p in OfficialProfiles)
        {
            p.Validate(ProfileKind.Official);
            if (string.IsNullOrWhiteSpace(p.Owner) || !System.Text.RegularExpressions.Regex.IsMatch(p.Owner, "^[a-f0-9]{64}$")) throw new InvalidDataException("官方档案账号标识无效。");
            if (!string.Equals(p.Id, "official-" + p.Owner, StringComparison.Ordinal)) throw new InvalidDataException("官方档案 ID 与账号标识不一致。");
            foreach (var digest in new[] { p.ModelCatalogSnapshotIdentity, p.ModelCatalogSnapshotSha256 })
                if (!string.IsNullOrEmpty(digest) && !System.Text.RegularExpressions.Regex.IsMatch(digest, "^[a-f0-9]{64}$")) throw new InvalidDataException("官方模型目录快照校验字段无效。");
        }
    }

    public static void ValidateRelayBaseUrl(string value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps ||
            !string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment))
            throw new InvalidDataException("中转地址必须是没有凭据、查询参数或片段的 HTTPS 绝对地址。");
    }

    private static bool PathEquals(string left, string right)
    {
        try { return string.Equals(Path.TrimEndingDirectorySeparator(Path.GetFullPath(left)), Path.TrimEndingDirectorySeparator(Path.GetFullPath(right)), StringComparison.OrdinalIgnoreCase); }
        catch { return false; }
    }
}

public abstract class ProfileEntry
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("auth_file")] public string AuthFile { get; set; } = "";
    [JsonPropertyName("model")] public string Model { get; set; } = "";
    [JsonPropertyName("context_window")] public string ContextWindow { get; set; } = "";
    [JsonPropertyName("proxy_policy")] public string ProxyPolicy { get; set; } = "";
    [JsonPropertyName("settings_scope")] public string SettingsScope { get; set; } = "";
    [JsonPropertyName("model_policy")] public string ModelPolicy { get; set; } = "";
    [JsonPropertyName("context_window_policy")] public string ContextWindowPolicy { get; set; } = "";
    [JsonPropertyName("created_utc")] public string CreatedUtc { get; set; } = "";
    [JsonPropertyName("updated_utc")] public string UpdatedUtc { get; set; } = "";
    [JsonExtensionData] public Dictionary<string, JsonElement>? UnknownFields { get; set; }

    public ProfileSettings ToSettings()
    {
        var accountScoped = SettingsScope == "account";
        var model = ModelPolicy switch
        {
            "preserve" => SettingChoice<string>.Preserve(),
            "inherit" => SettingChoice<string>.Inherit(),
            "explicit" when !string.IsNullOrWhiteSpace(Model) => SettingChoice<string>.Set(Model),
            _ => string.IsNullOrWhiteSpace(Model) ? SettingChoice<string>.Inherit() : SettingChoice<string>.Set(Model)
        };
        var context = ContextWindowPolicy switch
        {
            "preserve" => SettingChoice<int>.Preserve(),
            "inherit" => SettingChoice<int>.Inherit(),
            "explicit" when int.TryParse(ContextWindow, out var explicitContext) && explicitContext > 0 => SettingChoice<int>.Set(explicitContext),
            _ => int.TryParse(ContextWindow, out var parsed) && parsed > 0 ? SettingChoice<int>.Set(parsed) :
                accountScoped ? SettingChoice<int>.Preserve() : SettingChoice<int>.Inherit()
        };
        var proxy = ProxyPolicy switch
        {
            "system" => SettingChoice<global::Switcher.Core.Configuration.ProxyPolicy>.Set(global::Switcher.Core.Configuration.ProxyPolicy.System),
            "direct" => SettingChoice<global::Switcher.Core.Configuration.ProxyPolicy>.Set(global::Switcher.Core.Configuration.ProxyPolicy.Direct),
            "preserve" => SettingChoice<global::Switcher.Core.Configuration.ProxyPolicy>.Preserve(),
            "inherit" => SettingChoice<global::Switcher.Core.Configuration.ProxyPolicy>.Inherit(),
            "" => accountScoped ? SettingChoice<global::Switcher.Core.Configuration.ProxyPolicy>.Preserve() : SettingChoice<global::Switcher.Core.Configuration.ProxyPolicy>.Inherit(),
            _ => throw new InvalidDataException("账号代理策略无效。")
        };
        return new ProfileSettings(model, context, proxy);
    }

    public void SetSettings(ProfileSettings settings)
    {
        SettingsScope = "account";
        ModelPolicy = settings.Model.Kind switch { SettingChoiceKind.PreserveCurrent => "preserve", SettingChoiceKind.Explicit => "explicit", _ => "inherit" };
        Model = settings.Model.Kind == SettingChoiceKind.Explicit ? settings.Model.Value ?? "" : "";
        ContextWindowPolicy = settings.ContextWindow.Kind switch { SettingChoiceKind.PreserveCurrent => "preserve", SettingChoiceKind.Explicit => "explicit", _ => "inherit" };
        ContextWindow = settings.ContextWindow.Kind == SettingChoiceKind.Explicit ? settings.ContextWindow.Value.ToString() : "";
        ProxyPolicy = settings.Proxy.Kind switch
        {
            SettingChoiceKind.Explicit => settings.Proxy.Value.ToString().ToLowerInvariant(),
            SettingChoiceKind.Inherit => "inherit",
            _ => "preserve"
        };
    }

    public void Validate(ProfileKind expectedKind)
    {
        if (!System.Text.RegularExpressions.Regex.IsMatch(Id ?? "", "^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$")) throw new InvalidDataException("档案 ID 无效。");
        if (string.IsNullOrWhiteSpace(Name)) throw new InvalidDataException("档案名称不能为空。");
        if (!System.Text.RegularExpressions.Regex.IsMatch(AuthFile ?? "", "^[A-Za-z0-9][A-Za-z0-9._-]{0,120}\\.auth\\.dpapi$")) throw new InvalidDataException("档案凭据文件名无效。");
        if (!string.IsNullOrWhiteSpace(ContextWindow) && (!int.TryParse(ContextWindow, out var context) || context <= 0)) throw new InvalidDataException("上下文窗口必须是正整数。");
        if (ModelPolicy is not ("" or "inherit" or "preserve" or "explicit")) throw new InvalidDataException("模型设置策略无效。");
        if (ContextWindowPolicy is not ("" or "inherit" or "preserve" or "explicit")) throw new InvalidDataException("上下文设置策略无效。");
        if (ModelPolicy == "explicit" && string.IsNullOrWhiteSpace(Model)) throw new InvalidDataException("显式模型设置不能为空。");
        if (ContextWindowPolicy == "explicit" && string.IsNullOrWhiteSpace(ContextWindow)) throw new InvalidDataException("显式上下文设置不能为空。");
        _ = ToSettings();
        if (expectedKind == ProfileKind.Official && this is not OfficialProfile) throw new InvalidDataException("官方档案类型无效。");
        if (expectedKind == ProfileKind.Api && this is not ApiProfile) throw new InvalidDataException("API 档案类型无效。");
    }
}

public sealed class ApiProfile : ProfileEntry
{
    [JsonPropertyName("base_url")] public string BaseUrl { get; set; } = "";
    [JsonPropertyName("model_catalog_json")] public string ModelCatalogJson { get; set; } = "";
    [JsonPropertyName("model_catalog_mode")] public string ModelCatalogMode { get; set; } = "manual";
    [JsonPropertyName("model_catalog_source_official_id")] public string ModelCatalogSourceOfficialId { get; set; } = "";
}

public sealed class OfficialProfile : ProfileEntry
{
    [JsonPropertyName("owner")] public string Owner { get; set; } = "";
    [JsonPropertyName("model_catalog_snapshot_updated_utc")] public string ModelCatalogSnapshotUpdatedUtc { get; set; } = "";
    [JsonPropertyName("model_catalog_snapshot_client_version")] public string ModelCatalogSnapshotClientVersion { get; set; } = "";
    [JsonPropertyName("model_catalog_snapshot_identity")] public string ModelCatalogSnapshotIdentity { get; set; } = "";
    [JsonPropertyName("model_catalog_snapshot_sha256")] public string ModelCatalogSnapshotSha256 { get; set; } = "";
}
