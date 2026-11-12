using Switcher.Core.Configuration;

namespace Switcher.Core.Profiles;

public interface IAuthClassifier
{
    ProfileKind? Classify(string authenticationJson);
    string GetApiKey(string authenticationJson);
    string GetOfficialOwner(string authenticationJson);
}

public interface IProfileRepository
{
    ProfileRegistry Load();
    byte[] Serialize(ProfileRegistry registry);
    void Save(ProfileRegistry registry);
    string ReadAuthentication(ProfileEntry profile, ProfileKind kind);
    void SaveProfile(ProfileRegistry registry, ProfileEntry profile, ProfileKind kind, string authenticationJson);
    void DeleteProfile(ProfileRegistry registry, ProfileEntry profile, ProfileKind kind);
    string GetCredentialPath(ProfileEntry profile);
    string GetModelCatalogPath(ApiProfile profile);
}

public sealed record AddApiProfile(string Name, string BaseUrl, string ApiKey, string? ModelCatalogPath = null,
    ProfileSettings? Settings = null, string ModelCatalogMode = "manual", string? ModelCatalogSourceOfficialId = null);

public sealed class ProfileManagementService(IProfileRepository repository, IAuthClassifier classifier)
{
    public IReadOnlyList<ProfileEntry> List() => repository.Load().AllProfiles().OrderBy(p => p.Name, StringComparer.CurrentCultureIgnoreCase).ToArray();

    public ApiProfile AddApi(AddApiProfile request)
    {
        var name = RequiredName(request.Name);
        ProfileRegistry.ValidateRelayBaseUrl(request.BaseUrl);
        if (string.IsNullOrWhiteSpace(request.ApiKey)) throw new ArgumentException("API Key 不能为空。", nameof(request));
        if (request.ModelCatalogMode is not ("manual" or "official")) throw new ArgumentException("模型目录方式必须为 manual 或 official。", nameof(request));
        if (request.ModelCatalogMode == "official" && string.IsNullOrWhiteSpace(request.ModelCatalogSourceOfficialId))
            throw new InvalidDataException("跟随官方模型目录时必须指定来源官方账号。");
        var auth = $"{{\"OPENAI_API_KEY\":{System.Text.Json.JsonSerializer.Serialize(request.ApiKey)}}}";
        if (classifier.Classify(auth) != ProfileKind.Api) throw new InvalidDataException("API 认证格式无效。");
        var registry = repository.Load();
        var id = "api-" + Guid.NewGuid().ToString("N");
        var now = DateTimeOffset.UtcNow.ToString("O");
        var profile = new ApiProfile
        {
            Id = id,
            Name = name,
            BaseUrl = request.BaseUrl.TrimEnd('/'),
            ModelCatalogJson = request.ModelCatalogPath ?? "",
            ModelCatalogMode = request.ModelCatalogMode,
            ModelCatalogSourceOfficialId = request.ModelCatalogSourceOfficialId ?? "",
            AuthFile = id + ".auth.dpapi",
            CreatedUtc = now,
            UpdatedUtc = now
        };
        if (request.Settings is not null) profile.SetSettings(request.Settings);
        registry.ApiProfiles.Add(profile);
        registry.ActiveApiProfileId = id;
        repository.SaveProfile(registry, profile, ProfileKind.Api, auth);
        return profile;
    }

