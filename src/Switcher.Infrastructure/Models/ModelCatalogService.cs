using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Switcher.Core.Abstractions;
using Switcher.Core.Paths;
using Switcher.Core.Profiles;
using Switcher.Core.Switching;
using Switcher.Core.Configuration;
using Switcher.Infrastructure.Profiles;
using Switcher.Infrastructure.Switching;

namespace Switcher.Infrastructure.Models;

public sealed class ModelCatalogService(
    ISwitcherFileSystem files,
    SwitcherPaths paths,
    ProfileRegistryStore registryStore,
    IOfficialCacheSourceVerifier sourceVerifier,
    AtomicSwitchExecutor transactionExecutor,
    IConfigEditor configEditor) : IModelCatalogProvider
{
    private static readonly JsonSerializerOptions SnapshotOptions = new() { WriteIndented = true };

    public CatalogSyncSummary SyncOfficialSnapshot(string authJson, OfficialProfile profile, string currentConfig, string? organization, string? project)
    {
        var snapshotPath = Path.Combine(paths.ModelCatalogDirectory, profile.Id + ".json");
        try
        {
            var identity = CodexAuthAdapter.Inspect(authJson);
            if (identity.Kind != ProfileKind.Official || !string.Equals(identity.OfficialOwner, profile.Owner, StringComparison.Ordinal)) throw new InvalidDataException("当前官方身份与目标档案不一致。");
            configEditor.ValidateSyntax(currentConfig);
            if (!string.IsNullOrWhiteSpace(configEditor.GetTopLevel(currentConfig, "openai_base_url")) || !string.IsNullOrWhiteSpace(configEditor.GetTopLevel(currentConfig, "model_catalog_json"))) throw new InvalidDataException("当前不是原生官方模型目录配置。");
            if (!files.FileExists(paths.ModelCacheFile)) throw new FileNotFoundException("未找到本地官方模型缓存。", paths.ModelCacheFile);
            using var cacheDocument = JsonDocument.Parse(files.ReadAllBytes(paths.ModelCacheFile));
            var cache = cacheDocument.RootElement;
            if (!sourceVerifier.IsMatch(authJson, cache, organization, project)) throw new InvalidDataException("缓存来源无法与当前官方账号对应。");
            if (!cache.TryGetProperty("models", out var models) || models.ValueKind != JsonValueKind.Array || models.GetArrayLength() == 0) throw new InvalidDataException("本地缓存中的 models 不是非空数组。");
            foreach (var model in models.EnumerateArray())
            {
                if (model.ValueKind != JsonValueKind.Object || !model.TryGetProperty("slug", out var slug) || slug.ValueKind != JsonValueKind.String || string.IsNullOrWhiteSpace(slug.GetString())) throw new InvalidDataException("本地缓存中的模型目录格式无效。");
            }
            var snapshot = JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, JsonElement> { ["models"] = models.Clone() }, SnapshotOptions);
            var registry = registryStore.Load();
            var storedProfile = registry.OfficialProfiles.FirstOrDefault(item => item.Id == profile.Id) ?? throw new InvalidDataException("官方档案不存在。");
            var updatedUtc = DateTimeOffset.UtcNow;
            storedProfile.ModelCatalogSnapshotUpdatedUtc = updatedUtc.ToString("O");
            var versionText = cache.TryGetProperty("client_version", out var version) ? version.GetString() ?? "" : "";
            storedProfile.ModelCatalogSnapshotClientVersion = versionText;
            storedProfile.ModelCatalogSnapshotIdentity = cache.TryGetProperty("identity", out var cacheIdentity) ? cacheIdentity.GetString() ?? "" : "";
            storedProfile.ModelCatalogSnapshotSha256 = Convert.ToHexString(SHA256.HashData(snapshot)).ToLowerInvariant();
            var plan = new OperationPlan(Guid.NewGuid().ToString("N"), "同步官方模型目录快照",
            [
                new FileMutation(snapshotPath, CurrentHash(snapshotPath), snapshot, "写入独立官方模型目录快照", files.FileExists(snapshotPath)),
                new FileMutation(paths.RegistryFile, CurrentHash(paths.RegistryFile), registryStore.Serialize(registry), "更新官方快照来源记录", files.FileExists(paths.RegistryFile))
            ], updatedUtc);
            transactionExecutor.ExecuteAsync(plan, null, CancellationToken.None).GetAwaiter().GetResult();
            profile.ModelCatalogSnapshotUpdatedUtc = storedProfile.ModelCatalogSnapshotUpdatedUtc;
            profile.ModelCatalogSnapshotClientVersion = storedProfile.ModelCatalogSnapshotClientVersion;
            profile.ModelCatalogSnapshotIdentity = storedProfile.ModelCatalogSnapshotIdentity;
            profile.ModelCatalogSnapshotSha256 = storedProfile.ModelCatalogSnapshotSha256;
            return new CatalogSyncSummary(true, $"已同步官方账号模型目录（{models.GetArrayLength()} 项）。", snapshotPath, models.GetArrayLength());
        }
        catch (Exception ex) when (ex is not OperationCanceledException and not OutOfMemoryException && !files.FileExists(paths.TransactionFile))
        {
            var message = ex switch
            {
                FileNotFoundException => "本地尚无官方模型缓存",
                JsonException => "本地缓存格式无效",
                _ when ex.Message.Contains("来源", StringComparison.Ordinal) => "无法确认本地缓存属于当前官方账号",
                _ when ex.Message.Contains("models", StringComparison.Ordinal) => "本地缓存中的模型目录格式无效",
                UnauthorizedAccessException => "无权读取或保存目录文件",
                _ => "读取或保存快照失败"
            };
            return new CatalogSyncSummary(false, $"模型目录未更新（{message}），保留已有快照。", snapshotPath, 0);
        }
    }

    public string ResolveApiCatalog(ApiProfile profile) => registryStore.CatalogPath(profile);

    public string EnsureManualCatalogFile(ApiProfile profile)
    {
        if (profile.ModelCatalogMode == "official") throw new InvalidOperationException("跟随官方目录时请先同步来源账号的目录快照。 ");
        var path = registryStore.CatalogPath(profile);
        files.TryCreateAtomic(path, Encoding.UTF8.GetBytes("{\"models\":[]}\n"));
        return path;
    }

    public CatalogDisplay GetStatus(ProfileEntry profile, ProfileKind kind, string? sourceName = null)
    {
        var path = kind == ProfileKind.Official ? Path.Combine(paths.ModelCatalogDirectory, profile.Id + ".json") : registryStore.CatalogPath((ApiProfile)profile);
        var exists = files.FileExists(path);
        var updated = exists ? files.GetLastWriteTimeUtc(path).ToString("O") : "";
        var mode = kind == ProfileKind.Official ? "官方原生目录" : ((ApiProfile)profile).ModelCatalogMode == "official" ? "跟随官方目录" : "手动维护目录";
        return new CatalogDisplay(mode, path, exists, sourceName ?? "", updated, exists ? "目录可用" : "尚未配置目录，模型列表可能不完整");
    }

    private string? CurrentHash(string path) => files.FileExists(path) ? Convert.ToHexString(SHA256.HashData(files.ReadAllBytes(path))).ToLowerInvariant() : null;

}
