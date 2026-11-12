using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Data.Sqlite;
using Switcher.Core.Abstractions;
using Switcher.Core.Paths;
using Switcher.Core.Switching;

namespace Switcher.Infrastructure.History;

public sealed class ProjectProjectionService(ISwitcherFileSystem files, SwitcherPaths paths, ISecretProtector protector) : IProjectProjectionService
{
    private sealed record ProjectRoot(string ProjectId, string Path, string Key);
    private sealed record ProjectThread(string Id, string Cwd, string? ProjectId, int Archived, string AgentRole, bool IsSubagent);
    private sealed record ProjectData(IReadOnlyDictionary<string, string> Projects, IReadOnlyList<ProjectRoot> Roots, IReadOnlyList<ProjectThread> Threads);
    private sealed record ProjectChange(string Id, string? OldProjectId, string? ProjectId, string Reason);
    private sealed record ProjectionPlan(IReadOnlyList<ProjectChange> Changes, int ExplicitChanges, int CwdChanges,
        int Projectless, int Preserved, int UnresolvedExplicit, int ProjectCount, int ThreadCount);
    private sealed record GlobalProjection(JsonObject? Root, JsonObject? Assignments, HashSet<string> Projectless,
        JsonObject? Mapping, JsonObject? LegacyProjects, JsonObject? HostIds);

    private static readonly JsonSerializerOptions ManifestOptions = new() { WriteIndented = true, PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower };

    public Task<ProjectProjectionSummary> PrepareAsync(string? desktopOwner, bool repair, bool inferFromWorkingDirectory,
        IProgress<SwitchProgress>? progress, CancellationToken cancellationToken) =>
        Task.Run(() => Prepare(desktopOwner, repair, inferFromWorkingDirectory, progress, cancellationToken), cancellationToken);

    private ProjectProjectionSummary Prepare(string? desktopOwner, bool repair, bool inferFromWorkingDirectory,
        IProgress<SwitchProgress>? progress, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!files.FileExists(paths.ProjectStateDatabase))
            return new ProjectProjectionSummary(false, "项目归属投影：找不到 state_5.sqlite，未做修改。", 0, 0, 0, "");

        if (repair) RecoverPendingManifests(cancellationToken);
        progress?.Report(new SwitchProgress("项目归属检查", "正在读取项目、线程与 Desktop 归属元数据。", 8));
        var data = ReadProjectData(paths.ProjectStateDatabase);
        var global = ReadGlobalProjection(desktopOwner);
        var plan = BuildPlan(data, global, paths.CodexHome, inferFromWorkingDirectory);
        if (!repair || plan.Changes.Count == 0)
        {
            var message = plan.Changes.Count == 0
                ? "项目归属投影已经完整，无需写入。"
                : $"项目归属投影检查完成：待补齐 {plan.Changes.Count} 条（明确归属 {plan.ExplicitChanges}，工作目录 {plan.CwdChanges}）。";
            if (plan.UnresolvedExplicit > 0) message += $"另有 {plan.UnresolvedExplicit} 条明确归属无法映射，已保留原状。";
            return new ProjectProjectionSummary(false, message, plan.ProjectCount, plan.ThreadCount, plan.Changes.Count, "");
        }

        cancellationToken.ThrowIfCancellationRequested();
        files.CreateDirectory(paths.ProjectBackupsDirectory);
        var backupDirectory = Path.Combine(paths.ProjectBackupsDirectory, DateTimeOffset.UtcNow.ToString("yyyyMMddTHHmmssfffZ") + "-" + Guid.NewGuid().ToString("N"));
        files.CreateDirectory(backupDirectory);
        var backupDatabase = Path.Combine(backupDirectory, "state_5.sqlite");
        var backupGlobal = Path.Combine(backupDirectory, ".codex-global-state.json");
        var manifestPath = Path.Combine(backupDirectory, "manifest.json");
        var manifest = CreateManifest(plan, backupDatabase, backupGlobal, files.FileExists(paths.DesktopGlobalStateFile));
        BackupDatabase(paths.ProjectStateDatabase, backupDatabase);
        if (files.FileExists(paths.DesktopGlobalStateFile)) files.WriteAtomic(backupGlobal, files.ReadAllBytes(paths.DesktopGlobalStateFile));
        WriteManifest(manifestPath, manifest);

