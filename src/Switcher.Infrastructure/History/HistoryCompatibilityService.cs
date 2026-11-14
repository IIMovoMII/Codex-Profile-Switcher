using System.Buffers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Data.Sqlite;
using Switcher.Core.Abstractions;
using Switcher.Core.Paths;
using Switcher.Core.Switching;

namespace Switcher.Infrastructure.History;

public sealed class HistoryCompatibilityService(ISwitcherFileSystem files, SwitcherPaths paths) : IHistoryCompatibilityService
{
    private sealed record FilePlan(string Path, byte[] Original, byte[] Target);
    private sealed record ProviderRow(string ThreadId, string OldProvider);
    private sealed record DatabasePlan(string Path, IReadOnlyList<ProviderRow> Rows, string BackupPath, HistoryDbPlan Projection);
    private sealed record PreparedFile(string Source, string Backup, string OriginalSha256, string TargetSha256);
    private sealed record PreparedDatabase(string Source, string Backup, IReadOnlyList<ProviderRow> Rows, HistoryDbPlan? Projection = null);
    private sealed record PreparedManifest(int Version, string CodexHome, string Status, IReadOnlyList<PreparedFile> Files, IReadOnlyList<PreparedDatabase> Databases);
    private sealed record ReadyStamp(int Version, string CodexHome, string Fingerprint, int FileCount, int DatabaseCount);
    private static readonly Regex ProviderName = new("^[A-Za-z0-9._-]+$", RegexOptions.Compiled | RegexOptions.CultureInvariant);
    private static readonly byte[] ReplacementToken = Encoding.UTF8.GetBytes("\"openai\"");
    private static readonly JsonSerializerOptions ManifestOptions = new(JsonSerializerDefaults.Web) { WriteIndented = true };

