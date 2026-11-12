using System.Text;
using Microsoft.Data.Sqlite;
using Switcher.Core.Abstractions;
using Switcher.Core.Paths;
using Switcher.Infrastructure.Files;
using Switcher.Infrastructure.History;

namespace Switcher.Infrastructure.Tests;

public sealed class HistoryCompatibilityBehaviorTests
{
    [Fact]
    public async Task Preparation_rewrites_related_history_once_and_keeps_a_wal_backup()
    {
        using var fixture = new Fixture();
        fixture.CreateWalDatabase();
        var firstFile = Path.Combine(fixture.Paths.CodexHome, "sessions", "rollout-1.jsonl");
        Directory.CreateDirectory(Path.GetDirectoryName(firstFile)!);
        var originalFirst = Encoding.UTF8.GetBytes(
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread-a\",\"model_provider\":\"relay\",\"unknown\":\"保持\"}}\r\n" +
            "{\"type\":\"event_msg\",\"payload\":{\"type\":\"thread_settings_applied\",\"thread_id\":\"thread-a\",\"thread_settings\":{\"model_provider_id\":\"relay\"}}}\n");
        fixture.Files.WriteAtomic(firstFile, originalFirst);

        var first = await fixture.Service.PrepareAsync(false, null, CancellationToken.None);

        Assert.True(first.Prepared);
        Assert.True(first.Changed);
        Assert.Equal(1, first.FileCount);
        Assert.Equal("openai", Fixture.ReadJsonProvider(firstFile, "payload", "model_provider"));
        Assert.Contains("\"unknown\":\"保持\"", File.ReadAllText(firstFile));
        Assert.Contains("\"model_provider_id\":\"openai\"", File.ReadAllText(firstFile));
        Assert.Equal("openai", fixture.ReadProvider("thread-a"));
        Assert.Equal("relay", fixture.ReadProvider("unrelated"));

        var databaseBackup = Path.Combine(first.BackupDirectory, "db-0000-state_5.sqlite.bak");
        Assert.True(File.Exists(databaseBackup));
        Assert.Equal("relay", fixture.ReadProvider(databaseBackup, "thread-a"));
        Assert.Equal("ok", fixture.ReadProvider(databaseBackup, "quick_check"));

        var backupCount = Directory.GetDirectories(fixture.Paths.HistoryBackupsDirectory).Length;
        var unchanged = await fixture.Service.PrepareAsync(false, null, CancellationToken.None);
        Assert.True(unchanged.Prepared);
        Assert.False(unchanged.Changed);
        Assert.Equal(backupCount, Directory.GetDirectories(fixture.Paths.HistoryBackupsDirectory).Length);

        var secondFile = Path.Combine(fixture.Paths.CodexHome, "sessions", "rollout-2.jsonl");
        fixture.Files.WriteAtomic(secondFile, Encoding.UTF8.GetBytes(
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread-b\",\"model_provider\":\"future_provider\"}}\n"));
        fixture.InsertThread("thread-b", "future_provider");

        var incremental = await fixture.Service.PrepareAsync(false, null, CancellationToken.None);

        Assert.True(incremental.Prepared);
        Assert.True(incremental.Changed);
        Assert.Equal("openai", Fixture.ReadJsonProvider(secondFile, "payload", "model_provider"));
        Assert.Equal("openai", fixture.ReadProvider("thread-b"));
        Assert.Equal("openai", fixture.ReadProvider("thread-a"));
        Assert.Equal("relay", fixture.ReadProvider("unrelated"));
        var incrementalBackup = Path.Combine(incremental.BackupDirectory, "db-0000-state_5.sqlite.bak");
        Assert.Equal("future_provider", fixture.ReadProvider(incrementalBackup, "thread-b"));
    }

