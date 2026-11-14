using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Switcher.Infrastructure.History;

/// <summary>Byte boundaries belong to UTF-8 records, never to .NET character positions.</summary>
internal sealed class HistoryJournal
{
    internal sealed record Line(long Start, long ContentEnd, long End, long? Ordinal, JsonElement Json);
    private sealed record InheritedPrefix(string ParentId, long EndOrdinal);
    private static readonly UTF8Encoding Utf8 = new(false, true);
    private static readonly Regex Rollout = new(@"^rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-(?<logical>[0-9a-f-]{36})(?:_(?<segment>[0-9a-f-]{36}))?\.jsonl$", RegexOptions.CultureInvariant);

    public string Path { get; }
    public byte[] Original { get; }
    public byte[] Target { get; private set; }
    public IReadOnlyList<Line> Lines { get; }
    public string LogicalId { get; }
    public string ProjectionId { get; }
    public bool Paginated { get; }
    public bool Changed => !Original.AsSpan().SequenceEqual(Target);
    public bool LayoutChanged => _boundaries.Any(boundary => boundary.Key != boundary.Value);
    public JsonElement Metadata { get; }
    public IReadOnlyDictionary<long, Line> Ordinals { get; }
    private Dictionary<long, long> _boundaries = [];
    private readonly InheritedPrefix? _inheritedPrefix;

    public HistoryJournal(string path, byte[] original, byte[] target)
    {
        Path = path; Original = original; Target = target; Lines = Parse(original);
        var metadata = Lines.Where(line => Text(line.Json, "type") == "session_meta").ToArray();
        if (metadata.Any(line => !line.Json.TryGetProperty("payload", out var payload) || string.IsNullOrWhiteSpace(Text(payload, "id"))))
            throw new InvalidDataException("历史会话元数据缺少有效身份，未修改历史。");
        var ids = metadata.Select(line => Text(line.Json.GetProperty("payload"), "id")).Distinct(StringComparer.Ordinal).ToArray();
        Metadata = metadata.Length == 0 ? default : metadata[0].Json.GetProperty("payload");
        LogicalId = ids.FirstOrDefault() ?? "";
        ProjectionId = LogicalId;
        Paginated = Text(Metadata, "history_mode") == "paginated";
        var segment = Rollout.Match(System.IO.Path.GetFileName(path));
        if (Paginated && segment.Success)
        {
            if (segment.Groups["logical"].Value != LogicalId) throw new InvalidDataException("分页文件名与会话元数据不符，未修改历史。");
            if (segment.Groups["segment"].Success) ProjectionId = segment.Groups["segment"].Value;
        }
        if (ids.Length > 1) _inheritedPrefix = ReadInheritedPrefix(metadata);
        Ordinals = Lines.Where(line => line.Ordinal.HasValue).GroupBy(line => line.Ordinal!.Value)
            .Where(group => group.Count() == 1).ToDictionary(group => group.Key, group => group.Single());
        if (_inheritedPrefix is not null) ValidatePagination();
        RebuildBoundaries();
    }

    private InheritedPrefix ReadInheritedPrefix(IReadOnlyList<Line> metadata)
    {
        const string error = "同一历史文件含有不同会话身份，且无法核实为子代理继承前缀，未修改历史。";
        var parent = Text(Metadata, "parent_thread_id"); var session = Text(Metadata, "session_id");
        // A fork can carry a rebased copy of its parent's metadata and replay records. Only the
        // first header owns this physical file; history_base inside a copied header is inert context.
        if (!Paginated || Lines[0] != metadata[0] || Lines[0].Ordinal != 0 || Text(Metadata, "thread_source") != "subagent" ||
            parent.Length == 0 || parent == LogicalId || Text(Metadata, "forked_from_id") != parent || session.Length == 0 ||
            HasValue(Metadata, "history_base") || HasValue(Metadata, "forked_from_ordinal_exclusive") ||
            !Metadata.TryGetProperty("source", out var source) || source.ValueKind != JsonValueKind.Object ||
            !source.TryGetProperty("subagent", out var subagent) || subagent.ValueKind != JsonValueKind.Object ||
            !subagent.TryGetProperty("thread_spawn", out var spawn) || Text(spawn, "parent_thread_id") != parent ||
            !Metadata.TryGetProperty("subagent_history_start_ordinal", out var boundary) || boundary.ValueKind != JsonValueKind.Number ||
            !boundary.TryGetInt64(out var end) || end < 2 || Lines[^1].Ordinal is not long last || end > last + 1)
            throw new InvalidDataException(error);
        foreach (var line in metadata.Skip(1))
        {
            var payload = line.Json.GetProperty("payload");
            if (line.Ordinal is not long ordinal || ordinal < 1 || ordinal >= end || Text(payload, "id") != parent ||
                Text(payload, "session_id") != session || Text(payload, "history_mode") != "paginated")
                throw new InvalidDataException(error);
        }
        if (Lines.Where((line, index) => line.Ordinal != index).Any()) throw new InvalidDataException(error);
        return new(parent, end);
    }