        progress?.Report(new SwitchProgress("项目归属修复", $"已备份状态数据库，正在写入 {plan.Changes.Count} 条项目归属。", 18));
        var committed = false;
        try
        {
            using var connection = OpenReadWrite(paths.ProjectStateDatabase);
            QuickCheck(connection);
            using var transaction = connection.BeginTransaction(deferred: false);
            foreach (var change in plan.Changes)
            {
                cancellationToken.ThrowIfCancellationRequested();
                using var update = connection.CreateCommand();
                update.Transaction = transaction;
                update.CommandText = "UPDATE threads SET project_id = $target WHERE id = $id AND project_id IS $source";
                update.Parameters.AddWithValue("$target", (object?)change.ProjectId ?? DBNull.Value);
                update.Parameters.AddWithValue("$id", change.Id);
                update.Parameters.AddWithValue("$source", (object?)change.OldProjectId ?? DBNull.Value);
                if (update.ExecuteNonQuery() != 1) throw new IOException("项目归属在计划后发生变化；事务已回滚。 ");
            }
            QuickCheck(connection, transaction);
            cancellationToken.ThrowIfCancellationRequested();
            transaction.Commit();
            committed = true;
            VerifyChanges(paths.ProjectStateDatabase, plan.Changes, target: true);
            QuickCheckPath(paths.ProjectStateDatabase);
            manifest["status"] = "complete";
            manifest["completed_utc"] = DateTimeOffset.UtcNow;
            WriteManifest(manifestPath, manifest);
            var resultMessage = $"项目归属投影修复完成：已写入 {plan.Changes.Count} 条 threads.project_id。数据库备份与修复清单位于本地备份目录。";
            if (plan.UnresolvedExplicit > 0) resultMessage += $"另有 {plan.UnresolvedExplicit} 条明确归属无法映射，已保留原状。";
            return new ProjectProjectionSummary(true, resultMessage, plan.ProjectCount, plan.ThreadCount, plan.Changes.Count, backupDirectory);
        }
        catch (Exception ex)
        {
            if (committed)
            {
                manifest["last_error"] = ex is OperationCanceledException ? "提交后验证未完成；保留未完成清单和数据库备份。" : ex.Message;
            }
            else
            {
                manifest["status"] = "failed";
                manifest["failed_utc"] = DateTimeOffset.UtcNow;
                manifest["error"] = ex is OperationCanceledException ? "操作取消；SQLite 事务已回滚。" : ex.Message;
            }
            try { WriteManifest(manifestPath, manifest); } catch (IOException) { }
            throw;
        }
    }

    private GlobalProjection ReadGlobalProjection(string? desktopOwner)
    {
        if (!files.FileExists(paths.DesktopGlobalStateFile)) return new GlobalProjection(null, null, new HashSet<string>(StringComparer.OrdinalIgnoreCase), null, null, null);
        JsonObject root;
        try { root = JsonNode.Parse(files.ReadAllBytes(paths.DesktopGlobalStateFile)) as JsonObject ?? throw new InvalidDataException("Desktop 全局状态顶层必须是对象。"); }
        catch (JsonException ex) { throw new InvalidDataException("无法读取 Desktop 全局项目状态；未修改项目数据。", ex); }

        JsonObject? globals = root;
        if (root["local-projects"] is null && IsOwner(desktopOwner))
        {
            var envelopeProfile = GetObject(GetObject(root["electron-account-renderer-state-v1"])?["inactive"])?[desktopOwner!];
            globals = GetObject(envelopeProfile)?["globals"] as JsonObject;
            if (globals?["local-projects"] is null && files.FileExists(paths.DesktopRendererArchiveFile))
            {
                var archive = ReadRendererArchive();
                var profiles = GetObject(archive["profiles"]);
                globals = GetObject(GetObject(profiles?[desktopOwner!])?["globals"]);
                if (globals?["local-projects"] is null)
                    globals = GetObject(GetObject(archive["api"])?["globals"]);
            }
            if (globals?["local-projects"] is null) globals = root;
        }

        var projectless = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (globals?["projectless-thread-ids"] is JsonArray ids)
            foreach (var item in ids)
            {
                var id = GetString(item);
                if (!string.IsNullOrWhiteSpace(id)) projectless.Add(id);
            }
        var hostKey = "local:" + Path.TrimEndingDirectorySeparator(Path.GetFullPath(paths.CodexHome));
        var mappings = GetObject(globals?["app-server-project-id-by-legacy-project-id-by-host"]);
        return new GlobalProjection(globals, GetObject(globals?["thread-project-assignments"]), projectless,
            GetObject(GetObject(mappings?[hostKey])), GetObject(globals?["local-projects"]), GetObject(globals?["thread-project-membership-host-ids"]));
    }

    private JsonObject ReadRendererArchive()
    {
        var encrypted = files.ReadAllBytes(paths.DesktopRendererArchiveFile);
        var plain = protector.Unprotect(encrypted);
        try
        {
            var archive = JsonNode.Parse(plain) as JsonObject ?? throw new InvalidDataException("renderer archive 顶层必须是对象。");
            if (GetInt(archive["version"]) != 1 || !string.Equals(GetString(archive["codex_home"]), paths.CodexHome, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("renderer archive 版本或 CODEX_HOME 不匹配。");
            if (archive["profiles"] is not JsonObject || archive["api"] is not JsonObject) throw new InvalidDataException("renderer archive 结构无效。");
            return archive;
        }
        catch (JsonException ex) { throw new InvalidDataException("无法解密或解析 Desktop renderer archive；未修改项目数据。", ex); }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }

    private static ProjectData ReadProjectData(string databasePath)
    {
        using var connection = OpenReadOnly(databasePath);
        QuickCheck(connection);
        if (!HasTable(connection, "projects") || !HasTable(connection, "project_roots") || !HasTable(connection, "threads"))
            throw new InvalidDataException("state_5.sqlite 缺少项目投影所需的数据表；未修改项目数据。 ");
        var projectColumns = Columns(connection, "projects");
        var rootColumns = Columns(connection, "project_roots");
        var threadColumns = Columns(connection, "threads");
        RequireColumns(projectColumns, "projects", "id", "name");
        RequireColumns(rootColumns, "project_roots", "project_id", "path");
        RequireColumns(threadColumns, "threads", "id", "cwd", "project_id");
        var projects = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        using (var command = connection.CreateCommand())
        {
            command.CommandText = "SELECT id, name FROM projects ORDER BY position, updated_at_ms DESC";
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                var id = ReadSqliteText(reader, 0);
                if (string.IsNullOrWhiteSpace(id)) throw new InvalidDataException("projects 表出现空项目 ID；未修改项目数据。 ");
                projects[id] = ReadSqliteText(reader, 1);
            }
        }
        var roots = new List<ProjectRoot>();
        using (var command = connection.CreateCommand())
        {
            command.CommandText = rootColumns.Contains("position")
                ? "SELECT project_id, path FROM project_roots ORDER BY project_id, position"
                : "SELECT project_id, path FROM project_roots ORDER BY project_id";
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                var projectId = ReadSqliteText(reader, 0);
                var path = ReadSqliteText(reader, 1);
                if (!projects.ContainsKey(projectId) || string.IsNullOrWhiteSpace(path)) continue;
                roots.Add(new ProjectRoot(projectId, path, NormalizeProjectPath(path)));
            }
        }
        var archived = threadColumns.Contains("archived") ? "archived" : "0";
        var agentRole = threadColumns.Contains("agent_role") ? "agent_role" : "''";
        var source = threadColumns.Contains("source") ? "source" : "''";
        var threads = new List<ProjectThread>();
        using (var command = connection.CreateCommand())
        {
            command.CommandText = $"SELECT id, cwd, project_id, {archived}, {agentRole}, {source} FROM threads";
            using var reader = command.ExecuteReader();
            while (reader.Read())
            {
                var sourceText = reader.IsDBNull(5) ? "" : ReadSqliteText(reader, 5);
                var isSubagent = sourceText == "subagent";
                if (!isSubagent && sourceText.StartsWith('{'))
                {
                    try
                    {
                        var sourceObject = GetObject(JsonNode.Parse(sourceText));
                        isSubagent = sourceObject?.ContainsKey("subagent") == true && sourceObject["subagent"] is not null;
                    }
                    catch (JsonException) { isSubagent = true; }
                }
                threads.Add(new ProjectThread(ReadSqliteText(reader, 0), reader.IsDBNull(1) ? "" : ReadSqliteText(reader, 1),
                    reader.IsDBNull(2) ? null : ReadSqliteText(reader, 2), reader.IsDBNull(3) ? 0 : Convert.ToInt32(reader.GetValue(3), System.Globalization.CultureInfo.InvariantCulture),
                    reader.IsDBNull(4) ? "" : ReadSqliteText(reader, 4), isSubagent));
            }
        }
        return new ProjectData(projects, roots, threads);
    }

    private static ProjectionPlan BuildPlan(ProjectData data, GlobalProjection global, string codexHome, bool inferFromCwd)
    {
        var expectedHostId = "local:" + Path.TrimEndingDirectorySeparator(Path.GetFullPath(codexHome));
        var rootGroups = data.Roots.Where(root => root.Key.Length > 0).GroupBy(root => root.Key, StringComparer.OrdinalIgnoreCase).ToDictionary(
            group => group.Key, group => group.Select(root => root.ProjectId).Distinct(StringComparer.OrdinalIgnoreCase).ToArray(), StringComparer.OrdinalIgnoreCase);
        var changes = new List<ProjectChange>();
        var explicitChanges = 0;
        var cwdChanges = 0;
        var projectless = 0;
        var preserved = 0;
        var unresolved = 0;
        foreach (var thread in data.Threads)
        {
            if (thread.IsSubagent || !string.IsNullOrWhiteSpace(thread.AgentRole)) continue;
            var current = thread.ProjectId;
            var assignment = GetObject(global.Assignments?[thread.Id]);
            var legacyProjectId = GetString(assignment?["projectId"]);
            var hostId = GetString(global.HostIds?[thread.Id]);
            if (!string.IsNullOrWhiteSpace(hostId) && !string.Equals(hostId, expectedHostId, StringComparison.OrdinalIgnoreCase)) continue;
            if (assignment is not null && !string.Equals(GetString(assignment["projectKind"]), "local", StringComparison.Ordinal)) continue;

            string? desired = null;
            var reason = "";
            if (global.Projectless.Contains(thread.Id))
            {
                projectless++;
                if (!string.IsNullOrWhiteSpace(current)) reason = "projectless";
                else continue;
            }
            else if (!string.IsNullOrWhiteSpace(legacyProjectId))
            {
                desired = ResolveBackendProjectId(legacyProjectId, global, rootGroups, data.Projects);
                if (string.IsNullOrWhiteSpace(desired)) { unresolved++; continue; }
                explicitChanges++;
                reason = "explicit";
            }
            else if (!string.IsNullOrWhiteSpace(current) && data.Projects.ContainsKey(current))
            {
                preserved++;
                continue;
            }
            else
            {
                if (!inferFromCwd || thread.Archived != 0) continue;
                var cwd = NormalizeProjectPath(thread.Cwd);
                var matchingRoots = data.Roots.Where(root => root.Key.Length > 0 &&
                    (string.Equals(cwd, root.Key, StringComparison.OrdinalIgnoreCase) || cwd.StartsWith(root.Key + "\\", StringComparison.OrdinalIgnoreCase)))
                    .ToArray();
                if (matchingRoots.Length == 0) continue;
                var longest = matchingRoots.Max(root => root.Key.Length);
                var candidates = matchingRoots.Where(root => root.Key.Length == longest).Select(root => root.ProjectId).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
                if (candidates.Length != 1) continue;
                desired = candidates[0];
                cwdChanges++;
                reason = "cwd";
            }
            if (!string.Equals(desired, current, StringComparison.Ordinal)) changes.Add(new ProjectChange(thread.Id, current, desired, reason));
        }
        return new ProjectionPlan(changes, explicitChanges, cwdChanges, projectless, preserved, unresolved, data.Projects.Count, data.Threads.Count);
    }

    private static string? ResolveBackendProjectId(string legacyId, GlobalProjection global,
        IReadOnlyDictionary<string, string[]> roots, IReadOnlyDictionary<string, string> knownProjects)
    {
        var mapped = GetString(global.Mapping?[legacyId]);
        if (!string.IsNullOrWhiteSpace(mapped) && knownProjects.ContainsKey(mapped)) return mapped;
        if (knownProjects.ContainsKey(legacyId)) return legacyId;
        var legacyProject = GetObject(global.LegacyProjects?[legacyId]);
        if (legacyProject?["rootPaths"] is not JsonArray legacyRoots) return null;
        foreach (var item in legacyRoots)
        {
            var key = NormalizeProjectPath(GetString(item) ?? "");
            if (roots.TryGetValue(key, out var projects) && projects.Length == 1) return projects[0];
        }
        return null;
    }

    private JsonObject CreateManifest(ProjectionPlan plan, string backupDatabase, string backupGlobal, bool globalExists)
    {
        var changes = new JsonArray(plan.Changes.Select(change => (JsonNode?)new JsonObject
        {
            ["id"] = change.Id,
            ["old_project_id"] = change.OldProjectId,
            ["project_id"] = change.ProjectId,
            ["reason"] = change.Reason
        }).ToArray());
        return new JsonObject
        {
            ["version"] = 1,
            ["status"] = "prepared",
            ["started_utc"] = DateTimeOffset.UtcNow.ToString("O"),
            ["codex_home"] = paths.CodexHome,
            ["state_database"] = paths.ProjectStateDatabase,
            ["backup_database"] = backupDatabase,
            ["global_state"] = paths.DesktopGlobalStateFile,
            ["backup_global_state"] = globalExists ? backupGlobal : "",
            ["project_count"] = plan.ProjectCount,
            ["thread_count"] = plan.ThreadCount,
            ["planned_changes"] = plan.Changes.Count,
            ["explicit_changes"] = plan.ExplicitChanges,
            ["cwd_changes"] = plan.CwdChanges,
            ["projectless_kept"] = plan.Projectless,
            ["preserved"] = plan.Preserved,
            ["unresolved_explicit"] = plan.UnresolvedExplicit,
            ["changes"] = changes,
            ["global_state_modified"] = false
        };
    }

    private void RecoverPendingManifests(CancellationToken cancellationToken)
    {
        if (!files.DirectoryExists(paths.ProjectBackupsDirectory)) return;
        foreach (var manifestPath in files.EnumerateFiles(paths.ProjectBackupsDirectory, "manifest.json", SearchOption.AllDirectories))
        {
            cancellationToken.ThrowIfCancellationRequested();
            JsonObject manifest;
            try { manifest = JsonNode.Parse(files.ReadAllBytes(manifestPath)) as JsonObject ?? throw new InvalidDataException("项目修复清单顶层必须是对象。 "); }
            catch (JsonException ex) { throw new InvalidDataException("项目修复清单损坏；恢复材料已保留。", ex); }
            if (GetString(manifest["status"]) != "prepared") continue;
            var manifestHome = GetString(manifest["codex_home"]);
            if (!string.IsNullOrWhiteSpace(manifestHome) && !PathsEqual(manifestHome, paths.CodexHome)) continue;
            if (!PathsEqual(GetString(manifest["state_database"]), paths.ProjectStateDatabase) || manifest["changes"] is not JsonArray changes)
                throw new InvalidDataException("发现无法识别的未完成项目修复；备份已保留，请先人工检查。 ");
            var parsed = changes.Select(item => new ProjectChange(
                GetString(GetObject(item)?["id"]) ?? throw new InvalidDataException("未完成项目修复清单缺少 thread id。"),
                GetString(GetObject(item)?["old_project_id"]), GetString(GetObject(item)?["project_id"]), GetString(GetObject(item)?["reason"]) ?? "")).ToArray();
            var targetMatches = VerifyChanges(paths.ProjectStateDatabase, parsed, target: true, throwOnMismatch: false);
            var originalMatches = VerifyChanges(paths.ProjectStateDatabase, parsed, target: false, throwOnMismatch: false);
            if (!targetMatches && !originalMatches) throw new InvalidDataException("未完成项目修复的数据库状态与计划不一致；保留恢复材料并拒绝覆盖。 ");
            manifest["status"] = targetMatches ? "complete" : "rolled-back";
            manifest["recovered_utc"] = DateTimeOffset.UtcNow;
            WriteManifest(manifestPath, manifest);
        }
    }

    private static bool VerifyChanges(string path, IReadOnlyList<ProjectChange> changes, bool target, bool throwOnMismatch = true)
    {
        using var connection = OpenReadOnly(path);
        foreach (var change in changes)
        {
            using var command = connection.CreateCommand();
            command.CommandText = "SELECT project_id FROM threads WHERE id = $id";
            command.Parameters.AddWithValue("$id", change.Id);
            var result = command.ExecuteScalar();
            if (result is null) return Mismatch("项目修复后的 thread 已不存在。", throwOnMismatch);
            var actual = result is DBNull ? null : Convert.ToString(result, System.Globalization.CultureInfo.InvariantCulture);
            var expected = target ? change.ProjectId : change.OldProjectId;
            if (!string.Equals(actual, expected, StringComparison.Ordinal)) return Mismatch("项目修复后的归属与计划不一致。", throwOnMismatch);
        }
        return true;
    }

    private static bool Mismatch(string message, bool shouldThrow)
    {
        if (shouldThrow) throw new InvalidDataException(message);
        return false;
    }

    private static void BackupDatabase(string sourcePath, string backupPath)
    {
        using var source = OpenReadOnly(sourcePath);
        using var destination = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = backupPath, Mode = SqliteOpenMode.ReadWriteCreate, Pooling = false }.ConnectionString);
        destination.Open();
        source.BackupDatabase(destination);
        destination.Close();
        QuickCheckPath(backupPath);
    }

    private static void QuickCheckPath(string path)
    {
        using var connection = OpenReadOnly(path);
        QuickCheck(connection);
    }

    private static SqliteConnection OpenReadOnly(string path)
    {
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Mode = SqliteOpenMode.ReadOnly, Cache = SqliteCacheMode.Private, Pooling = false }.ConnectionString);
        connection.Open();
        using var timeout = connection.CreateCommand(); timeout.CommandText = "PRAGMA busy_timeout=5000"; timeout.ExecuteNonQuery();
        return connection;
    }

    private static SqliteConnection OpenReadWrite(string path)
    {
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Mode = SqliteOpenMode.ReadWrite, Cache = SqliteCacheMode.Private, Pooling = false }.ConnectionString);
        connection.Open();
        using var timeout = connection.CreateCommand(); timeout.CommandText = "PRAGMA busy_timeout=5000"; timeout.ExecuteNonQuery();
        return connection;
    }

    private static bool HasTable(SqliteConnection connection, string name)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=$name";
        command.Parameters.AddWithValue("$name", name);
        return Convert.ToInt32(command.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture) > 0;
    }

    private static HashSet<string> Columns(SqliteConnection connection, string table)
    {
        using var command = connection.CreateCommand(); command.CommandText = $"SELECT name FROM pragma_table_info('{table}')";
        using var reader = command.ExecuteReader();
        var columns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        while (reader.Read()) columns.Add(reader.GetString(0));
        return columns;
    }

    private static void RequireColumns(HashSet<string> actual, string table, params string[] required)
    {
        if (required.Any(column => !actual.Contains(column))) throw new InvalidDataException($"state_5.sqlite 的 {table} 表结构不受支持；未修改项目数据。 ");
    }

    private static void QuickCheck(SqliteConnection connection, SqliteTransaction? transaction = null)
    {
        using var command = connection.CreateCommand(); command.Transaction = transaction; command.CommandText = "PRAGMA quick_check";
        if (!string.Equals(Convert.ToString(command.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture), "ok", StringComparison.Ordinal))
            throw new InvalidDataException("SQLite quick_check 未通过；未继续修改项目数据。 ");
    }

    private void WriteManifest(string path, JsonObject manifest) => files.WriteAtomic(path, JsonSerializer.SerializeToUtf8Bytes(manifest, ManifestOptions));

    private static string ReadSqliteText(SqliteDataReader reader, int ordinal)
    {
        var value = reader.GetValue(ordinal);
        if (value is string text) return text;
        if (value is byte[] bytes) return new UTF8Encoding(false, true).GetString(bytes);
        return Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture) ?? "";
    }

    private static JsonObject? GetObject(JsonNode? value) => value as JsonObject;
    private static string? GetString(JsonNode? value)
    {
        if (value is not JsonValue scalar) return null;
        if (scalar.TryGetValue<string>(out var text)) return text;
        return null;
    }
    private static int GetInt(JsonNode? value) => value is JsonValue scalar && scalar.TryGetValue<int>(out var number) ? number : 0;
    private static bool IsOwner(string? owner) => owner is not null && owner.Length == 64 && owner.All(ch => ch is >= '0' and <= '9' or >= 'a' and <= 'f');
    private static string NormalizeProjectPath(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) return "";
        var value = path.Replace('/', '\\');
        if (value.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase)) value = value[4..];
        return value.TrimEnd('\\', '/').ToLowerInvariant();
    }
    private static bool PathsEqual(string? left, string right)
    {
        if (string.IsNullOrWhiteSpace(left)) return false;
        try { return string.Equals(Path.GetFullPath(left), Path.GetFullPath(right), StringComparison.OrdinalIgnoreCase); }
        catch { return false; }
    }
}