    public async Task<HistoryPreparationResult> PrepareAsync(bool fullScan, IProgress<SwitchProgress>? progress, CancellationToken cancellationToken)
    {
        await Task.Yield();
        var recovered = await RecoverPendingOperationsAsync(cancellationToken).ConfigureAwait(false);
        var rolloutFiles = EnumerateHistoryFiles().ToArray();
        var databasePaths = EnumerateDatabaseFiles().ToArray();
        var inputFingerprint = Fingerprint(rolloutFiles.Concat(databasePaths));
        var readyPath = paths.HistoryReadyFile;
        if (!fullScan && files.FileExists(readyPath) && IsReady(readyPath, inputFingerprint))
            return new HistoryPreparationResult(true, false, JoinMessages(recovered, "已准备且历史未变化"), rolloutFiles.Length, databasePaths.Length, paths.HistoryBackupsDirectory);

        var backupRoot = paths.HistoryBackupsDirectory;
        var backupDirectory = Path.Combine(backupRoot, DateTimeOffset.UtcNow.ToString("yyyyMMddTHHmmssfffZ") + "-" + Guid.NewGuid().ToString("N"));
        var filePlans = new List<FilePlan>();
        var journals = new List<HistoryJournal>();
        var threadIds = new HashSet<string>(StringComparer.Ordinal);
        var index = 0;
        foreach (var path in rolloutFiles)
        {
            cancellationToken.ThrowIfCancellationRequested();
            progress?.Report(new SwitchProgress("历史扫描", $"正在检查 {Path.GetFileName(path)}。", rolloutFiles.Length == 0 ? 45 : 10 + index * 40 / rolloutFiles.Length));
            var original = files.ReadAllBytes(path);
            var target = RewriteJsonl(path, original);
            var journal = new HistoryJournal(path, original, target);
            journals.Add(journal);
            if (journal.LogicalId.Length > 0) threadIds.Add(journal.LogicalId);
            index++;
        }
        HistoryJournal.UpdateParentBoundaries(journals);
        filePlans.AddRange(journals.Where(journal => journal.Changed).Select(journal => new FilePlan(journal.Path, journal.Original, journal.Target)));

        var dbPlans = new List<DatabasePlan>();
        foreach (var database in databasePaths)
        {
            cancellationToken.ThrowIfCancellationRequested();
            progress?.Report(new SwitchProgress("历史数据库", $"正在检查 {Path.GetFileName(database)}。", 55));
            var rows = ReadRelatedProviderRows(database, threadIds);
            using var connection = OpenReadOnly(database);
            var projection = PaginatedHistoryAdapter.Build(connection, journals, rows.Select(row => (row.ThreadId, row.OldProvider)).ToArray());
            if (projection is null) continue;
            var backupPath = Path.Combine(backupDirectory, $"db-{dbPlans.Count:D4}-{Path.GetFileName(database)}.bak");
            dbPlans.Add(new DatabasePlan(database, rows, backupPath, projection));
        }
        foreach (var journal in journals.Where(journal => journal.Paginated && journal.Changed))
            if (!dbPlans.Any(plan => plan.Projection.ProjectionIds.Contains(journal.ProjectionId)))
                throw new InvalidDataException("分页历史对应的本地投影游标尚未找到；已保留历史，未执行写入。");

        if (filePlans.Count == 0 && dbPlans.Count == 0)
        {
            WriteReady(readyPath, inputFingerprint, rolloutFiles.Length, databasePaths.Length);
            return new HistoryPreparationResult(true, false, JoinMessages(recovered, "历史未发现需要修改的记录"), rolloutFiles.Length, databasePaths.Length, "");
        }
        files.CreateDirectory(backupDirectory);
        var databaseTransactions = new List<(DatabasePlan Plan, SqliteConnection Connection, SqliteTransaction Transaction)>();
        string? manifestPath = null;
        PreparedManifest? preparedManifest = null;
        try
        {
            // Persist every restore source before the first live mutation.
            var preparedFiles = new List<PreparedFile>();
            foreach (var plan in filePlans)
            {
                var backupPath = Path.Combine(backupDirectory, $"jsonl-{preparedFiles.Count:D6}.bak");
                files.WriteAtomic(backupPath, plan.Original);
                preparedFiles.Add(new PreparedFile(plan.Path, backupPath, Hash(plan.Original), Hash(plan.Target)));
            }
            foreach (var database in dbPlans)
            {
                BackupDatabase(database.Path, database.BackupPath);
            }
            manifestPath = Path.Combine(backupDirectory, "manifest.json");
            preparedManifest = new PreparedManifest(3, paths.CodexHome, "prepared", preparedFiles,
                dbPlans.Select(db => new PreparedDatabase(db.Path, db.BackupPath, db.Rows, db.Projection)).ToArray());
            WriteManifest(manifestPath, preparedManifest);

            // Check all sources before the first mutation, including SQLite values in WAL.
            _ = AllChangesApplied(preparedManifest);

            foreach (var plan in filePlans)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (!Hash(files.ReadAllBytes(plan.Path)).Equals(Hash(plan.Original), StringComparison.Ordinal)) throw new IOException($"对话历史在计划后发生变化：{Path.GetFileName(plan.Path)}");
                files.WriteAtomic(plan.Path, plan.Target);
                if (!Hash(files.ReadAllBytes(plan.Path)).Equals(Hash(plan.Target), StringComparison.Ordinal)) throw new IOException($"对话历史写入后校验失败：{Path.GetFileName(plan.Path)}");
            }

            foreach (var database in dbPlans)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var connection = OpenReadWrite(database.Path);
                try
                {
                    QuickCheck(connection);
                    var transaction = connection.BeginTransaction(deferred: false);
                    databaseTransactions.Add((database, connection, transaction));
                    PaginatedHistoryAdapter.Apply(connection, transaction, database.Projection, restore: false);
                    VerifyProviderRows(connection, transaction, database.Rows, "openai");
                    QuickCheck(connection, transaction);
                }
                catch { connection.Dispose(); throw; }
            }

            foreach (var item in databaseTransactions)
            {
                item.Transaction.Commit();
            }
            cancellationToken.ThrowIfCancellationRequested();
            foreach (var item in databaseTransactions) { item.Transaction.Dispose(); item.Connection.Dispose(); }
            databaseTransactions.Clear();