    public bool IsOwnUiEvent(Line line) => (_inheritedPrefix is null || line.Ordinal >= _inheritedPrefix.EndOrdinal) &&
        line.Json.TryGetProperty("payload", out var payload) && Text(payload, "thread_id") == LogicalId;

    public void ValidatePagination()
    {
        if (string.IsNullOrWhiteSpace(LogicalId) || Lines.Count == 0 || Text(Lines[0].Json, "type") != "session_meta")
            throw new InvalidDataException("分页历史缺少初始会话元数据，未修改历史。");
        long previous = -1;
        foreach (var line in Lines)
        {
            if (line.Ordinal is not long ordinal || ordinal < 0 || ordinal <= previous)
                throw new InvalidDataException("分页历史 ordinal 缺失、重复或顺序无效，未修改历史。");
            previous = ordinal;
            if (Text(line.Json, "type") == "event_msg" && line.Json.TryGetProperty("payload", out var payload))
            {
                var owner = Text(payload, "thread_id");
                if (owner.Length > 0 && owner != LogicalId &&
                    !(_inheritedPrefix is not null && ordinal < _inheritedPrefix.EndOrdinal && owner == _inheritedPrefix.ParentId))
                    throw new InvalidDataException("分页历史含有其他会话的事件，未修改历史。");
            }
        }
        if (Metadata.TryGetProperty("history_base", out var historyBase) && historyBase.ValueKind != JsonValueKind.Null)
        {
            if (historyBase.ValueKind != JsonValueKind.Object || Text(historyBase, "thread_id").Length == 0 ||
                !historyBase.TryGetProperty("end_byte_offset", out var byteOffset) || byteOffset.ValueKind != JsonValueKind.Number || !byteOffset.TryGetInt64(out var endOffset) || endOffset < 1 ||
                !historyBase.TryGetProperty("end_ordinal_exclusive", out var ordinal) || ordinal.ValueKind != JsonValueKind.Number || !ordinal.TryGetInt64(out var endOrdinal) ||
                endOrdinal < 1 || Lines[0].Ordinal != endOrdinal)
                throw new InvalidDataException("分页分段继承 ordinal 不一致，未修改历史。");
        }
        else if (ProjectionId != LogicalId)
        {
            if (Lines[0].Ordinal != 0 || Lines.Where((line, index) => line.Ordinal != index).Any())
                throw new InvalidDataException("独立分页分段的 ordinal 不连续，未修改历史。");
            if (_inheritedPrefix is null && (new[] { "forked_from_id", "forked_from_ordinal_exclusive" }.Any(name => HasValue(Metadata, name)) ||
                (Metadata.TryGetProperty("session_id", out var sessionId) && sessionId.ValueKind != JsonValueKind.Null && (sessionId.ValueKind != JsonValueKind.String || sessionId.GetString() != LogicalId))))
                throw new InvalidDataException("独立分页分段仍有未核验的继承信息或归属冲突，未修改历史。");
        }
    }

    public long MapOffset(long value)
    {
        if (_boundaries.TryGetValue(value, out var target)) return target;
        throw new InvalidDataException("分页字节偏移未对齐 JSONL 记录边界，未修改历史。");
    }

    public void ValidateCursor(long offset, long ordinal)
    {
        ValidatePagination();
        _ = MapOffset(offset);
        var next = Lines.FirstOrDefault(line => line.Start == offset);
        var expected = offset == Original.LongLength ? checked(Lines[^1].Ordinal!.Value + 1) : next?.Ordinal;
        if (expected is null || ordinal != expected) throw new InvalidDataException("分页游标与 JSONL ordinal 不一致，未修改历史。");
    }

    public void UpdateParentBoundary(HistoryJournal parent)
    {
        if (Metadata.ValueKind != JsonValueKind.Object || !Metadata.TryGetProperty("history_base", out var historyBase) || historyBase.ValueKind == JsonValueKind.Null) return;
        if (historyBase.ValueKind != JsonValueKind.Object || !historyBase.TryGetProperty("end_byte_offset", out var offset) || offset.ValueKind != JsonValueKind.Number || !offset.TryGetInt64(out var oldOffset) ||
            !historyBase.TryGetProperty("end_ordinal_exclusive", out var ordinal) || ordinal.ValueKind != JsonValueKind.Number || !ordinal.TryGetInt64(out var nextOrdinal))
            throw new InvalidDataException("分页继承边界格式无效，未修改历史。");
        parent.ValidateCursor(oldOffset, nextOrdinal);
        var mapped = parent.MapOffset(oldOffset);
        if (mapped != oldOffset)
        {
            Target = ReplaceNumber(Target, ["payload", "history_base", "end_byte_offset"], mapped);
            RebuildBoundaries();
        }
    }

