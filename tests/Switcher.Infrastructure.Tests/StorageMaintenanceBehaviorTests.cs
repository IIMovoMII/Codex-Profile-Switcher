using System.Text.Json;
using Switcher.Core.Paths;
using Switcher.Infrastructure.Processes;
using Switcher.Infrastructure.Storage;

namespace Switcher.Infrastructure.Tests;

public sealed class StorageMaintenanceBehaviorTests
{
    [Fact]
    public async Task Retention_bounds_completed_sets_but_preserves_pending_unknown_and_user_material()
    {
        using var fixture = new Fixture();
        var completed = Enumerable.Range(0, 6).Select(index => fixture.Backup(history: true, index)).ToArray();
        var project = Enumerable.Range(0, 5).Select(index => fixture.Backup(history: false, index)).ToArray();
        var pending = fixture.Backup(true, 10, "prepared"); var recovery = fixture.Backup(true, 11, "recovery_required");
        var unknown = fixture.Backup(true, 12); File.WriteAllText(Path.Combine(unknown, "my-notes.txt"), "keep");
        var broken = fixture.Backup(true, 13); File.WriteAllText(Path.Combine(broken, "manifest.json"), "broken");
        File.WriteAllText(fixture.Paths.DefaultManualModelCatalogFile, "manual"); Directory.CreateDirectory(fixture.Paths.ModelCatalogDirectory);
        File.WriteAllText(Path.Combine(fixture.Paths.ModelCatalogDirectory, "official.json"), "snapshot");
        var result = await fixture.Service.MaintainAsync();
        Assert.Equal(5, result.BackupsRemoved); Assert.True(result.BytesRemoved > 0);
        Assert.All(completed.Take(3), path => Assert.False(Directory.Exists(path))); Assert.All(completed.Skip(3), path => Assert.True(Directory.Exists(path)));
        Assert.All(project.Take(2), path => Assert.False(Directory.Exists(path))); Assert.All(project.Skip(2), path => Assert.True(Directory.Exists(path)));
        Assert.All(new[] { pending, recovery, unknown, broken }, path => Assert.True(Directory.Exists(path)));
        Assert.Equal("manual", File.ReadAllText(fixture.Paths.DefaultManualModelCatalogFile)); Assert.Equal("snapshot", File.ReadAllText(Path.Combine(fixture.Paths.ModelCatalogDirectory, "official.json")));
    }

    [Fact]
    public async Task Old_backups_keep_one_latest_set_per_category_and_never_delete_other_home_backups()
    {
        using var fixture = new Fixture(); var old = fixture.Backup(true, -30); var latest = fixture.Backup(true, -20); var foreign = fixture.Backup(true, -40, foreign: true);
        var project = fixture.Backup(false, -35);
        var result = await fixture.Service.MaintainAsync();
        Assert.Equal(1, result.BackupsRemoved); Assert.False(Directory.Exists(old));
        Assert.True(Directory.Exists(latest)); Assert.True(Directory.Exists(project)); Assert.True(Directory.Exists(foreign));
    }

    [Fact]
    public async Task Size_budget_prunes_older_sets_but_retains_the_latest_recovery_source()
    {
        using var fixture = new Fixture(); var directories = Enumerable.Range(0, 3).Select(index => fixture.Backup(true, index)).ToArray();
        foreach (var directory in directories)
        {
            using var file = File.OpenWrite(Path.Combine(directory, "jsonl-000000.bak")); file.SetLength(100L * 1024 * 1024);
        }
        var result = await fixture.Service.MaintainAsync();
        Assert.Equal(1, result.BackupsRemoved); Assert.False(Directory.Exists(directories[0])); Assert.True(Directory.Exists(directories[2]));
    }

    [Fact]
    public async Task Pending_auth_transaction_or_busy_operation_prevents_backup_pruning()
    {
        using var fixture = new Fixture(); var directories = Enumerable.Range(0, 5).Select(index => fixture.Backup(true, index)).ToArray();
        File.WriteAllText(fixture.Paths.TransactionFile, "synthetic recovery sentinel");
        Assert.Equal(0, (await fixture.Service.MaintainAsync()).BackupsRemoved); File.Delete(fixture.Paths.TransactionFile);
        await using (await fixture.Lock.AcquireAsync(fixture.Paths.DataDirectory, CancellationToken.None))
            Assert.Null(await fixture.Service.TryMaintainAsync());
        Assert.All(directories, path => Assert.True(Directory.Exists(path)));
    }

    [Fact]
    public async Task Legacy_terminal_backups_are_bounded_but_referenced_sets_and_unknown_nested_files_are_protected()
    {
        using var fixture = new Fixture(); var completed = Enumerable.Range(0, 7).Select(index => fixture.LegacyBackup(index)).ToArray();
        var referenced = completed[0]; var pending = fixture.LegacyBackup(10, "applying", referenced);
        var manual = fixture.LegacyBackup(11); File.WriteAllText(Path.Combine(manual, "sessions", "user-note.txt"), "preserve");
        var result = await fixture.Service.MaintainAsync();
        Assert.Equal(3, result.BackupsRemoved); Assert.True(Directory.Exists(referenced)); Assert.True(Directory.Exists(pending)); Assert.True(Directory.Exists(manual));
        Assert.All(completed.Skip(1).Take(3), path => Assert.False(Directory.Exists(path))); Assert.All(completed.Skip(4), path => Assert.True(Directory.Exists(path)));
    }

