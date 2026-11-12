using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Switcher.Core.Abstractions;
using Switcher.Core.Paths;
using Switcher.Core.Profiles;
using Switcher.Core.Switching;
using Switcher.Infrastructure.Profiles;

namespace Switcher.Infrastructure.CodexAdapters;

/// <summary>Preserves shared local projects while keeping account-scoped renderer state under the same DPAPI format used by the legacy app.</summary>
public sealed class DesktopStateAdapter(ISwitcherFileSystem files, ISecretProtector protector, SwitcherPaths paths) : IDesktopStatePlanner
{
    private const string EnvelopeKey = "electron-account-renderer-state-v1";
    private const string AtomsKey = "electron-persisted-atom-state";
    private const string WelcomeKey = "electron:onboarding-welcome-v2-role-state";
    private static readonly string[] ScopedGlobals =
    [
        "active-workspace-roots", "electron-saved-workspace-roots", "local-projects",
        "app-server-project-id-by-legacy-project-id-by-host", "app-server-projects-migration-by-host",
        "selected-project", "project-appearances", "pinned-thread-ids",
        "app-server-migrated-pinned-thread-ids-by-host", "sidebar-project-thread-orders",
        "thread-project-assignments", "thread-project-membership-host-ids", "thread-writable-roots",
        "thread-workspace-root-hints", "thread-projectless-output-directories",
        "projectless-thread-ids", "project-order", "remote-project-connection-backfill-completed",
        "queued-follow-ups"
    ];
    private static readonly string[] SharedGlobals =
    [
        "active-workspace-roots", "electron-saved-workspace-roots", "local-projects",
        "app-server-project-id-by-legacy-project-id-by-host", "app-server-projects-migration-by-host",
        "project-appearances", "sidebar-project-thread-orders", "thread-project-assignments",
        "thread-project-membership-host-ids", "thread-writable-roots", "thread-workspace-root-hints",
        "thread-projectless-output-directories", "projectless-thread-ids", "project-order"
    ];
    private static readonly string[] DeviceAtoms =
    [
        "last_completed_onboarding", "electron:onboarding-projectless-completed",
        "electron:bedrock-govcloud-guidance-acknowledged", "ctrl-tab-shortcut-notice-shown",
        "number-shortcut-notice-shown", "thread-sort-key"
    ];
    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    public DesktopStatePlan CreatePlan(ProfileKind targetKind, string? sourceAuth, string? targetAuth, string? officialAuth)
    {
        var globalPath = Path.Combine(paths.CodexHome, ".codex-global-state.json");
        var archivePath = Path.Combine(paths.DataDirectory, "desktop-renderer-state.dpapi");
        if (!files.FileExists(globalPath)) return new DesktopStatePlan([], 0, false, false);
        JsonObject root;
        try { root = JsonNode.Parse(files.ReadAllBytes(globalPath)) as JsonObject ?? throw new InvalidDataException("Codex Desktop global state 顶层必须是对象。"); }
        catch (JsonException ex) { throw new InvalidDataException("无法解析 Codex Desktop global state；未修改状态文件。", ex); }

        ValidateJsonShape(root, "global state");
        var originalRoot = (JsonObject)root.DeepClone();
        var archive = ReadArchive(archivePath);
        ValidateArchive(archive);
        var previousArchive = (JsonObject)archive.DeepClone();
        var profiles = archive["profiles"] as JsonObject ?? throw new InvalidDataException("renderer archive profiles 字段不是对象。");
        var api = archive["api"] as JsonObject ?? throw new InvalidDataException("renderer archive api 字段不是对象。");
        var sourceOwner = ReadOwner(sourceAuth);
        var targetOwner = ReadOwner(targetAuth);
        var officialOwner = ReadOwner(officialAuth);
        var atoms = root[AtomsKey] as JsonObject ?? new JsonObject();
        var globals = Select(root, ScopedGlobals);
        var envelope = root[EnvelopeKey] as JsonObject;
        if (root[EnvelopeKey] is not null && envelope is null) throw new InvalidDataException("未知 Desktop account-state 封套结构；未修改状态文件。");

        if (envelope is not null)
        {
            if (envelope["inactive"] is not JsonObject inactive || !envelope.ContainsKey("owner")) throw new InvalidDataException("未知 Desktop account-state 封套结构；未修改状态文件。");
            foreach (var (owner, profile) in inactive)
            {
                ValidateOwner(owner);
                var normalized = ValidateProfile(profile);
                profiles[owner] = normalized.DeepClone();
            }
            var activeOwner = envelope["owner"]?.GetValue<string>() ?? "";
            if (!string.IsNullOrWhiteSpace(activeOwner))
            {
                ValidateOwner(activeOwner);
                profiles[activeOwner] = MakeProfile(atoms, globals);
            }
            else archive["api"] = MakeProfile(atoms, globals);
        }
        else if (!string.IsNullOrEmpty(sourceOwner)) profiles[sourceOwner] = MakeProfile(atoms, globals);
        else if (sourceAuth is not null && CodexAuthAdapter.Inspect(sourceAuth).Kind == ProfileKind.Api) archive["api"] = MakeProfile(atoms, globals);

        var targetProfile = new JsonObject { ["atoms"] = new JsonObject(), ["globals"] = new JsonObject() };
        if (targetKind == ProfileKind.Api) targetProfile = (JsonObject)api.DeepClone();
        else if (!string.IsNullOrEmpty(targetOwner) && profiles[targetOwner] is JsonObject stored) targetProfile = (JsonObject)stored.DeepClone();
        else if (envelope is null && sourceOwner == targetOwner) targetProfile = MakeProfile(atoms, globals);

        var localGlobals = globals;
        if (!localGlobals.ContainsKey("local-projects"))
        {
            foreach (var owner in new[] { sourceOwner, targetOwner, officialOwner })
            {
                if (!string.IsNullOrEmpty(owner) && profiles[owner] is JsonObject oldProfile && oldProfile["globals"] is JsonObject oldGlobals && oldGlobals.ContainsKey("local-projects"))
                { localGlobals = oldGlobals; break; }
            }
            if (!localGlobals.ContainsKey("local-projects") && api["globals"] is JsonObject apiGlobals && apiGlobals.ContainsKey("local-projects")) localGlobals = apiGlobals;
        }
        var shared = Select(localGlobals, SharedGlobals);
        var targetGlobals = targetProfile["globals"] as JsonObject ?? new JsonObject();
        var oldLocalGlobals = Select(targetGlobals, SharedGlobals);
        if (envelope is null && sourceOwner is null && targetKind == ProfileKind.Official && targetOwner is null && officialOwner is null)
            targetProfile = MakeProfile(atoms, globals);

        var targetAtoms = targetProfile["atoms"] as JsonObject ?? new JsonObject();
        foreach (var key in DeviceAtoms) if (atoms.ContainsKey(key)) targetAtoms[key] = atoms[key]?.DeepClone();
        var completed = false;
        var welcomeSources = new List<JsonObject> { atoms, targetAtoms };
        foreach (var owner in new[] { sourceOwner, targetOwner, officialOwner })
            if (!string.IsNullOrEmpty(owner) && profiles[owner] is JsonObject profile && profile["atoms"] is JsonObject profileAtoms) welcomeSources.Add(profileAtoms);
        if (api["atoms"] is JsonObject apiAtoms) welcomeSources.Add(apiAtoms);
        foreach (var candidate in welcomeSources)
        {
            if (candidate[WelcomeKey] is JsonObject welcome && welcome["completedConversationalOnboarding"]?.GetValue<bool>() == true)
            {
                targetAtoms[WelcomeKey] = welcome.DeepClone();
                targetAtoms["electron:onboarding-welcome-pending"] = false;
                completed = true;
                break;
            }
        }

        foreach (var key in ScopedGlobals)
        {
            if (targetGlobals.ContainsKey(key)) root[key] = targetGlobals[key]?.DeepClone();
            else root.Remove(key);
        }
        MergeShared(root, shared, oldLocalGlobals);
        root[AtomsKey] = targetAtoms.DeepClone();
        root.Remove(EnvelopeKey);
        ValidateJsonShape(root, "target global state");
        ValidateGlobalTypes(root);

        var mutations = new List<FileMutation>();
        var rootTarget = JsonSerializer.SerializeToUtf8Bytes(root, JsonOptions);
        var rootOriginal = files.ReadAllBytes(globalPath);
        if (!rootOriginal.AsSpan().SequenceEqual(rootTarget))
        {
            mutations.Add(new FileMutation(globalPath, Hash(rootOriginal), rootTarget, "更新 Desktop 账号界面状态", true));
            mutations.Add(new FileMutation(globalPath + ".bak", CurrentHash(globalPath + ".bak"), rootTarget, "保存 Desktop 状态对应备份", files.FileExists(globalPath + ".bak")));
        }
        var archiveTarget = JsonSerializer.SerializeToUtf8Bytes(archive, JsonOptions);
        if (!JsonNode.DeepEquals(previousArchive, archive))
        {
            var encrypted = protector.Protect(archiveTarget);
            mutations.Add(new FileMutation(archivePath, CurrentHash(archivePath), encrypted, "保存账号私有 Desktop 状态 DPAPI 存档", files.FileExists(archivePath)));
        }
        return new DesktopStatePlan(mutations, CountProjects(root), completed, envelope is not null);
    }

