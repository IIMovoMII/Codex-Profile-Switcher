using System.Text.Json;
using System.Text.RegularExpressions;
using Switcher.Core.Abstractions;
using Switcher.Core.Paths;

namespace Switcher.Infrastructure.Storage;

public sealed record StorageMaintenanceResult(int BackupsRemoved, int DownloadsRemoved, long BytesRemoved)
{
    public string Message => BackupsRemoved + DownloadsRemoved == 0 ? "存储检查完成，无需清理。" :
        $"已清理 {BackupsRemoved} 份过期备份、{DownloadsRemoved} 个更新缓存，释放 {BytesRemoved / 1024d / 1024d:0.0} MB。";
}

/// <summary>Only recognized, completed recovery sets and application-owned downloads are disposable.</summary>
public sealed class StorageMaintenanceService(SwitcherPaths paths, IOperationLock operationLock)
{
    public const int BackupsPerCategory = 3;
    public const long BackupBudgetBytes = 256L * 1024 * 1024;
    public const string PolicyDescription = "每类已完成备份最多保留 3 份，超过 14 天或合计超过 256 MB 时优先清理较旧备份（每类至少留最新 1 份）。更新安装包只保留最近 1 个，未完成下载超过 24 小时后清理。待恢复、无法识别的备份及账号、聊天和模型目录不参与清理。";

    public async Task<StorageMaintenanceResult> MaintainAsync(string? protectedInstaller = null, CancellationToken cancellationToken = default)
    {
        await using var lease = await operationLock.AcquireAsync(paths.DataDirectory, cancellationToken).ConfigureAwait(false);
        return Maintain(protectedInstaller);
    }