    [Fact]
    public async Task Failure_after_sqlite_commit_restores_jsonl_and_wal_database_from_durable_backup()
    {
        using var fixture = new Fixture();
        fixture.CreateWalDatabase();
        var historyFile = Path.Combine(fixture.Paths.CodexHome, "sessions", "rollout.jsonl");
        Directory.CreateDirectory(Path.GetDirectoryName(historyFile)!);
        var original = Encoding.UTF8.GetBytes("{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread-a\",\"model_provider\":\"relay\"}}\n");
        fixture.Files.WriteAtomic(historyFile, original);
        var failingFiles = new FailOnceFileSystem(fixture.Files, fixture.Paths.HistoryReadyFile);
        var service = fixture.CreateService(failingFiles);

        await Assert.ThrowsAsync<InvalidOperationException>(() => service.PrepareAsync(false, null, CancellationToken.None));

        Assert.Equal(original, fixture.Files.ReadAllBytes(historyFile));
        Assert.Equal("relay", fixture.ReadProvider("thread-a"));
        Assert.Equal("relay", fixture.ReadProvider("unrelated"));
        Assert.False(fixture.Files.FileExists(fixture.Paths.HistoryReadyFile));
        var manifestPath = Directory.GetFiles(fixture.Paths.HistoryBackupsDirectory, "manifest.json", SearchOption.AllDirectories).Single();
        using var manifest = System.Text.Json.JsonDocument.Parse(File.ReadAllBytes(manifestPath));
        Assert.Equal("rolled_back", manifest.RootElement.GetProperty("status").GetString());
        var backupPath = Path.Combine(Path.GetDirectoryName(manifestPath)!, "db-0000-state_5.sqlite.bak");
        Assert.Equal("relay", fixture.ReadProvider(backupPath, "thread-a"));
    }

    [Fact]
    public async Task Restart_recovery_rolls_back_partial_work_and_completes_fully_applied_work()
    {
        using var fixture = new Fixture();
        fixture.CreateWalDatabase();
        var historyFile = Path.Combine(fixture.Paths.CodexHome, "sessions", "rollout.jsonl");
        Directory.CreateDirectory(Path.GetDirectoryName(historyFile)!);
        var original = Encoding.UTF8.GetBytes("{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread-a\",\"model_provider\":\"relay\"}}\n");
        var target = Encoding.UTF8.GetBytes("{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread-a\",\"model_provider\":\"openai\"}}\n");
        fixture.Files.WriteAtomic(historyFile, original);

        var partialManifest = fixture.WritePreparedManifest("partial", historyFile, original, target);
        fixture.Files.WriteAtomic(historyFile, target);
        var partialRecovery = await fixture.Service.RecoverPendingOperationsAsync();

        Assert.Contains("已回退上次未完成的历史准备", partialRecovery);
        Assert.Equal(original, fixture.Files.ReadAllBytes(historyFile));
        Assert.Equal("relay", fixture.ReadProvider("thread-a"));
        using (var manifest = System.Text.Json.JsonDocument.Parse(File.ReadAllBytes(partialManifest)))
            Assert.Equal("rolled_back", manifest.RootElement.GetProperty("status").GetString());

        var completeManifest = fixture.WritePreparedManifest("complete", historyFile, original, target);
        fixture.Files.WriteAtomic(historyFile, target);
        fixture.UpdateProvider("thread-a", "openai");
        var completedRecovery = await fixture.Service.RecoverPendingOperationsAsync();

        Assert.Contains("已完成上次中断的历史准备", completedRecovery);
        Assert.True(fixture.Files.FileExists(fixture.Paths.HistoryReadyFile));
        Assert.Equal(target, fixture.Files.ReadAllBytes(historyFile));
        Assert.Equal("openai", fixture.ReadProvider("thread-a"));
        using (var manifest = System.Text.Json.JsonDocument.Parse(File.ReadAllBytes(completeManifest)))
            Assert.Equal("complete", manifest.RootElement.GetProperty("status").GetString());
        Assert.False(fixture.Service.HasPendingRecovery);
    }