    private JsonObject ReadArchive(string path)
    {
        if (!files.FileExists(path)) return new JsonObject
        {
            ["version"] = 1,
            ["codex_home"] = paths.CodexHome,
            ["profiles"] = new JsonObject(),
            ["api"] = new JsonObject { ["atoms"] = new JsonObject(), ["globals"] = new JsonObject() }
        };
        var encrypted = files.ReadAllBytes(path);
        var plain = protector.Unprotect(encrypted);
        try { return JsonNode.Parse(plain) as JsonObject ?? throw new InvalidDataException("Desktop renderer archive 顶层必须是对象。"); }
        catch (JsonException ex) { throw new InvalidDataException("Desktop renderer archive 无法解析；未修改状态文件。", ex); }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }

    private void ValidateArchive(JsonObject archive)
    {
        if (archive["version"]?.GetValue<int>() != 1 || archive["codex_home"]?.GetValue<string>() != paths.CodexHome ||
            archive["profiles"] is not JsonObject || archive["api"] is not JsonObject) throw new InvalidDataException("Desktop renderer archive 版本或 CODEX_HOME 不匹配。");
        ValidateProfile(archive["api"]);
        foreach (var (_, profile) in (JsonObject)archive["profiles"]!) ValidateProfile(profile);
    }

    private static JsonObject ValidateProfile(JsonNode? node)
    {
        if (node is not JsonObject profile || profile["atoms"] is not JsonObject || profile["globals"] is not JsonObject) throw new InvalidDataException("Desktop renderer profile 结构无效。");
        ValidateJsonShape(profile, "renderer profile");
        foreach (var key in ((JsonObject)profile["globals"]!).Select(item => item.Key))
            if (!ScopedGlobals.Contains(key, StringComparer.Ordinal)) throw new InvalidDataException("未知 Desktop 账号专属状态字段；停止修改以保护数据。");
        return profile;
    }

