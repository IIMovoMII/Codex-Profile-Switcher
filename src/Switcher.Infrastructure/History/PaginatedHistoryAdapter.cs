using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Data.Sqlite;

namespace Switcher.Infrastructure.History;

// Only identifiers and owned values are persisted. Conversation text is covered by digests, not copied into the manifest.
internal sealed record HistoryDbValue(string Type, string? Value)
{
    public static HistoryDbValue From(object value) => value switch
    {
        DBNull => new("null", null), byte[] bytes => new("blob", Convert.ToBase64String(bytes)),
        string text => new("text", text), long number => Integer(number),
        double number => new("real", number.ToString("R", CultureInfo.InvariantCulture)),
        _ => throw new InvalidDataException("历史数据库值类型未适配，未修改历史。")
    };
    public static HistoryDbValue Integer(long number) => new("integer", number.ToString(CultureInfo.InvariantCulture));
    public object ToParameter() => Type switch
    {
        "null" => DBNull.Value, "blob" => Convert.FromBase64String(Value!), "text" => Value!,
        "integer" => long.Parse(Value!, CultureInfo.InvariantCulture), "real" => double.Parse(Value!, CultureInfo.InvariantCulture),
        _ => throw new InvalidDataException("历史恢复值类型无效。")
    };
    [JsonIgnore] public long Number => Type == "integer" ? (long)ToParameter() : throw new InvalidDataException("分页偏移或 ordinal 不是整数，未修改历史。");
    [JsonIgnore] public string Text => Type == "text" ? Value! : throw new InvalidDataException("分页标识不是文本，未修改历史。");
}

internal sealed record HistoryDbScope(string Table, string ThreadId);
internal sealed record HistoryDbChange(string Table, Dictionary<string, HistoryDbValue> Key,
    Dictionary<string, HistoryDbValue> Original, Dictionary<string, HistoryDbValue> Target);
internal sealed record HistoryDbPlan(IReadOnlyList<HistoryDbScope> Scopes, IReadOnlyList<HistoryDbChange> Changes,
    string SchemaHash, string OriginalHash, string TargetHash, IReadOnlyList<string> ProjectionIds);

/// <summary>Adapts native pagination without touching visible item IDs, item_json, turn text or ordinals.</summary>
internal static class PaginatedHistoryAdapter
{
    private static readonly string[] Tables = ["threads", "thread_items", "thread_turns", "thread_history_projection_state"];
    private static readonly Dictionary<string, string[]> Keys = new(StringComparer.Ordinal)
    {
        ["threads"] = ["id"], ["thread_items"] = ["thread_id", "turn_id", "item_id"],
        ["thread_turns"] = ["thread_id", "turn_id"], ["thread_history_projection_state"] = ["thread_id"]
    };
    private static string Q(string name) => '"' + name.Replace("\"", "\"\"", StringComparison.Ordinal) + '"';