    [Fact]
    public async Task Recovery_refuses_to_overwrite_a_history_file_changed_after_interruption()
    {
        using var fixture = new Fixture();
        fixture.CreateWalDatabase();
        var historyFile = Path.Combine(fixture.Paths.CodexHome, "sessions", "rollout.jsonl");
        Directory.CreateDirectory(Path.GetDirectoryName(historyFile)!);
        var original = Encoding.UTF8.GetBytes("{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread-a\",\"model_provider\":\"relay\"}}\n");
        var target = Encoding.UTF8.GetBytes("{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread-a\",\"model_provider\":\"openai\"}}\n");
        var external = Encoding.UTF8.GetBytes("{\"type\":\"session_meta\",\"payload\":{\"id\":\"thread-a\",\"model_provider\":\"user_change\"}}\n");
        fixture.Files.WriteAtomic(historyFile, original);
        var directory = Path.Combine(fixture.Paths.HistoryBackupsDirectory, "external-change");
        Directory.CreateDirectory(directory);
        var backupPath = Path.Combine(directory, "jsonl-000000.bak");
        fixture.Files.WriteAtomic(backupPath, original);
        var manifestPath = Path.Combine(directory, "manifest.json");
        fixture.Files.WriteAtomic(manifestPath, System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(new
        {
            version = 2,
            codexHome = fixture.Paths.CodexHome,
            status = "prepared",
            files = new[] { new { source = historyFile, backup = backupPath, originalSha256 = Hash(original), targetSha256 = Hash(target) } },
            databases = Array.Empty<object>()
        }));
        fixture.Files.WriteAtomic(historyFile, external);

        var error = await Assert.ThrowsAsync<IOException>(() => fixture.Service.RecoverPendingOperationsAsync());

        Assert.Contains("外部变化", error.Message);
        Assert.Equal(external, fixture.Files.ReadAllBytes(historyFile));
        Assert.True(fixture.Service.HasPendingRecovery);
        using var manifest = System.Text.Json.JsonDocument.Parse(File.ReadAllBytes(manifestPath));
        Assert.Equal("recovery_required", manifest.RootElement.GetProperty("status").GetString());
        Assert.Equal(original, fixture.Files.ReadAllBytes(backupPath));
    }

    private sealed class Fixture : IDisposable
    {
        private SqliteConnection? _writer;