    private static JsonObject MakeProfile(JsonObject atoms, JsonObject globals) => new() { ["atoms"] = atoms.DeepClone(), ["globals"] = globals.DeepClone() };

    private static JsonObject Select(JsonObject source, IEnumerable<string> keys)
    {
        var target = new JsonObject();
        foreach (var key in keys) if (source.ContainsKey(key)) target[key] = source[key]?.DeepClone();
        return target;
    }

    private static void MergeShared(JsonObject root, JsonObject shared, JsonObject oldLocal)
    {
        foreach (var key in SharedGlobals)
        {
            if (!shared.ContainsKey(key)) continue;
            if (key != "local-projects" && shared[key] is JsonObject incoming && root[key] is JsonObject live)
            {
                if (oldLocal[key] is JsonObject oldMap) foreach (var (id, _) in oldMap) live.Remove(id);
                foreach (var (id, value) in incoming) live[id] = value?.DeepClone();
            }
            else if (key == "projectless-thread-ids" && shared[key] is JsonArray incomingIds && root[key] is JsonArray liveIds)
            {
                var old = oldLocal[key] as JsonArray ?? new JsonArray();
                var ids = liveIds.Where(item => item is not null && !old.Any(oldId => JsonNode.DeepEquals(item, oldId)))
                    .Concat(incomingIds.Where(item => item is not null)).GroupBy(item => item!.ToJsonString(), StringComparer.Ordinal).Select(group => group.First()!.DeepClone()).ToArray();
                root[key] = new JsonArray(ids);
            }
            else root[key] = shared[key]?.DeepClone();
        }
    }

    private static void ValidateGlobalTypes(JsonObject root)
    {
        foreach (var key in new[] { "active-workspace-roots", "electron-saved-workspace-roots", "project-order", "projectless-thread-ids", "pinned-thread-ids" })
            if (root[key] is not null && root[key] is not JsonArray) throw new InvalidDataException($"Codex Desktop global state 的 {key} 字段必须是数组。");
        if (root["local-projects"] is not null && root["local-projects"] is not JsonObject) throw new InvalidDataException("Codex Desktop local-projects 字段必须是对象。");
    }

    private static void ValidateJsonShape(JsonNode? node, string location)
    {
        if (node is JsonObject obj)
        {
            if (obj.Count == 1 && obj.TryGetPropertyValue("Length", out var length) && length is JsonValue && length.GetValueKind() == JsonValueKind.Number) throw new InvalidDataException($"检测到已知的损坏标量 {location}；未覆盖源文件。");
            foreach (var (key, value) in obj) ValidateJsonShape(value, location + "." + key);
        }
        else if (node is JsonArray array) foreach (var value in array) ValidateJsonShape(value, location + "[]");
    }

    private static int CountProjects(JsonObject root) => root["local-projects"] is JsonObject projects ? projects.Count : 0;
    private string? CurrentHash(string path) => files.FileExists(path) ? Hash(files.ReadAllBytes(path)) : null;
    private static string Hash(ReadOnlySpan<byte> data) => Convert.ToHexString(SHA256.HashData(data)).ToLowerInvariant();
    private static string? ReadOwner(string? auth) => string.IsNullOrWhiteSpace(auth) ? null : CodexAuthAdapter.Inspect(auth).OfficialOwner;
    private static void ValidateOwner(string owner) { if (!System.Text.RegularExpressions.Regex.IsMatch(owner, "^[a-f0-9]{64}$")) throw new InvalidDataException("Desktop renderer owner 格式无效。"); }
}