    public async Task<StorageMaintenanceResult?> TryMaintainAsync(string? protectedInstaller = null)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromMilliseconds(200));
        try { return await Task.Run(() => MaintainAsync(protectedInstaller, timeout.Token)).ConfigureAwait(false); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or OperationCanceledException or ArgumentException or InvalidDataException) { return null; }
    }

    private StorageMaintenanceResult Maintain(string? protectedInstaller)
    {
        var removed = 0; var bytes = 0L;
        // A durable transaction can still own restore sources. Never prune during its recovery.
        if (!File.Exists(paths.TransactionFile))
        {
            var sets = ReadCompletedSets(paths.HistoryBackupsDirectory, history: true)
                .Concat(ReadCompletedSets(paths.ProjectBackupsDirectory, history: false)).ToArray();
            var keep = sets.GroupBy(item => item.Category).SelectMany(group => group.OrderByDescending(item => item.Time).Take(BackupsPerCategory)).ToHashSet();
            var newest = sets.GroupBy(item => item.Category).Select(group => group.MaxBy(item => item.Time)!).ToHashSet();
            var now = DateTimeOffset.UtcNow;
            foreach (var item in keep.Where(item => !newest.Contains(item) && now - item.Time > TimeSpan.FromDays(14)).ToArray()) keep.Remove(item);
            var total = keep.Sum(item => item.Bytes);
            foreach (var item in keep.OrderBy(item => item.Time).ToArray())
            {
                if (total <= BackupBudgetBytes) break;
                if (newest.Contains(item)) continue;
                keep.Remove(item); total -= item.Bytes;
            }
            foreach (var item in sets.Where(item => !keep.Contains(item)))
                if (TryDeleteSet(item)) { removed++; bytes += item.Bytes; }
        }
        var cache = CleanDownloads(Path.Combine(paths.DataDirectory, "updates"), protectedInstaller);
        return new(removed, cache.DownloadsRemoved, bytes + cache.BytesRemoved);
    }

    private IEnumerable<BackupSet> ReadCompletedSets(string root, bool history)
    {
        if (!Directory.Exists(root) || IsLink(root) || IsLink(paths.DataDirectory)) yield break;
        if (history && File.Exists(Path.Combine(root, "active-transaction.json"))) yield break;
        var references = history ? BackupInventory.ReferencedSets(root) : (Names: new HashSet<string>(), Unknown: false);
        foreach (var directory in Directory.EnumerateDirectories(root, "*", SearchOption.TopDirectoryOnly))
        {
            if (!Regex.IsMatch(Path.GetFileName(directory), "^" + BackupInventory.DirectoryPattern + "$") || IsLink(directory) || references.Names.Contains(Path.GetFileName(directory))) continue;
            var manifest = Path.Combine(directory, "manifest.json");
            BackupSet? set = null;
            try
            {
                if (!File.Exists(manifest) || IsLink(manifest) || new FileInfo(manifest).Length > 8 * 1024 * 1024) continue;
                var content = File.ReadAllBytes(manifest);
                using var json = JsonDocument.Parse(content);
                var node = json.RootElement;
                if (!node.TryGetProperty("version", out var version) || !version.TryGetInt32(out var number)) continue;
                var legacy = history && !node.TryGetProperty("codexHome", out _);
                if (legacy && (number is < 1 or > 3 || references.Unknown)) continue;
                if (!legacy && !(history ? number is 2 or 3 : number == 1)) continue;
                if (!node.TryGetProperty(history && !legacy ? "codexHome" : "codex_home", out var home) ||
                    !string.Equals(home.GetString(), paths.CodexHome, StringComparison.OrdinalIgnoreCase)) continue;
                if (!node.TryGetProperty("status", out var state) || state.GetString() is not ("complete" or "rolled_back" or "rolled-back" or "failed")) continue;
                if (legacy && state.GetString() == "failed") continue;
                var inventory = legacy ? BackupInventory.ReadLegacy(directory, node, paths.CodexHome) : BackupInventory.ReadTree(directory);
                if (inventory is null) continue;
                if (!legacy && (inventory.Directories.Length > 0 || inventory.Files.Any(path => !KnownBackupFile(Path.GetFileName(path), history)))) continue;
                set = new(directory, root, File.GetLastWriteTimeUtc(manifest), inventory.Files.Sum(path => new FileInfo(path).Length), content, inventory);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or InvalidOperationException or FormatException or ArgumentException or NotSupportedException) { }
            if (set is not null) yield return set;
        }
    }

    private static bool KnownBackupFile(string name, bool history) => name == "manifest.json" || (history
        ? Regex.IsMatch(name, @"^(jsonl-\d{6}|db-\d{4}-.+)\.bak(-wal|-shm)?$")
        : name is "state_5.sqlite" or "state_5.sqlite-wal" or "state_5.sqlite-shm" or ".codex-global-state.json");

    private static bool TryDeleteSet(BackupSet set)
    {
        try
        {
            if (IsLink(set.Directory) || IsLink(set.Category)) return false;
            var manifest = Path.Combine(set.Directory, "manifest.json");
            if (!File.ReadAllBytes(manifest).AsSpan().SequenceEqual(set.Manifest)) return false;
            if (!set.Inventory.Matches(BackupInventory.ReadTree(set.Directory))) return false;
            // Keep the manifest until the remaining files have been removed; no recursive traversal.
            foreach (var path in set.Inventory.Files.Where(path => path != manifest)) File.Delete(path);
            foreach (var path in set.Inventory.Directories.OrderByDescending(path => path.Length)) Directory.Delete(path);
            File.Delete(manifest); Directory.Delete(set.Directory); return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return false; }
    }

    public static StorageMaintenanceResult CleanDownloads(string root, string? protectedInstaller = null)
    {
        var removed = 0; var bytes = 0L;
        if (!Directory.Exists(root) || IsLink(root) || IsLink(Path.GetDirectoryName(root)!)) return new(0, 0, 0);
        var downloads = Directory.EnumerateFiles(root, "Codex-Profile-Switcher-Setup-*", SearchOption.TopDirectoryOnly)
            .Where(path => !IsLink(path) && Regex.IsMatch(Path.GetFileName(path), @"^Codex-Profile-Switcher-Setup-\d+\.\d+\.\d+(\.\d+)?\.exe(\.sha256|\.partial-[a-f0-9]{32})?$"))
            .Select(path => new FileInfo(path)).ToArray();
        var keep = protectedInstaller is null ? downloads.Where(file => file.Extension == ".exe").MaxBy(file => file.LastWriteTimeUtc)?.FullName : Path.GetFullPath(protectedInstaller);
        foreach (var file in downloads)
        {
            if (string.Equals(file.FullName, keep, StringComparison.OrdinalIgnoreCase) || string.Equals(file.FullName, keep + ".sha256", StringComparison.OrdinalIgnoreCase)) continue;
            if (file.Name.Contains(".partial-", StringComparison.Ordinal) && DateTime.UtcNow - file.LastWriteTimeUtc < TimeSpan.FromDays(1)) continue;
            try { var size = file.Length; file.Delete(); removed++; bytes += size; }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        }
        foreach (var file in Directory.EnumerateFiles(root, "check-*.json", SearchOption.TopDirectoryOnly).Select(path => new FileInfo(path)))
        {
            try
            {
                if (!Regex.IsMatch(file.Name, @"^check-[a-f0-9]{32}\.json$") || IsLink(file.FullName) || file.Length > 16384 || DateTime.UtcNow - file.LastWriteTimeUtc < TimeSpan.FromDays(1)) continue;
                using var document = JsonDocument.Parse(File.ReadAllBytes(file.FullName)); var node = document.RootElement;
                if (node.ValueKind != JsonValueKind.Object || node.EnumerateObject().Count() != 2 || !node.TryGetProperty("state", out var state) ||
                    state.ValueKind != JsonValueKind.String || state.GetString() is not ("error" or "success" or "up-to-date" or "update-available") || !node.TryGetProperty("message", out var message) || message.ValueKind != JsonValueKind.String) continue;
                var size = file.Length; file.Delete(); removed++; bytes += size;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException) { }
        }
        return new(0, removed, bytes);
    }

    private static bool IsLink(string path) => (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
    private sealed record BackupSet(string Directory, string Category, DateTimeOffset Time, long Bytes, byte[] Manifest, BackupInventory Inventory);
}