        public Fixture()
        {
            Root = Path.Combine(Path.GetTempPath(), "codex-history-test-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Root);
            Paths = SwitcherPaths.FromEnvironment(Path.Combine(Root, "codex home"), Path.Combine(Root, "switcher data"),
                environment: new Dictionary<string, string?> { ["USERPROFILE"] = Root, ["LOCALAPPDATA"] = Path.Combine(Root, "local") });
            Files = new PhysicalSwitcherFileSystem();
            Service = new HistoryCompatibilityService(Files, Paths);
        }

        public string Root { get; }
        public SwitcherPaths Paths { get; }
        public PhysicalSwitcherFileSystem Files { get; }
        public HistoryCompatibilityService Service { get; }
        public HistoryCompatibilityService CreateService(ISwitcherFileSystem files) => new(files, Paths);

        public void CreateWalDatabase()
        {
            Directory.CreateDirectory(Paths.CodexHome);
            _writer = Open(Paths.ProjectStateDatabase, SqliteOpenMode.ReadWriteCreate);
            using var command = _writer.CreateCommand();
            command.CommandText = "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE threads(id TEXT PRIMARY KEY,model_provider TEXT NOT NULL); INSERT INTO threads VALUES('thread-a','relay'),('unrelated','relay');";
            command.ExecuteNonQuery();
        }

        public void InsertThread(string id, string provider)
        {
            using var command = _writer!.CreateCommand();
            command.CommandText = "INSERT INTO threads(id,model_provider) VALUES($id,$provider)";
            command.Parameters.AddWithValue("$id", id);
            command.Parameters.AddWithValue("$provider", provider);
            command.ExecuteNonQuery();
        }

        public void UpdateProvider(string id, string provider)
        {
            using var command = _writer!.CreateCommand();
            command.CommandText = "UPDATE threads SET model_provider=$provider WHERE id=$id";
            command.Parameters.AddWithValue("$id", id);
            command.Parameters.AddWithValue("$provider", provider);
            command.ExecuteNonQuery();
        }

        public string WritePreparedManifest(string name, string source, byte[] original, byte[] target)
        {
            var directory = Path.Combine(Paths.HistoryBackupsDirectory, name);
            Directory.CreateDirectory(directory);
            var fileBackup = Path.Combine(directory, "jsonl-000000.bak");
            Files.WriteAtomic(fileBackup, original);
            var databaseBackup = Path.Combine(directory, "db-0000-state_5.sqlite.bak");
            BackupDatabase(Paths.ProjectStateDatabase, databaseBackup);
            var manifestPath = Path.Combine(directory, "manifest.json");
            var manifest = new
            {
                version = 2,
                codexHome = Paths.CodexHome,
                status = "prepared",
                files = new[] { new { source, backup = fileBackup, originalSha256 = Hash(original), targetSha256 = Hash(target) } },
                databases = new[] { new { source = Paths.ProjectStateDatabase, backup = databaseBackup, rows = new[] { new { threadId = "thread-a", oldProvider = "relay" } } } }
            };
            Files.WriteAtomic(manifestPath, System.Text.Json.JsonSerializer.SerializeToUtf8Bytes(manifest));
            return manifestPath;
        }

        public string ReadProvider(string id) => ReadProvider(Paths.ProjectStateDatabase, id);

        public string ReadProvider(string database, string id)
        {
            using var connection = Open(database, SqliteOpenMode.ReadOnly);
            using var command = connection.CreateCommand();
            command.CommandText = id == "quick_check" ? "PRAGMA quick_check" : "SELECT model_provider FROM threads WHERE id=$id";
            if (id != "quick_check") command.Parameters.AddWithValue("$id", id);
            return Convert.ToString(command.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture)!;
        }

        public static string ReadJsonProvider(string path, params string[] propertyPath)
        {
            using var document = System.Text.Json.JsonDocument.Parse(File.ReadLines(path).First());
            var current = document.RootElement;
            foreach (var property in propertyPath) current = current.GetProperty(property);
            return current.GetString()!;
        }

        private static SqliteConnection Open(string path, SqliteOpenMode mode)
        {
            var connection = new SqliteConnection(new SqliteConnectionStringBuilder
            {
                DataSource = path,
                Mode = mode,
                Pooling = false
            }.ConnectionString);
            connection.Open();
            return connection;
        }

        private static void BackupDatabase(string sourcePath, string backupPath)
        {
            using var source = Open(sourcePath, SqliteOpenMode.ReadOnly);
            using var destination = Open(backupPath, SqliteOpenMode.ReadWriteCreate);
            source.BackupDatabase(destination);
        }

        public void Dispose()
        {
            _writer?.Dispose();
            try { Directory.Delete(Root, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }

    private static string Hash(ReadOnlySpan<byte> bytes) => Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(bytes)).ToLowerInvariant();

    private sealed class FailOnceFileSystem(ISwitcherFileSystem inner, string failPath) : ISwitcherFileSystem
    {
        private bool _failed;
        public bool FileExists(string path) => inner.FileExists(path);
        public bool DirectoryExists(string path) => inner.DirectoryExists(path);
        public byte[] ReadAllBytes(string path) => inner.ReadAllBytes(path);
        public string ReadAllText(string path) => inner.ReadAllText(path);
        public DateTimeOffset GetLastWriteTimeUtc(string path) => inner.GetLastWriteTimeUtc(path);
        public void WriteAtomic(string path, ReadOnlySpan<byte> contents)
        {
            if (!_failed && string.Equals(Path.GetFullPath(path), Path.GetFullPath(failPath), StringComparison.OrdinalIgnoreCase))
            {
                _failed = true;
                throw new IOException("injected ready-stamp failure");
            }
            inner.WriteAtomic(path, contents);
        }
        public bool TryCreateAtomic(string path, ReadOnlySpan<byte> contents) => inner.TryCreateAtomic(path, contents);
        public void DeleteFile(string path) => inner.DeleteFile(path);
        public void CreateDirectory(string path) => inner.CreateDirectory(path);
        public IEnumerable<string> EnumerateFiles(string path, string pattern, SearchOption option) => inner.EnumerateFiles(path, pattern, option);
    }
}
