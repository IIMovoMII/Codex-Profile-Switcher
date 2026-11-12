using System.Text;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using Switcher.Core.Abstractions;
using Switcher.Core.Paths;
using Switcher.Infrastructure.Files;
using Switcher.Infrastructure.History;

namespace Switcher.Infrastructure.Tests;

public sealed class ProjectProjectionBehaviorTests
{
    [Fact]
    public async Task Owner_scoped_assignments_are_projected_separately_and_database_backup_is_valid()
    {
        using var fixture = new Fixture();
        fixture.CreateDatabase(wal: true);
        fixture.Execute("INSERT INTO projects VALUES('project-a','A',0,1); INSERT INTO projects VALUES('project-b','B',1,1);");
        fixture.Execute("INSERT INTO project_roots VALUES('project-a',0,'D:\\A'); INSERT INTO project_roots VALUES('project-b',0,'D:\\B');");
        fixture.Execute("INSERT INTO threads(id,cwd,project_id,archived,agent_role,source) VALUES('thread-a','D:\\A',NULL,0,NULL,'vscode'),('thread-b','D:\\B',NULL,0,NULL,'vscode');");
        var ownerA = new string('a', 64);
        var ownerB = new string('b', 64);
        var homeKey = Path.TrimEndingDirectorySeparator(Path.GetFullPath(fixture.Paths.CodexHome));
        var global = new Dictionary<string, object?>
        {
            ["electron-account-renderer-state-v1"] = new Dictionary<string, object?>
            {
                ["owner"] = null,
                ["inactive"] = new Dictionary<string, object?>
                {
                    [ownerA] = InactiveProfile("thread-a", "legacy-a", "project-a", "D:\\A", homeKey),
                    [ownerB] = InactiveProfile("thread-b", "legacy-b", "project-b", "D:\\B", homeKey)
                }
            }
        };
        fixture.Files.WriteAtomic(fixture.Paths.DesktopGlobalStateFile, JsonSerializer.SerializeToUtf8Bytes(global));
        var beforeGlobal = fixture.Files.ReadAllBytes(fixture.Paths.DesktopGlobalStateFile);

        var first = await fixture.Service.PrepareAsync(ownerA, repair: true, inferFromWorkingDirectory: false, null, CancellationToken.None);
        Assert.True(first.Changed);
        Assert.Equal("project-a", fixture.ScalarText("SELECT project_id FROM threads WHERE id='thread-a';"));
        Assert.Null(fixture.ScalarText("SELECT project_id FROM threads WHERE id='thread-b';"));
        Assert.Equal(beforeGlobal, fixture.Files.ReadAllBytes(fixture.Paths.DesktopGlobalStateFile));
        Assert.Equal("ok", fixture.ScalarText("PRAGMA quick_check;"));
        Assert.Null(fixture.ScalarTextFromDatabase(Path.Combine(first.BackupDirectory, "state_5.sqlite"), "SELECT project_id FROM threads WHERE id='thread-a';"));

        var second = await fixture.Service.PrepareAsync(ownerB, repair: true, inferFromWorkingDirectory: false, null, CancellationToken.None);
        Assert.True(second.Changed);
        Assert.Equal("project-a", fixture.ScalarText("SELECT project_id FROM threads WHERE id='thread-a';"));
        Assert.Equal("project-b", fixture.ScalarText("SELECT project_id FROM threads WHERE id='thread-b';"));
    }