    public static HistoryDbPlan? Build(SqliteConnection connection, IReadOnlyList<HistoryJournal> journals,
        IReadOnlyList<(string ThreadId, string OldProvider)> providers)
    {
        var scopes = new List<HistoryDbScope>(); var changes = new List<HistoryDbChange>(); var projections = new HashSet<string>(StringComparer.Ordinal);
        var schema = ReadSchema(connection, null);
        foreach (var provider in providers)
        {
            scopes.Add(new("threads", provider.ThreadId));
            var row = ReadRows(connection, null, scopes[^1]).Single();
            changes.Add(Change("threads", row, new() { ["model_provider"] = new("text", "openai") }));
        }
        foreach (var journal in journals.Where(journal => journal.Changed && journal.LogicalId.Length > 0))
        {
            var related = new Dictionary<string, IReadOnlyList<Dictionary<string, HistoryDbValue>>>(StringComparer.Ordinal);
            foreach (var table in Tables.Where(table => table != "threads" && schema.ContainsKey(table)))
            {
                if (!Columns(connection, null, table).Contains("thread_id")) continue;
                related[table] = ReadRows(connection, null, new(table, journal.ProjectionId));
            }
            if (!related.Values.Any(rows => rows.Count > 0)) continue;
            try { journal.ValidatePagination(); }
            catch (InvalidDataException ex) { throw new InvalidDataException("已发现分页历史投影数据库，但 " + ex.Message, ex); }
            foreach (var (table, rows) in related)
            {
                // Empty projections are witnesses too: an external insertion must invalidate the plan.
                scopes.Add(new(table, journal.ProjectionId));
                if (rows.Count == 0) continue;
                RequireColumns(connection, table, Keys[table]);
                if (journal.LayoutChanged && Columns(connection, null, table).Any(column =>
                    column.Contains("byte_offset", StringComparison.OrdinalIgnoreCase) && column is not ("next_rollout_byte_offset" or "rollout_byte_offset" or "rollout_end_byte_offset")))
                    throw new InvalidDataException("已发现分页历史投影数据库，但存在未知字节偏移列，未修改历史。");
            }
            if (!related.TryGetValue("thread_history_projection_state", out var cursors) || cursors.Count != 1)
                throw new InvalidDataException("已发现分页历史投影数据库，但缺少唯一投影游标，未修改历史。");
            RequireColumns(connection, "thread_history_projection_state", ["next_rollout_byte_offset", "next_rollout_ordinal"]);
            var cursor = cursors.Single(); var oldOffset = cursor["next_rollout_byte_offset"].Number;
            journal.ValidateCursor(oldOffset, cursor["next_rollout_ordinal"].Number);
            var nextOffset = journal.MapOffset(oldOffset);
            if (nextOffset != oldOffset) changes.Add(Change("thread_history_projection_state", cursor, new() { ["next_rollout_byte_offset"] = HistoryDbValue.Integer(nextOffset) }));
            if (!projections.Add(journal.ProjectionId)) throw new InvalidDataException("多个分页文件指向同一投影，未修改历史。");

            var items = related.GetValueOrDefault("thread_items") ?? [];
            var turns = related.GetValueOrDefault("thread_turns") ?? [];
            // A response_item ID is model replay data. Native UI IDs must instead have unchanged event sources.
            if (ModelInputChanged(journal)) ValidateUiSources(journal, items, turns, oldOffset);
            foreach (var turn in turns)
            {
                var updates = new Dictionary<string, HistoryDbValue>(StringComparer.Ordinal);
                foreach (var column in new[] { "rollout_byte_offset", "rollout_end_byte_offset" })
                    if (turn.TryGetValue(column, out var value) && value.Type != "null")
                    {
                        var mapped = journal.MapOffset(value.Number);
                        if (mapped != value.Number) updates[column] = HistoryDbValue.Integer(mapped);
                    }
                if (updates.Count > 0) changes.Add(Change("thread_turns", turn, updates));
            }
        }
        scopes = scopes.Distinct().ToList();
        if (scopes.Count == 0) return null;
        var schemaHash = SchemaHash(connection, null);
        var originalHash = Snapshot(connection, null, scopes);
        var targetHash = Snapshot(connection, null, scopes, changes);
        return new(scopes, changes, schemaHash, originalHash, targetHash, projections.ToArray());
    }

    public static void ValidatePlan(HistoryDbPlan plan)
    {
        if (plan.Scopes is null || plan.Changes is null || plan.ProjectionIds is null || plan.Scopes.Count == 0 ||
            new[] { plan.SchemaHash, plan.OriginalHash, plan.TargetHash }.Any(hash => hash is null || hash.Length != 64 || hash.Any(value => !Uri.IsHexDigit(value))))
            throw new InvalidDataException("分页历史恢复计划不完整。");
        foreach (var scope in plan.Scopes)
            if (!Keys.ContainsKey(scope.Table) || string.IsNullOrWhiteSpace(scope.ThreadId)) throw new InvalidDataException("分页历史恢复范围无效。");
        foreach (var change in plan.Changes)
        {
            var allowed = change.Table switch
            {
                "threads" => new[] { "model_provider" }, "thread_history_projection_state" => ["next_rollout_byte_offset"],
                "thread_turns" => ["rollout_byte_offset", "rollout_end_byte_offset"], _ => []
            };
            if (!Keys.TryGetValue(change.Table, out var keys) || !keys.Order().SequenceEqual(change.Key.Keys.Order()) ||
                change.Original.Count == 0 || !change.Original.Keys.Order().SequenceEqual(change.Target.Keys.Order()) ||
                change.Target.Keys.Any(column => !allowed.Contains(column)) ||
                !plan.Scopes.Contains(new(change.Table, change.Key[change.Table == "threads" ? "id" : "thread_id"].Text)))
                throw new InvalidDataException("分页历史恢复字段越界。");
            foreach (var value in change.Key.Values.Concat(change.Original.Values).Concat(change.Target.Values)) _ = value.ToParameter();
        }
    }

    public static bool IsApplied(SqliteConnection connection, HistoryDbPlan plan, SqliteTransaction? transaction = null)
    {
        ValidatePlan(plan);
        if (SchemaHash(connection, transaction) != plan.SchemaHash) throw new IOException("历史数据库结构发生外部变化，保留恢复材料。");
        var current = Snapshot(connection, transaction, plan.Scopes);
        if (current == plan.TargetHash) return true;
        if (current == plan.OriginalHash) return false;
        throw new IOException("历史数据库相关投影发生外部变化，保留恢复材料并停止覆盖。");
    }