    [Fact]
    public async Task Legacy_active_transaction_and_paths_outside_a_backup_set_are_never_deleted()
    {
        using var fixture = new Fixture(); var directories = Enumerable.Range(0, 5).Select(index => fixture.LegacyBackup(index)).ToArray();
        File.WriteAllText(Path.Combine(fixture.Paths.HistoryBackupsDirectory, "active-transaction.json"), "{}");
        Assert.Equal(0, (await fixture.Service.MaintainAsync()).BackupsRemoved); Assert.All(directories, path => Assert.True(Directory.Exists(path)));
        File.Delete(Path.Combine(fixture.Paths.HistoryBackupsDirectory, "active-transaction.json"));
        var outside = Path.Combine(fixture.Root, "external-material.jsonl"); File.WriteAllText(outside, "keep");
        File.WriteAllText(Path.Combine(directories[0], "manifest.json"), JsonSerializer.Serialize(new { version = 3, codex_home = fixture.Paths.CodexHome, status = "complete", files = new[] { new { path = Path.Combine(fixture.Paths.CodexHome, "session.jsonl"), backup_path = outside } } }));
        await fixture.Service.MaintainAsync(); Assert.True(Directory.Exists(directories[0])); Assert.Equal("keep", File.ReadAllText(outside));
    }

    [Fact]
    public void Cache_keeps_current_installer_and_recent_partial_download_and_ignores_unowned_files()
    {
        using var fixture = new Fixture(); var directory = Path.Combine(fixture.Paths.DataDirectory, "updates"); Directory.CreateDirectory(directory);
        string Write(string name, int days) { var path = Path.Combine(directory, name); File.WriteAllText(path, name); File.SetLastWriteTimeUtc(path, DateTime.UtcNow.AddDays(days)); return path; }
        var previous = Write("Codex-Profile-Switcher-Setup-0.3.7.exe", -3);
        var current = Write("Codex-Profile-Switcher-Setup-0.3.9.exe", -4); // Protected verified package wins even if its file timestamp is older.
        var expired = Write("Codex-Profile-Switcher-Setup-0.4.0.exe.partial-" + Guid.NewGuid().ToString("N"), -2);
        var active = Write("Codex-Profile-Switcher-Setup-0.4.0.exe.partial-" + Guid.NewGuid().ToString("N"), 0);
        var manual = Write("my-downloaded-file.exe", -50);
        var oldCheck = Write("check-" + Guid.NewGuid().ToString("N") + ".json", -2); File.WriteAllText(oldCheck, "{\"state\":\"error\",\"message\":\"old result\"}"); File.SetLastWriteTimeUtc(oldCheck, DateTime.UtcNow.AddDays(-2));
        var result = StorageMaintenanceService.CleanDownloads(directory, current);
        Assert.Equal(3, result.DownloadsRemoved); Assert.False(File.Exists(previous)); Assert.False(File.Exists(expired)); Assert.False(File.Exists(oldCheck));
        Assert.True(File.Exists(current)); Assert.True(File.Exists(active)); Assert.True(File.Exists(manual));
    }

    private sealed class Fixture : IDisposable
    {
        public string Root { get; } = Path.Combine(Path.GetTempPath(), "SwitcherRetention-" + Guid.NewGuid().ToString("N"));
        public SwitcherPaths Paths { get; }
        public WindowsOperationLock Lock { get; } = new();
        public StorageMaintenanceService Service { get; }
        public Fixture() { Paths = new(Path.Combine(Root, "codex"), Path.Combine(Root, "data")); Directory.CreateDirectory(Paths.DataDirectory); Service = new(Paths, Lock); }
        public string Backup(bool history, int index, string status = "complete", bool foreign = false)
        {
            var time = DateTimeOffset.UtcNow.AddDays(index - 6); var root = history ? Paths.HistoryBackupsDirectory : Paths.ProjectBackupsDirectory;
            var directory = Path.Combine(root, time.ToString("yyyyMMddTHHmmssfffZ") + "-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(directory);
            var home = foreign ? Path.Combine(Root, "different-home") : Paths.CodexHome;
            var manifest = Path.Combine(directory, "manifest.json");
            File.WriteAllText(manifest, history ? JsonSerializer.Serialize(new { version = 2, codexHome = home, status, files = Array.Empty<object>(), databases = Array.Empty<object>() }) : JsonSerializer.Serialize(new { version = 1, codex_home = home, status, changes = Array.Empty<object>() }));
            File.WriteAllText(Path.Combine(directory, history ? "jsonl-000000.bak" : "state_5.sqlite"), "synthetic backup"); File.SetLastWriteTimeUtc(manifest, time.UtcDateTime); return directory;
        }
        public string LegacyBackup(int index, string status = "complete", string? referenced = null)
        {
            var time = DateTimeOffset.UtcNow.AddDays(index - 6);
            var directory = Path.Combine(Paths.HistoryBackupsDirectory, time.ToString("yyyyMMddTHHmmssfffZ") + "-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Path.Combine(directory, "sessions")); var backup = Path.Combine(directory, "sessions", "rollout.jsonl"); File.WriteAllText(backup, "legacy synthetic backup");
            var manifest = Path.Combine(directory, "manifest.json");
            File.WriteAllText(manifest, JsonSerializer.Serialize(new { version = 3, codex_home = Paths.CodexHome, status, files = new[] { new { path = Path.Combine(Paths.CodexHome, "sessions", "rollout.jsonl"), backup_path = backup, layout_recovery = referenced } } }));
            File.SetLastWriteTimeUtc(manifest, time.UtcDateTime); return directory;
        }
        public void Dispose() { if (Directory.Exists(Root)) Directory.Delete(Root, true); }
    }
}