    [Fact]
    public async Task Working_directory_inference_is_opt_in_and_uses_the_most_specific_unique_root()
    {
        using var fixture = new Fixture();
        fixture.CreateDatabase();
        fixture.Execute("INSERT INTO projects VALUES('parent','Parent',0,1); INSERT INTO projects VALUES('child','Child',1,1); INSERT INTO projects VALUES('ambiguous','Ambiguous',2,1);");
        fixture.Execute("INSERT INTO project_roots VALUES('parent',0,'D:\\Work'); INSERT INTO project_roots VALUES('child',0,'D:\\Work\\App'); INSERT INTO project_roots VALUES('ambiguous',0,'D:\\Other'); INSERT INTO project_roots VALUES('child',1,'D:\\Other');");
        fixture.Execute("INSERT INTO threads(id,cwd,project_id,archived,agent_role,source) VALUES('nested','D:\\Work\\App\\src',NULL,0,NULL,'vscode'),('ambiguous','D:\\Other\\src',NULL,0,NULL,'vscode');");

        var scan = await fixture.Service.PrepareAsync(null, repair: false, inferFromWorkingDirectory: true, null, CancellationToken.None);
        Assert.Equal(1, scan.PlannedChanges);
        Assert.Null(fixture.ScalarText("SELECT project_id FROM threads WHERE id='nested';"));

        var repair = await fixture.Service.PrepareAsync(null, repair: true, inferFromWorkingDirectory: true, null, CancellationToken.None);
        Assert.Equal("child", fixture.ScalarText("SELECT project_id FROM threads WHERE id='nested';"));
        Assert.Null(fixture.ScalarText("SELECT project_id FROM threads WHERE id='ambiguous';"));
        Assert.Equal(1, repair.PlannedChanges);
    }

    [Fact]
    public async Task Trigger_failure_rolls_back_transaction_and_keeps_recovery_material()
    {
        using var fixture = new Fixture();
        fixture.CreateDatabase();
        fixture.Execute("INSERT INTO projects VALUES('project-a','A',0,1); INSERT INTO project_roots VALUES('project-a',0,'D:\\A'); INSERT INTO threads(id,cwd,project_id,archived,agent_role,source) VALUES('thread-a','D:\\A',NULL,0,NULL,'vscode');");
        fixture.WriteGlobalAssignment("thread-a", "legacy-a", "project-a", "D:\\A");
        fixture.Execute("CREATE TRIGGER fail_projection BEFORE UPDATE OF project_id ON threads BEGIN SELECT RAISE(ABORT,'injected failure'); END;");

        await Assert.ThrowsAsync<SqliteException>(() => fixture.Service.PrepareAsync(null, repair: true, inferFromWorkingDirectory: false, null, CancellationToken.None));

        Assert.Null(fixture.ScalarText("SELECT project_id FROM threads WHERE id='thread-a';"));
        var manifest = Directory.GetFiles(fixture.Paths.ProjectBackupsDirectory, "manifest.json", SearchOption.AllDirectories).Single();
        using var json = JsonDocument.Parse(File.ReadAllBytes(manifest));
        Assert.Equal("failed", json.RootElement.GetProperty("status").GetString());
        Assert.True(File.Exists(Path.Combine(Path.GetDirectoryName(manifest)!, "state_5.sqlite")));
    }

    [Fact]
    public async Task Prepared_manifest_is_reconciled_without_overwriting_database_state()
    {
        using var fixture = new Fixture();
        fixture.CreateDatabase();
        fixture.Execute("INSERT INTO projects VALUES('project-a','A',0,1); INSERT INTO threads(id,cwd,project_id,archived,agent_role,source) VALUES('thread-a','D:\\A','project-a',0,NULL,'vscode');");
        var repairDirectory = Path.Combine(fixture.Paths.ProjectBackupsDirectory, "interrupted");
        Directory.CreateDirectory(repairDirectory);
        var manifestPath = Path.Combine(repairDirectory, "manifest.json");
        var manifest = new
        {
            version = 1,
            status = "prepared",
            state_database = fixture.Paths.ProjectStateDatabase,
            changes = new[] { new { id = "thread-a", old_project_id = (string?)null, project_id = "project-a", reason = "explicit" } }
        };
        File.WriteAllBytes(manifestPath, JsonSerializer.SerializeToUtf8Bytes(manifest));

        await fixture.Service.PrepareAsync(null, repair: true, inferFromWorkingDirectory: false, null, CancellationToken.None);

        using var json = JsonDocument.Parse(File.ReadAllBytes(manifestPath));
        Assert.Equal("complete", json.RootElement.GetProperty("status").GetString());
        Assert.Equal("project-a", fixture.ScalarText("SELECT project_id FROM threads WHERE id='thread-a';"));
    }

    private static object InactiveProfile(string thread, string legacy, string project, string root, string homeKey) => new
    {
        globals = new Dictionary<string, object?>
        {
            ["local-projects"] = new Dictionary<string, object?> { [legacy] = new { rootPaths = new[] { root } } },
            ["app-server-project-id-by-legacy-project-id-by-host"] = new Dictionary<string, object?>
            {
                ["local:" + homeKey] = new Dictionary<string, string> { [legacy] = project }
            },
            ["thread-project-assignments"] = new Dictionary<string, object?>
            {
                [thread] = new { projectKind = "local", projectId = legacy }
            }
        }
    };

