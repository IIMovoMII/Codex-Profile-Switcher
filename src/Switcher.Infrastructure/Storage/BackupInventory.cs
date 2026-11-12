using System.Text.Json;
using System.Text.RegularExpressions;

namespace Switcher.Infrastructure.Storage;

internal sealed record BackupInventory(string[] Files, string[] Directories)
{
    internal const string DirectoryPattern = @"\d{8}T\d{9}Z-[a-f0-9]{32}";
    internal static bool IsLink(string path) => (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;

    // Legacy backups may contain nested sessions. Delete only entries declared by a recognized terminal manifest.
    internal static BackupInventory? ReadLegacy(string directory, JsonElement manifest, string home)
    {
        if (!manifest.TryGetProperty("files", out var files) || files.ValueKind != JsonValueKind.Array) return null;
        var allowed = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { Path.Combine(directory, "manifest.json") };
        foreach (var arrayName in new[] { "files", "databases" })
        {
            if (!manifest.TryGetProperty(arrayName, out var entries)) continue;
            if (entries.ValueKind != JsonValueKind.Array) return null;
            foreach (var entry in entries.EnumerateArray())
            {
                if (entry.ValueKind != JsonValueKind.Object || !entry.TryGetProperty("backup_path", out var backup) || backup.ValueKind != JsonValueKind.String ||
                    !entry.TryGetProperty("path", out var source) || source.ValueKind != JsonValueKind.String) return null;
                var target = backup.GetString()!;
                if (!Within(target, directory) || !Within(source.GetString()!, home) || !File.Exists(target)) return null;
                allowed.Add(Path.GetFullPath(target));
                foreach (var suffix in new[] { "-wal", "-shm" }) if (File.Exists(target + suffix)) allowed.Add(Path.GetFullPath(target + suffix));
            }
        }
        var inventory = ReadTree(directory);
        if (inventory is null || !inventory.Files.ToHashSet(StringComparer.OrdinalIgnoreCase).SetEquals(allowed)) return null;
        // Extra empty folders can be user material; only retain parents of declared files in the inventory.
        if (inventory.Directories.Any(folder => !allowed.Any(file => Within(file, folder)))) return null;
        return inventory;
    }

    internal static BackupInventory? ReadTree(string root)
    {
        var files = new List<string>(); var directories = new List<string>(); var pending = new Stack<string>(); pending.Push(root);
        while (pending.Count > 0)
        {
            var parent = pending.Pop();
            if (IsLink(parent) || (parent != root && !Within(parent, root))) return null;
            foreach (var entry in Directory.EnumerateFileSystemEntries(parent))
            {
                if (!Within(entry, root) || IsLink(entry)) return null;
                if (Directory.Exists(entry)) { directories.Add(entry); pending.Push(entry); } else files.Add(entry);
            }
        }
        return new(files.ToArray(), directories.ToArray());
    }

    internal bool Matches(BackupInventory? other) => other is not null &&
        Files.ToHashSet(StringComparer.OrdinalIgnoreCase).SetEquals(other.Files) && Directories.ToHashSet(StringComparer.OrdinalIgnoreCase).SetEquals(other.Directories);

    internal static bool Within(string path, string root) => Path.IsPathFullyQualified(path) &&
        Path.GetFullPath(path).StartsWith(Path.TrimEndingDirectorySeparator(Path.GetFullPath(root)) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);

    internal static (HashSet<string> Names, bool Unknown) ReferencedSets(string root)
    {
        var referenced = new HashSet<string>(StringComparer.OrdinalIgnoreCase); var unknown = false;
        foreach (var folder in Directory.EnumerateDirectories(root))
        {
            if (IsLink(folder)) { unknown = true; continue; }
            Read(Path.Combine(folder, "manifest.json"), Path.GetFileName(folder));
        }
        foreach (var file in Directory.EnumerateFiles(root, "*.json", SearchOption.TopDirectoryOnly)) Read(file, "");
        return (referenced, unknown);

        void Read(string path, string owner)
        {
            try
            {
                if (!File.Exists(path)) return;
                if (IsLink(path) || new FileInfo(path).Length > 8 * 1024 * 1024) { unknown = true; return; }
                var text = File.ReadAllText(path); using var document = JsonDocument.Parse(text);
                foreach (Match match in Regex.Matches(text, DirectoryPattern, RegexOptions.IgnoreCase, TimeSpan.FromSeconds(1)))
                    if (!match.Value.Equals(owner, StringComparison.OrdinalIgnoreCase)) referenced.Add(match.Value);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException) { unknown = true; }
        }
    }
}