    public static void Apply(SqliteConnection connection, SqliteTransaction transaction, HistoryDbPlan plan, bool restore)
    {
        var applied = IsApplied(connection, plan, transaction);
        if (restore ? !applied : applied && plan.OriginalHash != plan.TargetHash) return;
        foreach (var change in restore ? plan.Changes.Reverse() : plan.Changes)
        {
            var expected = restore ? change.Target : change.Original;
            var target = restore ? change.Original : change.Target;
            using var command = connection.CreateCommand(); command.Transaction = transaction;
            var index = 0;
            string Parameter(HistoryDbValue value) { var name = "$v" + index++; command.Parameters.AddWithValue(name, value.ToParameter()); return name; }
            var set = target.Select(pair => Q(pair.Key) + "=" + Parameter(pair.Value)).ToArray();
            var guard = change.Key.Concat(expected).Select(pair => Q(pair.Key) + " IS " + Parameter(pair.Value)).ToArray();
            command.CommandText = $"UPDATE {Q(change.Table)} SET {string.Join(',', set)} WHERE {string.Join(" AND ", guard)}";
            if (command.ExecuteNonQuery() != 1) throw new IOException("历史投影在写入期间发生变化，保留恢复材料。");
        }
        var expectedHash = restore ? plan.OriginalHash : plan.TargetHash;
        if (SchemaHash(connection, transaction) != plan.SchemaHash || Snapshot(connection, transaction, plan.Scopes) != expectedHash)
            throw new IOException("历史投影写后校验失败，保留恢复材料。");
    }

    public static void VerifyBackup(SqliteConnection connection, HistoryDbPlan plan)
    {
        ValidatePlan(plan);
        if (SchemaHash(connection, null) != plan.SchemaHash || Snapshot(connection, null, plan.Scopes) != plan.OriginalHash)
            throw new InvalidDataException("分页历史恢复备份与计划不匹配。");
    }

    private static HistoryDbChange Change(string table, Dictionary<string, HistoryDbValue> row, Dictionary<string, HistoryDbValue> target) =>
        new(table, Keys[table].ToDictionary(key => key, key => row[key], StringComparer.Ordinal), target.Keys.ToDictionary(column => column, column => row[column], StringComparer.Ordinal), target);

    private static bool ModelInputChanged(HistoryJournal journal) => journal.Lines.Any(line =>
        (Text(line.Json, "type") is "response_item" or "compacted") && CodexHistoryCompat.PortableHistory.Inspect(line.Json.GetRawText(), 0) is not null);

    private static void ValidateUiSources(HistoryJournal journal, IReadOnlyList<Dictionary<string, HistoryDbValue>> items,
        IReadOnlyList<Dictionary<string, HistoryDbValue>> turns, long cursor)
    {
        foreach (var item in items)
        {
            var required = new[] { "turn_id", "item_id", "rollout_ordinal", "item_json", "item_type", "updated_at_ordinal" };
            if (required.Any(column => !item.ContainsKey(column))) throw new InvalidDataException("分页项目投影缺少来源字段，未修改历史。");
            using var json = JsonDocument.Parse(item["item_json"].Text);
            if (Text(json.RootElement, "id") != item["item_id"].Text || Text(json.RootElement, "type") != item["item_type"].Text)
                throw new InvalidDataException("分页项目标识与投影内容不一致，未修改历史。");
            var first = item["rollout_ordinal"].Number; var updated = item["updated_at_ordinal"].Number;
            foreach (var ordinal in new[] { first, Math.Max(first, updated) }.Distinct())
            {
                if (!journal.Ordinals.TryGetValue(ordinal, out var line) || line.End > cursor || Text(line.Json, "type") != "event_msg" ||
                    !line.Json.TryGetProperty("payload", out var payload) || Text(payload, "type") is not ("item_completed" or "item_started" or "item_updated") ||
                    !journal.IsOwnUiEvent(line) || Text(payload, "turn_id") != item["turn_id"].Text || !payload.TryGetProperty("item", out var source) ||
                    Text(source, "id") != item["item_id"].Text || UiType(source) != item["item_type"].Text)
                    throw new InvalidDataException("分页界面项目无法核实为独立事件来源，未清除模型输入标识。");
            }
        }
        var ids = items.Select(item => (Turn: item["turn_id"].Text, Id: item["item_id"].Text)).ToHashSet();
        foreach (var turn in turns)
            foreach (var column in new[] { "first_user_item_id", "final_agent_item_id" })
                if (turn.TryGetValue(column, out var value) && value.Type != "null" && !ids.Contains((turn["turn_id"].Text, value.Text)))
                    throw new InvalidDataException("分页轮次存在悬空项目引用，未修改历史。");
    }