            foreach (var plan in filePlans)
                if (!Hash(files.ReadAllBytes(plan.Path)).Equals(Hash(plan.Target), StringComparison.Ordinal)) throw new IOException($"对话历史复查失败：{Path.GetFileName(plan.Path)}");
            foreach (var database in dbPlans)
            {
                VerifyDatabase(database.Path, database.Rows, "openai");
                using var verify = OpenReadOnly(database.Path);
                if (!PaginatedHistoryAdapter.IsApplied(verify, database.Projection)) throw new IOException("分页历史写后校验失败。");
            }
            var finalFingerprint = Fingerprint(rolloutFiles.Concat(databasePaths));
            WriteReady(readyPath, finalFingerprint, rolloutFiles.Length, databasePaths.Length);
            WriteManifest(manifestPath, preparedManifest with { Status = "complete" });
            return new HistoryPreparationResult(true, filePlans.Count > 0 || dbPlans.Count > 0,
                JoinMessages(recovered, filePlans.Count > 0 || dbPlans.Count > 0 ? "对话 provider 和可验证的模型输入标识已核对为 openai" : "历史未发现需要修改的记录"),
                rolloutFiles.Length, databasePaths.Length, backupDirectory);
        }
        catch (Exception operationError)
        {
            foreach (var item in databaseTransactions)
            {
                try { item.Transaction.Rollback(); } catch (Exception ex) when (ex is SqliteException or InvalidOperationException) { }
                item.Transaction.Dispose(); item.Connection.Dispose();
            }
            var recoveryErrors = new List<string>();
            if (manifestPath is not null && preparedManifest is not null)
            {
                try { RollbackPreparedChanges(preparedManifest); }
                catch (Exception ex) when (ex is IOException or SqliteException or UnauthorizedAccessException or InvalidDataException)
                {
                    recoveryErrors.Add(ex.Message);
                }
                var finalStatus = recoveryErrors.Count == 0 ? "rolled_back" : "recovery_required";
                try { WriteManifest(manifestPath, preparedManifest with { Status = finalStatus }); }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { recoveryErrors.Add("无法更新历史恢复清单状态：" + ex.Message); }
            }
            if (recoveryErrors.Count > 0)
                throw new IOException("历史处理失败且自动恢复未完成；恢复材料保留在本地备份目录。" + string.Join("；", recoveryErrors), operationError);
            if (operationError is OperationCanceledException) throw new OperationCanceledException("历史处理已取消；本轮修改已安全回退。", operationError, cancellationToken);
            throw new InvalidOperationException("历史兼容准备失败；已恢复本轮修改，恢复材料保留在本地备份目录。", operationError);
        }
        finally
        {
            foreach (var plan in databaseTransactions) { plan.Transaction.Dispose(); plan.Connection.Dispose(); }
        }
    }

    public bool HasPendingRecovery
    {
        get
        {
            if (!files.DirectoryExists(paths.HistoryBackupsDirectory)) return false;
            foreach (var manifestPath in files.EnumerateFiles(paths.HistoryBackupsDirectory, "manifest.json", SearchOption.AllDirectories))
            {
                try
                {
                    using var document = JsonDocument.Parse(files.ReadAllBytes(manifestPath));
                    if (!document.RootElement.TryGetProperty("status", out var status) || status.ValueKind != JsonValueKind.String || status.GetString() is "prepared" or "recovery_required") return true;
                }
                catch (Exception ex) when (ex is JsonException or IOException or UnauthorizedAccessException) { return true; }
            }
            return false;
        }
    }

    public async Task<IReadOnlyList<string>> RecoverPendingOperationsAsync(CancellationToken cancellationToken = default)
    {
        await Task.Yield();
        if (!files.DirectoryExists(paths.HistoryBackupsDirectory)) return [];
        var recovered = new List<string>();
        foreach (var manifestPath in files.EnumerateFiles(paths.HistoryBackupsDirectory, "manifest.json", SearchOption.AllDirectories))
        {
            cancellationToken.ThrowIfCancellationRequested();
            PreparedManifest manifest;
            try { manifest = JsonSerializer.Deserialize<PreparedManifest>(files.ReadAllBytes(manifestPath), ManifestOptions) ?? throw new InvalidDataException("历史恢复清单为空。"); }
            catch (JsonException ex) { throw new InvalidDataException("历史恢复清单损坏，已保留恢复材料并停止历史写入。", ex); }
            if (manifest.Status is not ("prepared" or "recovery_required")) continue;
            ValidateManifest(manifestPath, manifest);
            try
            {
                if (AllChangesApplied(manifest))
                {
                    var rolloutFiles = EnumerateHistoryFiles().ToArray();
                    var databasePaths = EnumerateDatabaseFiles().ToArray();
                    WriteReady(paths.HistoryReadyFile, Fingerprint(rolloutFiles.Concat(databasePaths)), rolloutFiles.Length, databasePaths.Length);
                    WriteManifest(manifestPath, manifest with { Status = "complete" });
                    recovered.Add("已完成上次中断的历史准备");
                }
                else
                {
                    RollbackPreparedChanges(manifest);
                    WriteManifest(manifestPath, manifest with { Status = "rolled_back" });
                    recovered.Add("已回退上次未完成的历史准备");
                }
            }
            catch (Exception ex) when (ex is IOException or SqliteException or UnauthorizedAccessException or InvalidDataException)
            {
                try { WriteManifest(manifestPath, manifest with { Status = "recovery_required" }); }
                catch (Exception statusError) when (statusError is IOException or UnauthorizedAccessException) { }
                throw new IOException("发现未完成的历史操作；检测到外部变化或恢复失败，已保留恢复材料并停止写入。" + ex.Message, ex);
            }
        }
        return recovered;
    }

    private void ValidateManifest(string manifestPath, PreparedManifest manifest)
    {
        if (manifest.Version is not (2 or 3) || !string.Equals(manifest.CodexHome, paths.CodexHome, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("历史恢复清单版本或 CODEX_HOME 不匹配；已保留恢复材料。");
        EnsurePathWithin(manifestPath, paths.HistoryBackupsDirectory, "恢复清单");
        if (manifest.Files is null || manifest.Databases is null) throw new InvalidDataException("历史恢复清单缺少文件计划。");
        foreach (var item in manifest.Files)
        {
            EnsurePathWithin(item.Source, paths.CodexHome, "JSONL 源文件");
            EnsurePathWithin(item.Backup, paths.HistoryBackupsDirectory, "JSONL 备份");
            if (!Regex.IsMatch(item.OriginalSha256, "^[a-f0-9]{64}$") || !Regex.IsMatch(item.TargetSha256, "^[a-f0-9]{64}$"))
                throw new InvalidDataException("历史恢复清单中的 JSONL 摘要无效。");
        }
        foreach (var item in manifest.Databases)
        {
            EnsurePathWithin(item.Source, paths.CodexHome, "SQLite 源文件");
            EnsurePathWithin(item.Backup, paths.HistoryBackupsDirectory, "SQLite 备份");
            if (item.Rows is null || item.Rows.Any(row => string.IsNullOrWhiteSpace(row.ThreadId) || !ProviderName.IsMatch(row.OldProvider) || row.OldProvider == "openai"))
                throw new InvalidDataException("历史恢复清单中的 SQLite 行计划无效。");
            if (manifest.Version == 3 && item.Projection is null) throw new InvalidDataException("历史恢复清单缺少数据库投影计划。");
            if (item.Projection is not null) PaginatedHistoryAdapter.ValidatePlan(item.Projection);
        }
    }

    private bool AllChangesApplied(PreparedManifest manifest)
    {
        var allApplied = true;
        foreach (var item in manifest.Files)
        {
            var original = files.ReadAllBytes(item.Backup);
            if (Hash(original) != item.OriginalSha256) throw new InvalidDataException("JSONL 恢复备份摘要不匹配。");
            var current = Hash(files.ReadAllBytes(item.Source));
            if (current == item.OriginalSha256) allApplied = false;
            else if (current != item.TargetSha256) throw new IOException($"检测到历史文件外部变化：{Path.GetFileName(item.Source)}");
        }
        foreach (var item in manifest.Databases)
        {
            ValidateDatabaseBackup(item);
            if (item.Projection is not null)
            {
                using var connection = OpenReadOnly(item.Source);
                if (!PaginatedHistoryAdapter.IsApplied(connection, item.Projection)) allApplied = false;
                continue;
            }
            foreach (var row in item.Rows)
            {
                var current = ReadProviderValue(item.Source, row.ThreadId);
                if (current == row.OldProvider) allApplied = false;
                else if (current != "openai") throw new IOException($"检测到 SQLite provider 外部变化：{Path.GetFileName(item.Source)}");
            }
        }
        return allApplied;
    }

    private void RollbackPreparedChanges(PreparedManifest manifest)
    {
        // Refuse the entire recovery before reverting any database if another source was edited externally.
        _ = AllChangesApplied(manifest);
        foreach (var item in manifest.Databases)
        {
            ValidateDatabaseBackup(item);
            using var connection = OpenReadWrite(item.Source);
            QuickCheck(connection);
            using var transaction = connection.BeginTransaction(deferred: false);
            if (item.Projection is not null)
            {
                PaginatedHistoryAdapter.Apply(connection, transaction, item.Projection, restore: true);
                QuickCheck(connection, transaction); transaction.Commit(); continue;
            }
            foreach (var row in item.Rows)
            {
                var current = ReadProviderValue(connection, transaction, row.ThreadId);
                if (current == row.OldProvider) continue;
                if (current != "openai") throw new IOException($"检测到 SQLite provider 外部变化：{Path.GetFileName(item.Source)}");
                using var update = connection.CreateCommand(); update.Transaction = transaction;
                update.CommandText = "UPDATE threads SET model_provider = $source WHERE id = $id AND model_provider = 'openai'";
                update.Parameters.AddWithValue("$source", row.OldProvider);
                update.Parameters.AddWithValue("$id", row.ThreadId);
                if (update.ExecuteNonQuery() != 1) throw new IOException($"SQLite provider 行在恢复期间发生变化：{Path.GetFileName(item.Source)}");
            }
            foreach (var row in item.Rows)
                if (ReadProviderValue(connection, transaction, row.ThreadId) != row.OldProvider) throw new InvalidDataException("SQLite provider 恢复后校验失败。");
            QuickCheck(connection, transaction);
            transaction.Commit();
        }
        foreach (var item in manifest.Files)
        {
            var current = Hash(files.ReadAllBytes(item.Source));
            if (current == item.OriginalSha256) continue;
            if (current != item.TargetSha256) throw new IOException($"检测到历史文件外部变化：{Path.GetFileName(item.Source)}");
            var original = files.ReadAllBytes(item.Backup);
            if (Hash(original) != item.OriginalSha256) throw new InvalidDataException("JSONL 恢复备份摘要不匹配。");
            files.WriteAtomic(item.Source, original);
            if (Hash(files.ReadAllBytes(item.Source)) != item.OriginalSha256) throw new IOException($"JSONL 恢复后校验失败：{Path.GetFileName(item.Source)}");
        }
    }

    private static void ValidateDatabaseBackup(PreparedDatabase item)
    {
        using var connection = OpenReadOnly(item.Backup);
        QuickCheck(connection);
        if (item.Projection is not null) PaginatedHistoryAdapter.VerifyBackup(connection, item.Projection);
        foreach (var row in item.Rows)
            if (ReadProviderValue(connection, null, row.ThreadId) != row.OldProvider) throw new InvalidDataException("SQLite 恢复备份不匹配原始 provider。");
    }

    private static string ReadProviderValue(string path, string threadId)
    {
        using var connection = OpenReadOnly(path);
        return ReadProviderValue(connection, null, threadId);
    }

    private static string ReadProviderValue(SqliteConnection connection, SqliteTransaction? transaction, string threadId)
    {
        using var command = connection.CreateCommand(); command.Transaction = transaction;
        command.CommandText = "SELECT model_provider FROM threads WHERE id = $id";
        command.Parameters.AddWithValue("$id", threadId);
        using var reader = command.ExecuteReader();
        if (!reader.Read() || reader.IsDBNull(0)) throw new IOException("历史恢复所需的 SQLite 行不存在或 provider 为空。");
        return ReadSqliteText(reader, 0);
    }

    private static void EnsurePathWithin(string path, string root, string kind)
    {
        var fullPath = Path.GetFullPath(path);
        var fullRoot = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
        var prefix = fullRoot + Path.DirectorySeparatorChar;
        if (!fullPath.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException($"历史恢复清单中的{kind}路径越界。");
    }

    private void WriteManifest(string path, PreparedManifest manifest) => files.WriteAtomic(path, JsonSerializer.SerializeToUtf8Bytes(manifest, ManifestOptions));

    private static string JoinMessages(IReadOnlyList<string> prior, string current) => prior.Count == 0 ? current : string.Join("；", prior.Append(current));

    private byte[] RewriteJsonl(string path, byte[] source)
    {
        if (source.Length == 0) throw new InvalidDataException($"历史文件为空，拒绝切换：{Path.GetFileName(path)}");
        var output = new MemoryStream(source.Length + 64);
        var start = 0; var lineNumber = 0;
        while (start < source.Length)
        {
            var newline = Array.IndexOf(source, (byte)0x0A, start);
            var contentEnd = newline < 0 ? source.Length : newline;
            var lineEnd = contentEnd;
            if (lineEnd > start && source[lineEnd - 1] == 0x0D) contentEnd--;
            var raw = source.AsSpan(start, contentEnd - start);
            var hasBom = lineNumber == 0 && raw.StartsWith(Encoding.UTF8.Preamble);
            if (hasBom) raw = raw[Encoding.UTF8.Preamble.Length..];
            var text = new UTF8Encoding(false, true).GetString(raw);
            lineNumber++;
            if (hasBom) output.Write(Encoding.UTF8.Preamble);
            if (!string.IsNullOrWhiteSpace(text)) output.Write(Encoding.UTF8.GetBytes(RewriteJsonLine(text, lineNumber)));
            else output.Write(raw);
            if (contentEnd < lineEnd) output.WriteByte(0x0D);
            if (newline >= 0) output.WriteByte(0x0A);
            if (newline < 0) break;
            start = newline + 1;
        }
        return output.ToArray();
    }

    private static string RewriteJsonLine(string line, int lineNumber)
    {
        using var document = JsonDocument.Parse(line);
        var root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object) return line;
        var targetPaths = new List<string[]>();
        var recordName = root.TryGetProperty("type", out var recordType) && recordType.ValueKind == JsonValueKind.String ? recordType.GetString() : null;
        if (recordName == "session_meta" && root.TryGetProperty("payload", out var meta) && meta.ValueKind == JsonValueKind.Object && meta.TryGetProperty("model_provider", out var provider))
            targetPaths.Add(["payload", "model_provider"]);
        if (recordName == "event_msg" && root.TryGetProperty("payload", out var eventPayload) && eventPayload.ValueKind == JsonValueKind.Object &&
            eventPayload.TryGetProperty("type", out var eventType) && eventType.ValueKind == JsonValueKind.String && eventType.GetString() == "thread_settings_applied" &&
            eventPayload.TryGetProperty("thread_settings", out var settings) && settings.ValueKind == JsonValueKind.Object && settings.TryGetProperty("model_provider_id", out provider))
            targetPaths.Add(["payload", "thread_settings", "model_provider_id"]);

        var changed = false;
        var rewritten = line;
        foreach (var targetPath in targetPaths)
        {
            var current = ReadPath(root, targetPath);
            if (current.ValueKind != JsonValueKind.String) throw new InvalidDataException($"历史 provider 字段不是字符串（第 {lineNumber} 行），拒绝猜测。");
            var providerValue = current.GetString() ?? "";
            if (providerValue.Length == 0 || !ProviderName.IsMatch(providerValue)) throw new InvalidDataException($"历史 provider 字段为空或包含未支持字符（第 {lineNumber} 行），拒绝自动改写。");
            if (providerValue == "openai") continue;
            var ranges = FindJsonStringRanges(Encoding.UTF8.GetBytes(rewritten), targetPath);
            if (ranges.Count != 1) throw new InvalidDataException($"无法唯一定位历史 provider 字段（第 {lineNumber} 行），未修改历史。");
            var range = ranges[0];
            var utf8 = Encoding.UTF8.GetBytes(rewritten);
            rewritten = Encoding.UTF8.GetString([.. utf8.AsSpan(0, range.Start), .. ReplacementToken, .. utf8.AsSpan(range.Start + range.Length)]);
            changed = true;
        }

        var portable = CodexHistoryCompat.PortableHistory.Inspect(rewritten, lineNumber);
        if (portable is not null)
        {
            if (!string.IsNullOrWhiteSpace(portable.UnsupportedReason)) throw new InvalidDataException($"历史第 {lineNumber} 行含有无法安全转换的模型输入标识：{portable.UnsupportedReason}");
            var cleared = CodexHistoryCompat.PortableHistory.Clear(rewritten);
            if (Encoding.UTF8.GetByteCount(cleared) != Encoding.UTF8.GetByteCount(rewritten)) throw new InvalidDataException("历史模型输入标识处理改变了字节边界。");
            rewritten = cleared;
            changed = true;
        }
        _ = changed;
        return rewritten;
    }

    private static JsonElement ReadPath(JsonElement root, IReadOnlyList<string> path)
    {
        var current = root;
        foreach (var name in path) if (!current.TryGetProperty(name, out current)) throw new InvalidDataException("历史 provider 字段结构不稳定。");
        return current;
    }

    private readonly record struct ByteRange(int Start, int Length);
    private static IReadOnlyList<ByteRange> FindJsonStringRanges(byte[] utf8, IReadOnlyList<string> path)
    {
        var reader = new Utf8JsonReader(utf8, new JsonReaderOptions { CommentHandling = JsonCommentHandling.Disallow, AllowTrailingCommas = false });
        var found = new List<ByteRange>();
        if (!reader.Read()) throw new JsonException("JSONL 记录为空。");
        Visit(ref reader, [], path, found);
        return found;
    }

    private static void Visit(ref Utf8JsonReader reader, List<string> currentPath, IReadOnlyList<string> wantedPath, List<ByteRange> matches)
    {
        if (reader.TokenType == JsonTokenType.StartObject)
        {
            while (reader.Read() && reader.TokenType != JsonTokenType.EndObject)
            {
                if (reader.TokenType != JsonTokenType.PropertyName) throw new JsonException("对象属性无效。");
                var name = reader.GetString() ?? "";
                if (!reader.Read()) throw new JsonException("对象属性值缺失。");
                currentPath.Add(name);
                if (reader.TokenType == JsonTokenType.String && PathEquals(currentPath, wantedPath))
                    matches.Add(new ByteRange(checked((int)reader.TokenStartIndex), checked((int)(reader.BytesConsumed - reader.TokenStartIndex))));
                else if (reader.TokenType is JsonTokenType.StartObject or JsonTokenType.StartArray) Visit(ref reader, currentPath, wantedPath, matches);
                currentPath.RemoveAt(currentPath.Count - 1);
            }
        }
        else if (reader.TokenType == JsonTokenType.StartArray)
        {
            var index = 0;
            while (reader.Read() && reader.TokenType != JsonTokenType.EndArray)
            {
                currentPath.Add(index++.ToString(System.Globalization.CultureInfo.InvariantCulture));
                if (reader.TokenType is JsonTokenType.StartObject or JsonTokenType.StartArray) Visit(ref reader, currentPath, wantedPath, matches);
                currentPath.RemoveAt(currentPath.Count - 1);
            }
        }
    }

    private static bool PathEquals(IReadOnlyList<string> actual, IReadOnlyList<string> expected) => actual.Count == expected.Count && actual.SequenceEqual(expected, StringComparer.Ordinal);

    private IReadOnlyList<ProviderRow> ReadRelatedProviderRows(string path, HashSet<string> threadIds)
    {
        if (threadIds.Count == 0) return [];
        using var connection = OpenReadOnly(path);
        QuickCheck(connection);
        using var tableCommand = connection.CreateCommand();
        tableCommand.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='threads'";
        if (Convert.ToInt32(tableCommand.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture) == 0) return [];
        using var columnsCommand = connection.CreateCommand(); columnsCommand.CommandText = "SELECT name FROM pragma_table_info('threads')";
        var columns = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        using (var columnReader = columnsCommand.ExecuteReader()) while (columnReader.Read()) columns.Add(columnReader.GetString(0));
        var hasId = columns.Contains("id"); var hasProvider = columns.Contains("model_provider");
        if (!hasId && !hasProvider) return [];
        if (hasId != hasProvider) throw new InvalidDataException($"SQLite threads 表缺少 id 或 model_provider 字段：{Path.GetFileName(path)}");
        var result = new List<ProviderRow>();
        using var command = connection.CreateCommand(); command.CommandText = "SELECT id, model_provider FROM threads ORDER BY id";
        using var reader = command.ExecuteReader();
        while (reader.Read())
        {
            var threadId = ReadSqliteText(reader, 0);
            if (!threadIds.Contains(threadId)) continue;
            var provider = reader.IsDBNull(1) ? "" : ReadSqliteText(reader, 1);
            if (provider.Length == 0 || !ProviderName.IsMatch(provider)) throw new InvalidDataException($"SQLite provider 值无效，无法安全修复：{Path.GetFileName(path)}");
            if (provider != "openai") result.Add(new ProviderRow(threadId, provider));
        }
        return result;
    }

    private IEnumerable<string> EnumerateHistoryFiles()
    {
        foreach (var folder in new[] { Path.Combine(paths.CodexHome, "sessions"), Path.Combine(paths.CodexHome, "archived_sessions") })
            if (Directory.Exists(folder)) foreach (var file in Directory.EnumerateFiles(folder, "*.jsonl", SearchOption.AllDirectories)) yield return Path.GetFullPath(file);
    }

    private IEnumerable<string> EnumerateDatabaseFiles()
    {
        foreach (var folder in new[] { paths.CodexHome, Path.Combine(paths.CodexHome, "sqlite") })
        {
            if (!Directory.Exists(folder)) continue;
            foreach (var file in Directory.EnumerateFiles(folder, "*.sqlite", SearchOption.TopDirectoryOnly))
            {
                cancellationTokenThrowIfCorrupt(file);
                if (HasHistoryTable(file)) yield return Path.GetFullPath(file);
            }
        }
    }

    private static void cancellationTokenThrowIfCorrupt(string path)
    {
        using var connection = OpenReadOnly(path);
        QuickCheck(connection);
    }

    private static bool HasHistoryTable(string path)
    {
        using var connection = OpenReadOnly(path);
        using var command = connection.CreateCommand(); command.CommandText = "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('threads','thread_items','thread_turns','thread_history_projection_state')";
        return Convert.ToInt32(command.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture) > 0;
    }

    private static SqliteConnection OpenReadOnly(string path)
    {
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Mode = SqliteOpenMode.ReadOnly, Cache = SqliteCacheMode.Private }.ConnectionString);
        connection.Open();
        using var timeout = connection.CreateCommand(); timeout.CommandText = "PRAGMA busy_timeout=5000"; timeout.ExecuteNonQuery();
        return connection;
    }

    private static SqliteConnection OpenReadWrite(string path)
    {
        var connection = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Mode = SqliteOpenMode.ReadWrite, Cache = SqliteCacheMode.Private }.ConnectionString);
        connection.Open();
        using var timeout = connection.CreateCommand(); timeout.CommandText = "PRAGMA busy_timeout=5000"; timeout.ExecuteNonQuery();
        return connection;
    }

    private static void BackupDatabase(string sourcePath, string backupPath)
    {
        using var source = OpenReadOnly(sourcePath);
        using var destination = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = backupPath, Mode = SqliteOpenMode.ReadWriteCreate }.ConnectionString);
        destination.Open();
        source.BackupDatabase(destination);
        destination.Close();
        using var verify = OpenReadOnly(backupPath); QuickCheck(verify);
    }

    private static void VerifyDatabase(string path, IReadOnlyList<ProviderRow> rows, string expected)
    {
        using var connection = OpenReadOnly(path); QuickCheck(connection); VerifyProviderRows(connection, null, rows, expected);
    }

    private static void VerifyProviderRows(SqliteConnection connection, SqliteTransaction? transaction, IReadOnlyList<ProviderRow> rows, string expected)
    {
        foreach (var row in rows)
        {
            using var command = connection.CreateCommand(); command.Transaction = transaction;
            command.CommandText = "SELECT model_provider FROM threads WHERE id = $id"; command.Parameters.AddWithValue("$id", row.ThreadId);
            var result = command.ExecuteScalar();
            if (!string.Equals(Convert.ToString(result, System.Globalization.CultureInfo.InvariantCulture), expected, StringComparison.Ordinal)) throw new InvalidDataException("SQLite thread provider 写入后校验失败。");
        }
    }

    private static void QuickCheck(SqliteConnection connection, SqliteTransaction? transaction = null)
    {
        using var command = connection.CreateCommand(); command.Transaction = transaction; command.CommandText = "PRAGMA quick_check";
        if (!string.Equals(Convert.ToString(command.ExecuteScalar(), System.Globalization.CultureInfo.InvariantCulture), "ok", StringComparison.Ordinal)) throw new InvalidDataException("SQLite quick_check 未通过；未继续修改历史。");
    }

    private static string ReadSqliteText(SqliteDataReader reader, int ordinal)
    {
        var value = reader.GetValue(ordinal);
        if (value is string text) return text;
        if (value is byte[] bytes) return new UTF8Encoding(false, true).GetString(bytes);
        return Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture) ?? "";
    }

    private bool IsReady(string path, string fingerprint)
    {
        try
        {
            var stamp = JsonSerializer.Deserialize<ReadyStamp>(files.ReadAllBytes(path));
            return stamp is { Version: 4 } && string.Equals(stamp.CodexHome, paths.CodexHome, StringComparison.OrdinalIgnoreCase) && string.Equals(stamp.Fingerprint, fingerprint, StringComparison.Ordinal);
        }
        catch (Exception ex) when (ex is JsonException or IOException) { return false; }
    }

    private void WriteReady(string path, string fingerprint, int fileCount, int databaseCount)
    {
        var content = JsonSerializer.SerializeToUtf8Bytes(new ReadyStamp(4, paths.CodexHome, fingerprint, fileCount, databaseCount));
        files.WriteAtomic(path, content);
    }

    private static string Fingerprint(IEnumerable<string> filePaths)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        // Committed changes may live exclusively in WAL; -shm is a volatile reader index, not content.
        var contentFiles = filePaths.SelectMany(path => path.EndsWith(".sqlite", StringComparison.OrdinalIgnoreCase) && File.Exists(path + "-wal")
            ? new[] { path, path + "-wal" } : new[] { path });
        foreach (var path in contentFiles.OrderBy(value => value, StringComparer.OrdinalIgnoreCase))
        {
            var info = new FileInfo(path);
            var header = Encoding.UTF8.GetBytes($"{path}|{info.Length}|{info.LastWriteTimeUtc.Ticks}\n");
            hash.AppendData(header);
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var buffer = ArrayPool<byte>.Shared.Rent(1024 * 1024);
            try { int count; while ((count = stream.Read(buffer, 0, buffer.Length)) > 0) hash.AppendData(buffer, 0, count); }
            finally { ArrayPool<byte>.Shared.Return(buffer, clearArray: true); }
        }
        return Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
    }

    private static string Hash(ReadOnlySpan<byte> bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
}
