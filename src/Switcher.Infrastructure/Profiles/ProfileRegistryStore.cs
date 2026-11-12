using System.Text.Json;
using System.Text.Json.Serialization;
using Switcher.Core.Abstractions;
using Switcher.Core.Paths;
using Switcher.Core.Profiles;

namespace Switcher.Infrastructure.Profiles;

public sealed class ProfileRegistryStore(ISwitcherFileSystem files, SwitcherPaths paths, ISecretProtector? protector = null)
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        PropertyNameCaseInsensitive = false
    };

    public ProfileRegistry Load()
    {
        if (!files.FileExists(paths.RegistryFile))
        {
            var migrated = TryMigrateLegacy();
            if (migrated is not null) return migrated;
            return ProfileRegistry.Create(paths.CodexHome, DateTimeOffset.UtcNow);
        }
        try
        {
            var registry = JsonSerializer.Deserialize<ProfileRegistry>(files.ReadAllBytes(paths.RegistryFile), JsonOptions)
                ?? throw new InvalidDataException("档案注册表内容为空。");
            registry.Validate(paths.CodexHome);
            return registry;
        }
        catch (JsonException ex) { throw new InvalidDataException("档案注册表损坏，已停止操作。", ex); }
    }

    public byte[] Serialize(ProfileRegistry registry)
    {
        registry.Validate(paths.CodexHome);
        registry.UpdatedUtc = DateTimeOffset.UtcNow.ToString("O");
        return JsonSerializer.SerializeToUtf8Bytes(registry, JsonOptions);
    }

    public void Save(ProfileRegistry registry) => files.WriteAtomic(paths.RegistryFile, Serialize(registry));

    public string CredentialPath(ProfileEntry profile)
    {
        profile.Validate(profile is ApiProfile ? ProfileKind.Api : ProfileKind.Official);
        return Path.Combine(paths.ProfileCredentialDirectory, profile.AuthFile);
    }

    public string CatalogPath(ApiProfile profile)
    {
        if (profile.ModelCatalogMode == "official")
        {
            if (string.IsNullOrWhiteSpace(profile.ModelCatalogSourceOfficialId)) throw new InvalidDataException("官方模型目录来源未指定。");
            if (!System.Text.RegularExpressions.Regex.IsMatch(profile.ModelCatalogSourceOfficialId, "^official-[a-f0-9]{64}$")) throw new InvalidDataException("官方模型目录来源标识无效。");
            return Path.Combine(paths.ModelCatalogDirectory, profile.ModelCatalogSourceOfficialId + ".json");
        }
        var path = string.IsNullOrWhiteSpace(profile.ModelCatalogJson) ? paths.DefaultManualModelCatalogFile : profile.ModelCatalogJson;
        return Path.GetFullPath(Environment.ExpandEnvironmentVariables(path));
    }

    private ProfileRegistry? TryMigrateLegacy()
    {
        if (protector is null) return null;
        var relay = Path.Combine(paths.DataDirectory, "relay.auth.dpapi");
        var official = Path.Combine(paths.DataDirectory, "official.auth.dpapi");
        if (!files.FileExists(relay) && !files.FileExists(official)) return null;
        var result = ProfileRegistry.Create(paths.CodexHome, DateTimeOffset.UtcNow);
        if (files.FileExists(relay))
        {
            var plain = protector.Unprotect(files.ReadAllBytes(relay));
            try
            {
                var auth = System.Text.Encoding.UTF8.GetString(plain);
                if (CodexAuthAdapter.Inspect(auth).Kind != ProfileKind.Api) throw new InvalidDataException("旧 API 认证快照类型无效。");
                var baseUrl = ReadTopLevelConfig("openai_base_url");
                if (!string.IsNullOrWhiteSpace(baseUrl))
                {
                    var id = "api-" + Guid.NewGuid().ToString("N");
                    var item = new ApiProfile { Id = id, Name = "中转 API 1", BaseUrl = baseUrl.TrimEnd('/'), AuthFile = id + ".auth.dpapi", ModelCatalogJson = ReadTopLevelConfig("model_catalog_json") ?? "", ModelCatalogMode = "manual", CreatedUtc = DateTimeOffset.UtcNow.ToString("O"), UpdatedUtc = DateTimeOffset.UtcNow.ToString("O") };
                    result.ApiProfiles.Add(item); result.ActiveApiProfileId = id;
                    files.CreateDirectory(paths.ProfileCredentialDirectory);
                    files.WriteAtomic(Path.Combine(paths.ProfileCredentialDirectory, item.AuthFile), protector.Protect(plain));
                }
            }
            finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(plain); }
        }
        if (files.FileExists(official))
        {
            var plain = protector.Unprotect(files.ReadAllBytes(official));
            try
            {
                var auth = System.Text.Encoding.UTF8.GetString(plain);
                var identity = CodexAuthAdapter.Inspect(auth);
                if (identity.Kind != ProfileKind.Official || string.IsNullOrWhiteSpace(identity.OfficialOwner)) throw new InvalidDataException("旧官方认证快照类型无效。");
                var item = new OfficialProfile { Id = "official-" + identity.OfficialOwner, Name = "ChatGPT 账号 1", Owner = identity.OfficialOwner, AuthFile = "official-" + identity.OfficialOwner + ".auth.dpapi", CreatedUtc = DateTimeOffset.UtcNow.ToString("O"), UpdatedUtc = DateTimeOffset.UtcNow.ToString("O") };
                result.OfficialProfiles.Add(item); result.ActiveOfficialProfileId = item.Id;
                files.CreateDirectory(paths.ProfileCredentialDirectory);
                files.WriteAtomic(Path.Combine(paths.ProfileCredentialDirectory, item.AuthFile), protector.Protect(plain));
            }
            finally { System.Security.Cryptography.CryptographicOperations.ZeroMemory(plain); }
        }
        Save(result);
        return result;
    }

    private string? ReadTopLevelConfig(string key)
    {
        if (!files.FileExists(paths.ConfigFile)) return null;
        foreach (var line in files.ReadAllText(paths.ConfigFile).Replace("\r\n", "\n").Split('\n'))
        {
            if (line.TrimStart().StartsWith('[')) break;
            var match = System.Text.RegularExpressions.Regex.Match(line, $"^\\s*{System.Text.RegularExpressions.Regex.Escape(key)}\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')");
            if (match.Success) return match.Groups[1].Success ? match.Groups[1].Value : match.Groups[2].Value;
        }
        return null;
    }
}