    private sealed class Fixture : IDisposable
    {
        public Fixture()
        {
            Root = Path.Combine(Path.GetTempPath(), "codex-project-projection-test-" + Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(Root);
            Paths = SwitcherPaths.FromEnvironment(Path.Combine(Root, "codex home"), Path.Combine(Root, "data"),
                environment: new Dictionary<string, string?> { ["USERPROFILE"] = Root, ["LOCALAPPDATA"] = Path.Combine(Root, "local") });
            Files = new PhysicalSwitcherFileSystem();
            Service = new ProjectProjectionService(Files, Paths, new TestProtector());
        }

        public string Root { get; }
        public SwitcherPaths Paths { get; }
        public PhysicalSwitcherFileSystem Files { get; }
        public ProjectProjectionService Service { get; }

        public void CreateDatabase(bool wal = false)
        {
            Directory.CreateDirectory(Paths.CodexHome);
            using var connection = Open(Paths.ProjectStateDatabase);
            using var command = connection.CreateCommand();
            command.CommandText = "CREATE TABLE projects(id TEXT PRIMARY KEY,name TEXT NOT NULL,position INTEGER NOT NULL,updated_at_ms INTEGER NOT NULL); CREATE TABLE project_roots(project_id TEXT NOT NULL,position INTEGER NOT NULL,path TEXT NOT NULL,PRIMARY KEY(project_id,position)); CREATE TABLE threads(id TEXT PRIMARY KEY,cwd TEXT,project_id TEXT,archived INTEGER NOT NULL DEFAULT 0,agent_role TEXT,source TEXT DEFAULT 'vscode');";
            command.ExecuteNonQuery();
            if (wal)
            {
                command.CommandText = "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;";
                command.ExecuteNonQuery();
            }
        }

        public void Execute(string sql)
        {
            using var connection = Open(Paths.ProjectStateDatabase);
            using var command = connection.CreateCommand(); command.CommandText = sql; command.ExecuteNonQuery();
        }

        public string? ScalarText(string sql) => ScalarTextFromDatabase(Paths.ProjectStateDatabase, sql);
        public string? ScalarTextFromDatabase(string database, string sql)
        {
            using var connection = Open(database, readOnly: true);
            using var command = connection.CreateCommand(); command.CommandText = sql;
            var value = command.ExecuteScalar();
            return value is null or DBNull ? null : Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture);
        }

        public void WriteGlobalAssignment(string thread, string legacy, string project, string root)
        {
            var homeKey = Path.TrimEndingDirectorySeparator(Path.GetFullPath(Paths.CodexHome));
            var global = new Dictionary<string, object?>
            {
                ["local-projects"] = new Dictionary<string, object?> { [legacy] = new { rootPaths = new[] { root } } },
                ["app-server-project-id-by-legacy-project-id-by-host"] = new Dictionary<string, object?>
                {
                    ["local:" + homeKey] = new Dictionary<string, string> { [legacy] = project }
                },
                ["thread-project-assignments"] = new Dictionary<string, object?>
                {
                    [thread] = new { projectKind = "local", projectId = legacy }
                }
            };
            Files.WriteAtomic(Paths.DesktopGlobalStateFile, JsonSerializer.SerializeToUtf8Bytes(global));
        }

        private static SqliteConnection Open(string path, bool readOnly = false)
        {
            var connection = new SqliteConnection(new SqliteConnectionStringBuilder
            {
                DataSource = path,
                Mode = readOnly ? SqliteOpenMode.ReadOnly : SqliteOpenMode.ReadWriteCreate,
                Pooling = false
            }.ConnectionString);
            connection.Open();
            return connection;
        }

        public void Dispose() { try { Directory.Delete(Root, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
    }

    private sealed class TestProtector : ISecretProtector
    {
        public byte[] Protect(ReadOnlySpan<byte> plaintext) => plaintext.ToArray();
        public byte[] Unprotect(ReadOnlySpan<byte> ciphertext) => ciphertext.ToArray();
    }
}