    private static string UiType(JsonElement item)
    {
        var type = Text(item, "type");
        if (type == "Extension") return Text(item, "kind") switch { "clock.sleep" => "sleep", "web.search" => "webSearch", _ => "extension" };
        return type.Length == 0 ? "" : char.ToLowerInvariant(type[0]) + type[1..];
    }

    private static string Text(JsonElement root, string name) => HistoryJournal.Text(root, name);
    private static void RequireColumns(SqliteConnection connection, string table, IEnumerable<string> required)
    {
        var columns = Columns(connection, null, table);
        if (required.Any(column => !columns.Contains(column))) throw new InvalidDataException("已发现分页历史投影数据库，但必要字段缺失，未修改历史。");
    }

    private static HashSet<string> Columns(SqliteConnection connection, SqliteTransaction? transaction, string table)
    {
        using var command = connection.CreateCommand(); command.Transaction = transaction;
        command.CommandText = "SELECT name FROM pragma_table_info($table)"; command.Parameters.AddWithValue("$table", table);
        using var reader = command.ExecuteReader(); var result = new HashSet<string>(StringComparer.Ordinal);
        while (reader.Read()) result.Add(reader.GetString(0)); return result;
    }

    private static Dictionary<string, string> ReadSchema(SqliteConnection connection, SqliteTransaction? transaction)
    {
        using var command = connection.CreateCommand(); command.Transaction = transaction;
        command.CommandText = "SELECT type||':'||name,coalesce(sql,'') FROM sqlite_master WHERE tbl_name IN ('threads','thread_items','thread_turns','thread_history_projection_state') ORDER BY type,name";
        using var reader = command.ExecuteReader(); var result = new Dictionary<string, string>(StringComparer.Ordinal);
        while (reader.Read()) result.Add(reader.GetString(0).Replace("table:", "", StringComparison.Ordinal), reader.GetString(1)); return result;
    }
    private static string SchemaHash(SqliteConnection connection, SqliteTransaction? transaction) => Hash(JsonSerializer.Serialize(ReadSchema(connection, transaction)));

    private static IReadOnlyList<Dictionary<string, HistoryDbValue>> ReadRows(SqliteConnection connection, SqliteTransaction? transaction, HistoryDbScope scope)
    {
        if (!Keys.ContainsKey(scope.Table)) throw new InvalidDataException("历史投影表名未适配。");
        using var command = connection.CreateCommand(); command.Transaction = transaction;
        command.CommandText = $"SELECT * FROM {Q(scope.Table)} WHERE {Q(scope.Table == "threads" ? "id" : "thread_id")}=$id";
        command.Parameters.AddWithValue("$id", scope.ThreadId);
        using var reader = command.ExecuteReader(); var rows = new List<Dictionary<string, HistoryDbValue>>();
        while (reader.Read())
        {
            var row = new Dictionary<string, HistoryDbValue>(StringComparer.Ordinal);
            for (var index = 0; index < reader.FieldCount; index++) row.Add(reader.GetName(index), HistoryDbValue.From(reader.GetValue(index)));
            rows.Add(row);
        }
        return rows;
    }

    private static string Snapshot(SqliteConnection connection, SqliteTransaction? transaction, IReadOnlyList<HistoryDbScope> scopes,
        IReadOnlyList<HistoryDbChange>? targets = null)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        foreach (var scope in scopes.OrderBy(scope => scope.Table, StringComparer.Ordinal).ThenBy(scope => scope.ThreadId, StringComparer.Ordinal))
        {
            hash.AppendData(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(scope) + "\n"));
            var rows = ReadRows(connection, transaction, scope);
            var rendered = new List<string>();
            foreach (var row in rows)
            {
                if (targets is not null)
                    foreach (var target in targets.Where(change => change.Table == scope.Table && change.Key.All(pair => row.GetValueOrDefault(pair.Key) == pair.Value)))
                        foreach (var pair in target.Target) row[pair.Key] = pair.Value;
                rendered.Add(JsonSerializer.Serialize(row.OrderBy(pair => pair.Key, StringComparer.Ordinal)));
            }
            foreach (var text in rendered.Order(StringComparer.Ordinal)) hash.AppendData(Encoding.UTF8.GetBytes(text + "\n"));
        }
        return Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
    }
    private static string Hash(string text) => Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text))).ToLowerInvariant();
}