    public static void UpdateParentBoundaries(IReadOnlyList<HistoryJournal> journals)
    {
        var visited = new HashSet<HistoryJournal>(); var visiting = new HashSet<HistoryJournal>();
        void Visit(HistoryJournal journal)
        {
            if (visited.Contains(journal)) return;
            if (!visiting.Add(journal)) throw new InvalidDataException("分页历史继承关系形成循环，未修改历史。");
            var parentId = journal.Metadata.ValueKind == JsonValueKind.Object && journal.Metadata.TryGetProperty("history_base", out var node) ? Text(node, "thread_id") : "";
            if (parentId.Length > 0)
            {
                if (parentId == journal.ProjectionId) throw new InvalidDataException("分页历史不能继承自身，未修改历史。");
                var candidates = journals.Where(candidate => candidate != journal && candidate.ProjectionId == parentId).ToArray();
                if (candidates.Length > 1) throw new InvalidDataException("分页继承来源不唯一，未修改历史。");
                if (candidates.Length == 1) { Visit(candidates[0]); journal.UpdateParentBoundary(candidates[0]); }
                // A retained parent outside this CODEX_HOME is never rewritten by this operation.
            }
            visiting.Remove(journal); visited.Add(journal);
        }
        foreach (var journal in journals.Where(journal => journal.Paginated)) Visit(journal);
    }

    private void RebuildBoundaries()
    {
        var target = Parse(Target);
        if (target.Count != Lines.Count) throw new InvalidDataException("历史改写改变了记录数量，未继续处理。");
        _boundaries = new() { [0] = 0, [Original.LongLength] = Target.LongLength };
        for (var index = 0; index < Lines.Count; index++)
        {
            _boundaries[Lines[index].Start] = target[index].Start;
            _boundaries[Lines[index].ContentEnd] = target[index].ContentEnd;
            _boundaries[Lines[index].End] = target[index].End;
        }
    }

    private static IReadOnlyList<Line> Parse(byte[] bytes)
    {
        var result = new List<Line>(); var start = 0;
        while (start < bytes.Length)
        {
            var newline = Array.IndexOf(bytes, (byte)'\n', start);
            var end = newline < 0 ? bytes.Length : newline + 1;
            var contentEnd = newline < 0 ? bytes.Length : newline;
            if (contentEnd > start && bytes[contentEnd - 1] == '\r') contentEnd--;
            var contentStart = start == 0 && bytes.AsSpan().StartsWith(Encoding.UTF8.Preamble) ? Encoding.UTF8.Preamble.Length : start;
            var text = Utf8.GetString(bytes, contentStart, contentEnd - contentStart);
            if (!string.IsNullOrWhiteSpace(text))
            {
                using var json = JsonDocument.Parse(text); var root = json.RootElement.Clone();
                long? ordinal = root.ValueKind == JsonValueKind.Object && root.TryGetProperty("ordinal", out var value) && value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var number) ? number : null;
                result.Add(new(start, contentEnd, end, ordinal, root));
            }
            start = end;
        }
        return result;
    }

    private static byte[] ReplaceNumber(byte[] bytes, string[] path, long value)
    {
        var line = Parse(bytes).First(record => Text(record.Json, "type") == "session_meta");
        var begin = checked((int)line.Start);
        if (begin == 0 && bytes.AsSpan().StartsWith(Encoding.UTF8.Preamble)) begin += Encoding.UTF8.Preamble.Length;
        var reader = new Utf8JsonReader(bytes.AsSpan(begin, checked((int)line.ContentEnd) - begin));
        var current = new List<string>(); (int Start, int End)? range = null;
        void Unsupported() => throw new InvalidDataException("分页继承偏移无法唯一定位，未修改历史。");
        // The target is an object path; nesting in arrays is intentionally excluded.
        while (reader.Read())
        {
            if (reader.TokenType == JsonTokenType.PropertyName)
            {
                var name = reader.GetString()!;
                if (!reader.Read()) { Unsupported(); break; }
                if (current.Append(name).SequenceEqual(path))
                {
                    if (range is not null || reader.TokenType != JsonTokenType.Number) Unsupported();
                    range = (begin + (int)reader.TokenStartIndex, begin + (int)reader.BytesConsumed);
                }
                if (reader.TokenType == JsonTokenType.StartObject) current.Add(name);
                else if (reader.TokenType == JsonTokenType.StartArray) reader.Skip();
            }
            else if (reader.TokenType == JsonTokenType.EndObject && current.Count > 0) current.RemoveAt(current.Count - 1);
        }
        if (range is null) { Unsupported(); return bytes; }
        var token = Encoding.UTF8.GetBytes(value.ToString(CultureInfo.InvariantCulture));
        return [.. bytes.AsSpan(0, range.Value.Start), .. token, .. bytes.AsSpan(range.Value.End)];
    }

    internal static string Text(JsonElement root, string name) => root.ValueKind == JsonValueKind.Object && root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() ?? "" : "";
    private static bool HasValue(JsonElement root, string name) => root.TryGetProperty(name, out var value) && value.ValueKind != JsonValueKind.Null;
}