    public ProfileEntry CaptureCurrent(string authJson, string currentBaseUrl, string? manualCatalogPath)
    {
        var kind = classifier.Classify(authJson) ?? throw new InvalidDataException("当前认证类型无法确认，未切换账号。");
        var registry = repository.Load();
        var now = DateTimeOffset.UtcNow.ToString("O");
        if (kind == ProfileKind.Api)
        {
            ProfileRegistry.ValidateRelayBaseUrl(currentBaseUrl);
            var currentKeyHash = System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(classifier.GetApiKey(authJson)));
            ApiProfile? existing = null;
            foreach (var candidate in registry.ApiProfiles.Where(p => string.Equals(p.BaseUrl, currentBaseUrl, StringComparison.Ordinal)))
            {
                try
                {
                    var candidateHash = System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(classifier.GetApiKey(repository.ReadAuthentication(candidate, ProfileKind.Api))));
                    if (System.Security.Cryptography.CryptographicOperations.FixedTimeEquals(currentKeyHash, candidateHash)) { existing = candidate; break; }
                }
                catch (Exception ex) when (ex is IOException or InvalidDataException or System.Security.Cryptography.CryptographicException) { }
            }
            var id = "api-" + Guid.NewGuid().ToString("N");
            var profile = existing ?? new ApiProfile
            {
                Id = id,
                Name = $"中转 API {registry.ApiProfiles.Count + 1}",
                BaseUrl = currentBaseUrl,
                ModelCatalogJson = manualCatalogPath ?? "",
                ModelCatalogMode = "manual",
                AuthFile = id + ".auth.dpapi",
                CreatedUtc = now
            };
            profile.BaseUrl = currentBaseUrl;
            if (string.IsNullOrWhiteSpace(profile.ModelCatalogMode))
            {
                if (!string.IsNullOrWhiteSpace(manualCatalogPath)) profile.ModelCatalogJson = manualCatalogPath;
                profile.ModelCatalogMode = "manual";
            }
            if (existing is null) registry.ApiProfiles.Add(profile);
            profile.UpdatedUtc = now;
            registry.ActiveApiProfileId = profile.Id;
            repository.SaveProfile(registry, profile, kind, authJson);
            System.Security.Cryptography.CryptographicOperations.ZeroMemory(currentKeyHash);
            return profile;
        }
        else
        {
            var owner = classifier.GetOfficialOwner(authJson);
            var profile = registry.OfficialProfiles.FirstOrDefault(p => string.Equals(p.Owner, owner, StringComparison.Ordinal));
            if (profile is null)
            {
                profile = new OfficialProfile
                {
                    Id = "official-" + owner,
                    Owner = owner,
                    Name = $"ChatGPT 账号 {registry.OfficialProfiles.Count + 1}",
                    AuthFile = "official-" + owner + ".auth.dpapi",
                    CreatedUtc = now
                };
                registry.OfficialProfiles.Add(profile);
            }
            profile.UpdatedUtc = now;
            registry.ActiveOfficialProfileId = profile.Id;
            repository.SaveProfile(registry, profile, kind, authJson);
            return profile;
        }
    }

    public OfficialProfile ImportOfficial(string name, string authJson)
    {
        if (classifier.Classify(authJson) != ProfileKind.Official) throw new InvalidDataException("当前 auth.json 不是完整的官方 OAuth 凭据。");
        var owner = classifier.GetOfficialOwner(authJson);
        var registry = repository.Load();
        var existing = registry.OfficialProfiles.FirstOrDefault(p => p.Owner == owner);
        var now = DateTimeOffset.UtcNow.ToString("O");
        var profile = existing ?? new OfficialProfile
        {
            Id = "official-" + owner,
            Name = string.IsNullOrWhiteSpace(name) ? $"ChatGPT 账号 {registry.OfficialProfiles.Count + 1}" : RequiredName(name),
            Owner = owner,
            AuthFile = "official-" + owner + ".auth.dpapi",
            CreatedUtc = now
        };
        if (!string.IsNullOrWhiteSpace(name)) profile.Name = RequiredName(name);
        profile.UpdatedUtc = now;
        if (existing is null) registry.OfficialProfiles.Add(profile);
        registry.ActiveOfficialProfileId = profile.Id;
        repository.SaveProfile(registry, profile, ProfileKind.Official, authJson);
        return profile;
    }

    public void Rename(ProfileKind kind, string selector, string name)
    {
        var registry = repository.Load();
        var profile = registry.Find(kind, selector);
        profile.Name = RequiredName(name);
        profile.UpdatedUtc = DateTimeOffset.UtcNow.ToString("O");
        repository.Save(registry);
    }

    public void UpdateSettings(ProfileKind kind, string selector, ProfileSettings settings, string? displayName = null)
    {
        var registry = repository.Load();
        var profile = registry.Find(kind, selector);
        profile.SetSettings(settings);
        if (displayName is not null) profile.Name = RequiredName(displayName);
        profile.UpdatedUtc = DateTimeOffset.UtcNow.ToString("O");
        repository.Save(registry);
    }

    public void UpdateApiSettings(string selector, ProfileSettings settings, string? baseUrl = null, string? catalogMode = null, string? catalogPath = null, string? sourceOfficialId = null)
    {
        var registry = repository.Load();
        var profile = (ApiProfile)registry.Find(ProfileKind.Api, selector);
        if (baseUrl is not null)
        {
            ProfileRegistry.ValidateRelayBaseUrl(baseUrl);
            profile.BaseUrl = baseUrl.TrimEnd('/');
        }
        if (catalogMode is not null)
        {
            if (catalogMode is not ("manual" or "official")) throw new ArgumentException("模型目录方式必须为 manual 或 official。", nameof(catalogMode));
            profile.ModelCatalogMode = catalogMode;
        }
        if (catalogPath is not null) profile.ModelCatalogJson = catalogPath;
        if (sourceOfficialId is not null) profile.ModelCatalogSourceOfficialId = sourceOfficialId;
        if (profile.ModelCatalogMode == "official" && string.IsNullOrWhiteSpace(profile.ModelCatalogSourceOfficialId)) throw new InvalidDataException("跟随官方目录时必须选择来源官方账号。");
        profile.SetSettings(settings);
        profile.UpdatedUtc = DateTimeOffset.UtcNow.ToString("O");
        repository.Save(registry);
    }

    public void EditApiProfile(string selector, ProfileSettings settings, string baseUrl, string catalogMode, string? catalogPath, string? sourceOfficialId, string? replacementApiKey, string? displayName = null)
    {
        var registry = repository.Load();
        var profile = (ApiProfile)registry.Find(ProfileKind.Api, selector);
        ProfileRegistry.ValidateRelayBaseUrl(baseUrl);
        if (catalogMode is not ("manual" or "official")) throw new ArgumentException("模型目录方式必须为 manual 或 official。", nameof(catalogMode));
        profile.BaseUrl = baseUrl.TrimEnd('/');
        if (displayName is not null) profile.Name = RequiredName(displayName);
        profile.ModelCatalogMode = catalogMode;
        if (catalogPath is not null) profile.ModelCatalogJson = catalogPath;
        if (sourceOfficialId is not null) profile.ModelCatalogSourceOfficialId = sourceOfficialId;
        if (profile.ModelCatalogMode == "official" && string.IsNullOrWhiteSpace(profile.ModelCatalogSourceOfficialId)) throw new InvalidDataException("跟随官方目录时必须选择官方来源账号。");
        profile.SetSettings(settings);
        profile.UpdatedUtc = DateTimeOffset.UtcNow.ToString("O");
        var auth = string.IsNullOrWhiteSpace(replacementApiKey)
            ? repository.ReadAuthentication(profile, ProfileKind.Api)
            : System.Text.Json.JsonSerializer.Serialize(new Dictionary<string, string> { ["OPENAI_API_KEY"] = replacementApiKey });
        repository.SaveProfile(registry, profile, ProfileKind.Api, auth);
        if (!string.IsNullOrWhiteSpace(replacementApiKey)) System.Security.Cryptography.CryptographicOperations.ZeroMemory(System.Text.Encoding.UTF8.GetBytes(auth));
    }

    public void ReauthorizeOfficial(string selector, string refreshedAuthenticationJson)
    {
        var registry = repository.Load();
        var profile = (OfficialProfile)registry.Find(ProfileKind.Official, selector);
        var identityKind = classifier.Classify(refreshedAuthenticationJson);
        var owner = identityKind == ProfileKind.Official ? classifier.GetOfficialOwner(refreshedAuthenticationJson) : null;
        if (identityKind != ProfileKind.Official || !string.Equals(owner, profile.Owner, StringComparison.Ordinal))
            throw new InvalidDataException("重新授权的官方身份与所选档案不同；原凭据未改变。 ");
        profile.UpdatedUtc = DateTimeOffset.UtcNow.ToString("O");
        repository.SaveProfile(registry, profile, ProfileKind.Official, refreshedAuthenticationJson);
    }

    public void Remove(ProfileKind kind, string selector, string? liveProfileId)
    {
        var registry = repository.Load();
        var profile = registry.Find(kind, selector);
        if (string.Equals(profile.Id, liveProfileId, StringComparison.Ordinal)) throw new InvalidOperationException("不能删除当前正在使用的档案，请先切换到其他账号。");
        if (kind == ProfileKind.Api)
        {
            registry.ApiProfiles.Remove((ApiProfile)profile);
            if (registry.ActiveApiProfileId == profile.Id) registry.ActiveApiProfileId = registry.ApiProfiles.FirstOrDefault()?.Id ?? "";
        }
        else
        {
            registry.OfficialProfiles.Remove((OfficialProfile)profile);
            if (registry.ActiveOfficialProfileId == profile.Id) registry.ActiveOfficialProfileId = registry.OfficialProfiles.FirstOrDefault()?.Id ?? "";
        }
        repository.DeleteProfile(registry, profile, kind);
    }

    private static string RequiredName(string name) => string.IsNullOrWhiteSpace(name) ? throw new ArgumentException("档案名称不能为空。") : name.Trim();
}
