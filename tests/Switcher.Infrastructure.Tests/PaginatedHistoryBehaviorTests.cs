using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Data.Sqlite;
using Switcher.Core.Abstractions;
using Switcher.Core.Paths;
using Switcher.Infrastructure.Files;
using Switcher.Infrastructure.History;

namespace Switcher.Infrastructure.Tests;

public sealed class PaginatedHistoryBehaviorTests
{
    [Theory]
    [InlineData(false, "\n", true, false)]
    [InlineData(true, "\r\n", true, false)]
    [InlineData(false, "\r\n", false, true)]
    public async Task Native_pagination_updates_byte_boundaries_and_preserves_ui_data_and_unknown_fields(bool bom, string newline, bool finalNewline, bool combinedDatabase)
    {
        using var fixture = new Fixture(bom, newline, finalNewline, combinedDatabase);
        var before = fixture.Original; var ui = fixture.UiSnapshot();
        var result = await fixture.Service.PrepareAsync(false, null, CancellationToken.None);
        Assert.True(result.Prepared); Assert.True(result.Changed);
        var target = File.ReadAllBytes(fixture.Journal);
        Assert.Equal(bom, target.AsSpan().StartsWith(Encoding.UTF8.Preamble));
        Assert.Equal(finalNewline, target[^1] == '\n');
        var originalLines = fixture.Lines(before); var targetLines = fixture.Lines(target);
        Assert.Equal(originalLines.Count, targetLines.Count);
        using (var metadata = JsonDocument.Parse(targetLines[0]))
        {
            Assert.Equal("中文😀在 provider 前", metadata.RootElement.GetProperty("unknown").GetString());
            Assert.Equal("openai", metadata.RootElement.GetProperty("payload").GetProperty("model_provider").GetString());
            Assert.Equal("2026-11-13T10:00:00Z", metadata.RootElement.GetProperty("date_string").GetString());
        }
        using (var response = JsonDocument.Parse(targetLines[3]))
        {
            var payload = response.RootElement.GetProperty("payload"); Assert.Equal(JsonValueKind.Null, payload.GetProperty("id").ValueKind);
            Assert.Equal("same-call", payload.GetProperty("call_id").GetString()); Assert.Single(payload.GetProperty("content").EnumerateArray());
        }
        using (var compacted = JsonDocument.Parse(targetLines[6]))
        {
            var item = compacted.RootElement.GetProperty("payload").GetProperty("replacement_history")[0];
            Assert.Equal(JsonValueKind.Null, item.GetProperty("id").ValueKind); Assert.Equal("encrypted-unchanged", item.GetProperty("encrypted_content").GetString());
        }
        foreach (var index in new[] { 1, 2, 4, 5, 7 }) Assert.Equal(originalLines[index], targetLines[index]);
        Assert.Equal(ui, fixture.UiSnapshot());
        Assert.Equal("openai", fixture.Scalar(fixture.StateDb, "SELECT model_provider FROM threads WHERE id='synthetic-thread'"));
        Assert.Equal("relay", fixture.Scalar(fixture.StateDb, "SELECT model_provider FROM threads WHERE id='unrelated'"));
        Assert.Equal(target.LongLength, fixture.Number("SELECT next_rollout_byte_offset FROM thread_history_projection_state WHERE thread_id='synthetic-thread'"));
        Assert.Equal(8, fixture.Number("SELECT next_rollout_ordinal FROM thread_history_projection_state WHERE thread_id='synthetic-thread'"));
        Assert.Equal(fixture.Offset(target, 1), fixture.Number("SELECT rollout_byte_offset FROM thread_turns WHERE thread_id='synthetic-thread'"));
        Assert.Equal(fixture.Offset(target, 6), fixture.Number("SELECT rollout_end_byte_offset FROM thread_turns WHERE thread_id='synthetic-thread'"));
        Assert.Equal("2030-01-02", fixture.Scalar(fixture.ProjectionDb, "SELECT unknown_date FROM thread_turns WHERE thread_id='synthetic-thread'"));
        Assert.Equal("ok", fixture.Scalar(fixture.ProjectionDb, "PRAGMA quick_check"));
        var noChange = await fixture.Service.PrepareAsync(false, null, CancellationToken.None);
        Assert.False(noChange.Changed); Assert.Single(Directory.GetDirectories(fixture.Paths.HistoryBackupsDirectory));
    }

    [Fact]
    public async Task Partial_projection_cursor_and_nullable_turn_boundaries_remain_valid()
    {
        using var fixture = new Fixture();
        fixture.Execute(fixture.ProjectionDb, "DELETE FROM thread_items WHERE item_id='visible-agent'; UPDATE thread_turns SET final_agent_item_id=NULL,rollout_end_byte_offset=NULL,rollout_end_ordinal=NULL WHERE thread_id='synthetic-thread'; UPDATE thread_history_projection_state SET next_rollout_byte_offset=$offset,next_rollout_ordinal=4 WHERE thread_id='synthetic-thread'", ("$offset", fixture.Offset(fixture.Original, 4)));
        var result = await fixture.Service.PrepareAsync(false, null, CancellationToken.None);
        Assert.True(result.Prepared);
        Assert.Equal(fixture.Offset(File.ReadAllBytes(fixture.Journal), 4), fixture.Number("SELECT next_rollout_byte_offset FROM thread_history_projection_state WHERE thread_id='synthetic-thread'"));
        Assert.Null(fixture.Scalar(fixture.ProjectionDb, "SELECT rollout_end_byte_offset FROM thread_turns WHERE thread_id='synthetic-thread'"));
    }

    [Theory]
    [InlineData("cursor")]
    [InlineData("ordinal")]
    [InlineData("ui-source")]
    [InlineData("dangling-reference")]
    public async Task Invalid_related_projection_stops_before_json_or_database_changes(string problem)
    {
        using var fixture = new Fixture();
        fixture.Execute(fixture.ProjectionDb, problem switch
        {
            "cursor" => "UPDATE thread_history_projection_state SET next_rollout_byte_offset=7 WHERE thread_id='synthetic-thread'",
            "ordinal" => "UPDATE thread_history_projection_state SET next_rollout_ordinal=99 WHERE thread_id='synthetic-thread'",
            "ui-source" => "UPDATE thread_items SET rollout_ordinal=3,updated_at_ordinal=3 WHERE item_id='visible-agent'",
            _ => "UPDATE thread_turns SET final_agent_item_id='missing-ui-item' WHERE thread_id='synthetic-thread'"
        });
        var original = fixture.DatabaseSnapshot();
        await Assert.ThrowsAsync<InvalidDataException>(() => fixture.Service.PrepareAsync(true, null, CancellationToken.None));
        Assert.Equal(fixture.Original, File.ReadAllBytes(fixture.Journal)); Assert.Equal(original, fixture.DatabaseSnapshot());
        Assert.False(Directory.Exists(fixture.Paths.HistoryBackupsDirectory)); Assert.False(File.Exists(fixture.Paths.HistoryReadyFile));
    }

    [Fact]
    public async Task Unrelated_partial_projection_schema_does_not_block_a_legacy_thread()
    {
        using var fixture = new Fixture();
        fixture.Execute(fixture.ProjectionDb, "DROP TABLE thread_items; DROP TABLE thread_turns; DROP TABLE thread_history_projection_state; CREATE TABLE thread_items(thread_id TEXT,item_json TEXT); INSERT INTO thread_items VALUES('unrelated','future format')");
        fixture.WriteJournal(["{\"unknown\":\"中文😀\",\"type\":\"session_meta\",\"payload\":{\"id\":\"synthetic-thread\",\"model_provider\":\"api\"}}"]);
        var result = await fixture.Service.PrepareAsync(false, null, CancellationToken.None);
        Assert.True(result.Prepared); Assert.Equal("future format", fixture.Scalar(fixture.ProjectionDb, "SELECT item_json FROM thread_items"));
    }

    [Fact]
    public async Task Native_segment_identity_and_inherited_byte_boundaries_follow_the_parent_without_mixing_projections()
    {
        using var fixture = new Fixture(bom: true, newline: "\r\n");
        const string logical = "11111111-1111-4111-8111-111111111111";
        const string parent = "22222222-2222-4222-8222-222222222222";
        const string child = "33333333-3333-4333-8333-333333333333";
        fixture.UseSegment(logical, parent);
        var lines = fixture.Lines(fixture.Original);
        var padding = 9999 - fixture.Original.Length;
        Assert.True(padding > 0);
        lines[^1] = lines[^1].Insert(lines[^1].Length - 1, ",\"padding\":\"" + new string('x', padding - 13) + "\"");
        fixture.WriteJournal(lines.ToArray());
        Assert.Equal(9999, fixture.Original.Length);
        fixture.Execute(fixture.ProjectionDb, "UPDATE thread_history_projection_state SET next_rollout_byte_offset=$length WHERE thread_id=$id", ("$length", fixture.Original.LongLength), ("$id", parent));
        var childPath = Path.Combine(Path.GetDirectoryName(fixture.Journal)!, $"rollout-2026-11-13T10-01-00-{logical}_{child}.jsonl");
        var metadata = JsonSerializer.Serialize(new { ordinal = 8, type = "session_meta", payload = new { id = logical, history_mode = "paginated", model_provider = "openai", history_base = new { thread_id = parent, end_byte_offset = fixture.Original.LongLength, end_ordinal_exclusive = 8 }, unknown = new[] { "继承目录😀" } } });
        var childOriginal = Encoding.UTF8.GetBytes(metadata + "\r\n{\"ordinal\":9,\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"thread_id\":\"" + logical + "\",\"turn_id\":\"child-turn\"}}\r\n");
        fixture.Files.WriteAtomic(childPath, childOriginal);
        fixture.Execute(fixture.ProjectionDb, "INSERT INTO thread_history_projection_state VALUES($child,$length,10)", ("$child", child), ("$length", childOriginal.LongLength));
        var ui = fixture.UiSnapshot();

        var result = await fixture.Service.PrepareAsync(false, null, CancellationToken.None);

        Assert.True(result.Changed); Assert.Equal(2, result.FileCount);
        var parentTarget = File.ReadAllBytes(fixture.Journal); var childTarget = File.ReadAllBytes(childPath);
        Assert.Equal(10002, parentTarget.Length); Assert.Equal(childOriginal.Length + 1, childTarget.Length);
        using var childJson = JsonDocument.Parse(fixture.Lines(childTarget)[0]);
        Assert.Equal(parentTarget.LongLength, childJson.RootElement.GetProperty("payload").GetProperty("history_base").GetProperty("end_byte_offset").GetInt64());
        Assert.Equal(childTarget.LongLength, fixture.Number($"SELECT next_rollout_byte_offset FROM thread_history_projection_state WHERE thread_id='{child}'"));
        Assert.Equal(parentTarget.LongLength, fixture.Number($"SELECT next_rollout_byte_offset FROM thread_history_projection_state WHERE thread_id='{parent}'"));
        Assert.Equal("openai", fixture.Scalar(fixture.StateDb, $"SELECT model_provider FROM threads WHERE id='{logical}'"));
        Assert.Equal(ui, fixture.UiSnapshot());
        Assert.False((await fixture.Service.PrepareAsync(false, null, CancellationToken.None)).Changed);
    }

    [Theory]
    [InlineData("cycle")]
    [InlineData("duplicate")]
    [InlineData("unknown-offset")]
    [InlineData("ancestry")]
    public async Task Ambiguous_segments_or_unadapted_offsets_stop_before_writing(string problem)
    {
        using var fixture = new Fixture();
        const string logical = "11111111-1111-4111-8111-111111111111";
        const string segment = "22222222-2222-4222-8222-222222222222";
        fixture.UseSegment(logical, segment);
        if (problem == "cycle")
        {
            var lines = fixture.Lines(fixture.Original); var json = JsonNode.Parse(lines[0])!;
            json["payload"]!["history_base"] = new JsonObject { ["thread_id"] = segment, ["end_byte_offset"] = 0, ["end_ordinal_exclusive"] = 0 };
            lines[0] = json.ToJsonString(); fixture.WriteJournal(lines.ToArray());
        }
        else if (problem == "ancestry")
        {
            var lines = fixture.Lines(fixture.Original); var json = JsonNode.Parse(lines[0])!;
            json["payload"]!["forked_from_id"] = "unverified-source"; lines[0] = json.ToJsonString(); fixture.WriteJournal(lines.ToArray());
        }
        else if (problem == "duplicate") fixture.Files.WriteAtomic(Path.Combine(fixture.Paths.CodexHome, "archived_sessions", Path.GetFileName(fixture.Journal)), fixture.Original);
        else fixture.Execute(fixture.ProjectionDb, "ALTER TABLE thread_turns ADD COLUMN future_byte_offset INTEGER DEFAULT 1");
        var original = fixture.DatabaseSnapshot();
        await Assert.ThrowsAsync<InvalidDataException>(() => fixture.Service.PrepareAsync(true, null, CancellationToken.None));
        Assert.Equal(fixture.Original, File.ReadAllBytes(fixture.Journal)); Assert.Equal(original, fixture.DatabaseSnapshot());
        Assert.False(Directory.Exists(fixture.Paths.HistoryBackupsDirectory));
    }

    [Fact]
    public async Task Unknown_offset_columns_are_rejected_even_if_opposite_length_changes_cancel_at_eof()
    {
        using var fixture = new Fixture();
        var lines = fixture.Lines(fixture.Original);
        lines.Add("{\"ordinal\":8,\"type\":\"event_msg\",\"payload\":{\"type\":\"thread_settings_applied\",\"thread_id\":\"synthetic-thread\",\"thread_settings\":{\"model_provider_id\":\"longrelay\"}}}");
        fixture.WriteJournal(lines.ToArray());
        fixture.Execute(fixture.ProjectionDb, "UPDATE thread_history_projection_state SET next_rollout_byte_offset=$length,next_rollout_ordinal=9 WHERE thread_id='synthetic-thread'; ALTER TABLE thread_turns ADD COLUMN future_byte_offset INTEGER DEFAULT 1", ("$length", fixture.Original.LongLength));
        // api -> openai adds three bytes and longrelay -> openai removes three; intermediate offsets still move.
        var original = fixture.DatabaseSnapshot();
        var error = await Assert.ThrowsAsync<InvalidDataException>(() => fixture.Service.PrepareAsync(true, null, CancellationToken.None));
        Assert.Contains("未知字节偏移列", error.Message); Assert.Equal(fixture.Original, File.ReadAllBytes(fixture.Journal)); Assert.Equal(original, fixture.DatabaseSnapshot());
    }

    [Fact]
    public async Task Older_turn_tables_without_optional_byte_boundaries_preserve_ui_rows()
    {
        using var fixture = new Fixture(); var ui = fixture.UiSnapshot();
        fixture.Execute(fixture.ProjectionDb, "ALTER TABLE thread_turns DROP COLUMN rollout_byte_offset; ALTER TABLE thread_turns DROP COLUMN rollout_end_byte_offset; ALTER TABLE thread_turns DROP COLUMN rollout_end_ordinal");
        Assert.True((await fixture.Service.PrepareAsync(false, null, CancellationToken.None)).Prepared);
        Assert.Equal(ui, fixture.UiSnapshot()); Assert.Equal(File.ReadAllBytes(fixture.Journal).LongLength, fixture.Number("SELECT next_rollout_byte_offset FROM thread_history_projection_state WHERE thread_id='synthetic-thread'"));
    }

    [Fact]
    public async Task Legacy_jsonl_retains_bom_blank_lines_mixed_endings_and_multibyte_fields_before_the_owned_token()
    {
        using var fixture = new Fixture();
        fixture.Execute(fixture.ProjectionDb, "DELETE FROM thread_items; DELETE FROM thread_turns; DELETE FROM thread_history_projection_state");
        const string text = "\r\n  \t\n{\"中文😀\":null,\"type\":\"session_meta\",\"payload\":{\"id\":\"synthetic-thread\",\"model_provider\":\"api\",\"unknown\":[\"2026-11-13\"]}}\r\n \t";
        fixture.Files.WriteAtomic(fixture.Journal, [.. Encoding.UTF8.Preamble, .. Encoding.UTF8.GetBytes(text)]);
        Assert.True((await fixture.Service.PrepareAsync(true, null, CancellationToken.None)).Changed);
        var expected = Encoding.UTF8.GetBytes(text.Replace("\"model_provider\":\"api\"", "\"model_provider\":\"openai\"", StringComparison.Ordinal));
        Assert.Equal([.. Encoding.UTF8.Preamble, .. expected], File.ReadAllBytes(fixture.Journal));
    }

    [Theory]
    [InlineData("after-json")]
    [InlineData("after-db-commit")]
    [InlineData("after-ready")]
    [InlineData("cancel")]
    public async Task Failure_or_cancellation_restores_json_and_all_related_databases(string boundary)
    {
        using var fixture = new Fixture();
        var original = fixture.DatabaseSnapshot(); using var cancellation = new CancellationTokenSource();
        var intercept = new InterceptFiles(fixture.Files, (path, after) =>
        {
            if (boundary == "after-json" && path == fixture.Journal && after) throw new IOException("synthetic boundary failure");
            if (boundary == "after-db-commit" && path == fixture.Paths.HistoryReadyFile && !after) throw new IOException("synthetic committed failure");
            if (boundary == "after-ready" && path == fixture.Paths.HistoryReadyFile && after) throw new IOException("synthetic ready failure");
            if (boundary == "cancel" && path == fixture.Journal && after) cancellation.Cancel();
        });
        var service = new HistoryCompatibilityService(intercept, fixture.Paths);
        if (boundary == "cancel") await Assert.ThrowsAnyAsync<OperationCanceledException>(() => service.PrepareAsync(false, null, cancellation.Token));
        else await Assert.ThrowsAsync<InvalidOperationException>(() => service.PrepareAsync(false, null, CancellationToken.None));
        Assert.Equal(fixture.Original, File.ReadAllBytes(fixture.Journal)); Assert.Equal(original, fixture.DatabaseSnapshot());
        Assert.False(service.HasPendingRecovery);
        Assert.Equal("rolled_back", JsonNode.Parse(File.ReadAllText(fixture.Manifest()))!["status"]!.GetValue<string>());
        if (boundary == "after-ready") Assert.True((await fixture.Service.PrepareAsync(false, null, CancellationToken.None)).Changed);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task Restart_recovers_real_version3_plans_after_partial_or_complete_database_commits(bool partial)
    {
        using var fixture = new Fixture(); var original = fixture.DatabaseSnapshot();
        await fixture.Service.PrepareAsync(false, null, CancellationToken.None);
        var target = File.ReadAllBytes(fixture.Journal); var applied = fixture.DatabaseSnapshot();
        var manifestPath = fixture.Manifest(); var manifest = JsonNode.Parse(File.ReadAllText(manifestPath))!;
        Assert.Equal(3, manifest["version"]!.GetValue<int>());
        if (partial)
        {
            var database = manifest["databases"]![0]!;
            fixture.RestoreDatabase(database["source"]!.GetValue<string>(), database["backup"]!.GetValue<string>());
        }
        manifest["status"] = "prepared"; File.WriteAllText(manifestPath, manifest.ToJsonString());
        var restarted = new HistoryCompatibilityService(fixture.Files, fixture.Paths);
        await restarted.RecoverPendingOperationsAsync();
        Assert.Equal(partial ? fixture.Original : target, File.ReadAllBytes(fixture.Journal));
        Assert.Equal(partial ? original : applied, fixture.DatabaseSnapshot()); Assert.False(restarted.HasPendingRecovery);
        Assert.Equal(partial ? "rolled_back" : "complete", JsonNode.Parse(File.ReadAllText(manifestPath))!["status"]!.GetValue<string>());
    }

    [Theory]
    [InlineData("json")]
    [InlineData("ui")]
    public async Task Recovery_preflights_every_source_before_reverting_any_database(string changed)
    {
        using var fixture = new Fixture(); await fixture.Service.PrepareAsync(false, null, CancellationToken.None);
        var manifestPath = fixture.Manifest(); var manifest = JsonNode.Parse(File.ReadAllText(manifestPath))!;
        manifest["status"] = "prepared"; File.WriteAllText(manifestPath, manifest.ToJsonString());
        if (changed == "json") File.AppendAllText(fixture.Journal, "\n{\"external\":true}\n");
        else fixture.Execute(fixture.ProjectionDb, "UPDATE thread_items SET unknown_date='external-edit' WHERE item_id='visible-agent'");
        var external = File.ReadAllBytes(fixture.Journal); var databases = fixture.DatabaseSnapshot();
        await Assert.ThrowsAsync<IOException>(() => fixture.Service.RecoverPendingOperationsAsync());
        Assert.Equal(external, File.ReadAllBytes(fixture.Journal)); Assert.Equal(databases, fixture.DatabaseSnapshot());
        Assert.True(fixture.Service.HasPendingRecovery);
    }

    [Fact]
    public async Task A_previously_empty_projection_is_guarded_against_external_insertion_before_the_first_write()
    {
        using var fixture = new Fixture();
        fixture.Execute(fixture.ProjectionDb, "DELETE FROM thread_items WHERE thread_id='synthetic-thread'; UPDATE thread_turns SET first_user_item_id=NULL,final_agent_item_id=NULL WHERE thread_id='synthetic-thread'");
        string? external = null;
        var intercept = new InterceptFiles(fixture.Files, (path, after) =>
        {
            if (!after || Path.GetFileName(path) != "manifest.json" || external is not null) return;
            fixture.Execute(fixture.ProjectionDb, "INSERT INTO thread_items(thread_id,turn_id,item_id,rollout_ordinal,created_at_ms,item_json,item_type,updated_at_ordinal) VALUES('synthetic-thread','external','external',0,0,'{}','future',0)");
            external = fixture.DatabaseSnapshot();
        });
        var service = new HistoryCompatibilityService(intercept, fixture.Paths);
        await Assert.ThrowsAsync<IOException>(() => service.PrepareAsync(false, null, CancellationToken.None));
        Assert.NotNull(external); Assert.Equal(external, fixture.DatabaseSnapshot()); Assert.Equal(fixture.Original, File.ReadAllBytes(fixture.Journal));
        Assert.True(service.HasPendingRecovery);
    }

    [Fact]
    public async Task Wal_only_commits_invalidate_the_ready_stamp_even_when_the_main_database_is_unchanged()
    {
        using var fixture = new Fixture(); using var held = fixture.Open(fixture.StateDb);
        fixture.Execute(held, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0");
        await fixture.Service.PrepareAsync(false, null, CancellationToken.None);
        var main = ReadShared(fixture.StateDb);
        fixture.Execute(held, "UPDATE threads SET model_provider='new_provider' WHERE id='synthetic-thread'");
        Assert.Equal(main, ReadShared(fixture.StateDb));
        var result = await fixture.Service.PrepareAsync(false, null, CancellationToken.None);
        Assert.True(result.Changed); Assert.Equal("openai", fixture.Scalar(fixture.StateDb, "SELECT model_provider FROM threads WHERE id='synthetic-thread'"));
    }

    [Fact]
    public async Task Sqlite_trigger_failure_rolls_back_both_provider_and_pagination_without_losing_ui_items()
    {
        using var fixture = new Fixture(); var original = fixture.DatabaseSnapshot();
        fixture.Execute(fixture.ProjectionDb, "CREATE TRIGGER fail_cursor BEFORE UPDATE ON thread_history_projection_state BEGIN SELECT RAISE(ABORT,'synthetic cursor failure'); END");
        await Assert.ThrowsAsync<InvalidOperationException>(() => fixture.Service.PrepareAsync(false, null, CancellationToken.None));
        Assert.Equal(fixture.Original, File.ReadAllBytes(fixture.Journal)); Assert.Equal(original, fixture.DatabaseSnapshot()); Assert.False(fixture.Service.HasPendingRecovery);
    }

    [Fact]
    public async Task Committed_wal_values_are_backed_up_and_restored_across_both_databases()
    {
        using var fixture = new Fixture(); using var state = fixture.Open(fixture.StateDb); using var projection = fixture.Open(fixture.ProjectionDb);
        fixture.Execute(state, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; UPDATE threads SET unknown_value=2.75 WHERE id='synthetic-thread'");
        fixture.Execute(projection, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; UPDATE thread_items SET unknown_date='WAL-only' WHERE item_id='visible-agent'");
        var original = fixture.DatabaseSnapshot();
        var intercept = new InterceptFiles(fixture.Files, (path, after) => { if (path == fixture.Paths.HistoryReadyFile && !after) throw new IOException("synthetic failure after all commits"); });
        await Assert.ThrowsAsync<InvalidOperationException>(() => new HistoryCompatibilityService(intercept, fixture.Paths).PrepareAsync(false, null, CancellationToken.None));
        Assert.Equal(original, fixture.DatabaseSnapshot()); Assert.Equal(fixture.Original, File.ReadAllBytes(fixture.Journal));
        var manifest = JsonNode.Parse(File.ReadAllText(fixture.Manifest()))!;
        var stateBackup = manifest["databases"]!.AsArray().Single(database => database!["source"]!.GetValue<string>() == fixture.StateDb)!["backup"]!.GetValue<string>();
        var projectionBackup = manifest["databases"]!.AsArray().Single(database => database!["source"]!.GetValue<string>() == fixture.ProjectionDb)!["backup"]!.GetValue<string>();
        Assert.Equal(2.75, fixture.Scalar(stateBackup, "SELECT unknown_value FROM threads WHERE id='synthetic-thread'"));
        Assert.Equal("WAL-only", fixture.Scalar(projectionBackup, "SELECT unknown_date FROM thread_items WHERE item_id='visible-agent'"));
    }

    internal sealed class Fixture : IDisposable
    {
        public string Root { get; } = Path.Combine(Path.GetTempPath(), "paged-history-中文-" + Guid.NewGuid().ToString("N"));
        public SwitcherPaths Paths { get; }
        public PhysicalSwitcherFileSystem Files { get; } = new();
        public HistoryCompatibilityService Service => new(Files, Paths);
        public string Journal { get; private set; }
        public string StateDb => Paths.ProjectStateDatabase;
        public string ProjectionDb { get; }
        public byte[] Original { get; private set; } = [];
        private readonly bool _bom; private readonly string _newline; private readonly bool _finalNewline;
        public Fixture(bool bom = false, string newline = "\n", bool finalNewline = true, bool combined = false)
        {
            Paths = new(Path.Combine(Root, "home"), Path.Combine(Root, "data")); Directory.CreateDirectory(Paths.CodexHome);
            _bom = bom; _newline = newline; _finalNewline = finalNewline;
            Journal = Path.Combine(Paths.CodexHome, "sessions", "synthetic.jsonl");
            ProjectionDb = combined ? StateDb : Path.Combine(Paths.CodexHome, "thread_history_1.sqlite");
            Execute(StateDb, "CREATE TABLE threads(id TEXT PRIMARY KEY,model_provider TEXT NOT NULL,unknown_blob BLOB,unknown_value REAL); INSERT INTO threads VALUES('synthetic-thread','api',X'00ff',1.5),('unrelated','relay',NULL,0.0)");
            Execute(ProjectionDb, """
                CREATE TABLE thread_history_projection_state(thread_id TEXT PRIMARY KEY,next_rollout_byte_offset INTEGER NOT NULL,next_rollout_ordinal INTEGER NOT NULL);
                CREATE TABLE thread_items(thread_id TEXT NOT NULL,turn_id TEXT NOT NULL,item_id TEXT NOT NULL,rollout_ordinal INTEGER NOT NULL,created_at_ms INTEGER NOT NULL,item_json TEXT NOT NULL,item_type TEXT NOT NULL,updated_at_ordinal INTEGER NOT NULL,started_at_ms INTEGER,completed_at_ms INTEGER,unknown_date TEXT,unknown_blob BLOB,PRIMARY KEY(thread_id,turn_id,item_id));
                CREATE TABLE thread_turns(thread_id TEXT NOT NULL,turn_id TEXT NOT NULL,rollout_ordinal INTEGER NOT NULL,status TEXT NOT NULL,error_json TEXT,started_at INTEGER,completed_at INTEGER,duration_ms INTEGER,first_user_item_id TEXT,final_agent_item_id TEXT,rollout_byte_offset INTEGER,rollout_end_ordinal INTEGER,rollout_end_byte_offset INTEGER,root_turn_id TEXT,unknown_date TEXT,PRIMARY KEY(thread_id,turn_id));
                """);
            WriteJournal([
                "{\"ordinal\":0,\"unknown\":\"中文😀在 provider 前\",\"date_string\":\"2026-11-13T10:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"id\":\"synthetic-thread\",\"history_mode\":\"paginated\",\"model_provider\":\"api\"}}",
                "{\"ordinal\":1,\"type\":\"event_msg\",\"payload\":{\"type\":\"task_started\",\"thread_id\":\"synthetic-thread\",\"turn_id\":\"turn-1\"}}",
                Event(2, "visible-user", "UserMessage"),
                "{\"ordinal\":3,\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"id\":\"model-replay-id\",\"call_id\":\"same-call\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"模型输入文字😀\"}]}}",
                Event(4, "visible-agent", "AgentMessage"),
                "{\"ordinal\":5,\"type\":\"event_msg\",\"payload\":{\"type\":\"task_complete\",\"thread_id\":\"synthetic-thread\"}}",
                "{\"ordinal\":6,\"type\":\"compacted\",\"payload\":{\"replacement_history\":[{\"id\":\"model-reason-id\",\"type\":\"reasoning\",\"encrypted_content\":\"encrypted-unchanged\"}]}}",
                "{\"ordinal\":7,\"type\":\"unknown_future_record\",\"unknown\":{\"empty\":[],\"one\":[null],\"text\":\"原样保留\"}}"
            ]);
            Execute(ProjectionDb, "INSERT INTO thread_history_projection_state VALUES('synthetic-thread',$length,8),('unrelated',123,9)", ("$length", Original.LongLength));
            foreach (var (id, type, ordinal) in new[] { ("visible-user", "userMessage", 2), ("visible-agent", "agentMessage", 4) })
                Execute(ProjectionDb, "INSERT INTO thread_items VALUES('synthetic-thread','turn-1',$id,$ordinal,1000,$json,$type,$ordinal,NULL,1001,'2026-11-13',X'00ff')", ("$id", id), ("$ordinal", ordinal), ("$json", JsonSerializer.Serialize(new { id, type, content = new[] { "界面文字😀" }, unknown = (object?)null })), ("$type", type));
            Execute(ProjectionDb, "INSERT INTO thread_turns VALUES('synthetic-thread','turn-1',1,'completed',NULL,100,200,100,'visible-user','visible-agent',$start,5,$end,NULL,'2030-01-02')", ("$start", Offset(Original, 1)), ("$end", Offset(Original, 6)));
        }
        public void WriteJournal(string[] lines)
        {
            var text = string.Join(_newline, lines) + (_finalNewline ? _newline : "");
            Original = [.. (_bom ? Encoding.UTF8.Preamble : ReadOnlySpan<byte>.Empty), .. Encoding.UTF8.GetBytes(text)]; Files.WriteAtomic(Journal, Original);
        }
        public void UseSegment(string logical, string segment)
        {
            var oldPath = Journal;
            Journal = Path.Combine(Path.GetDirectoryName(oldPath)!, $"rollout-2026-11-13T10-00-00-{logical}_{segment}.jsonl");
            WriteJournal(Lines(Original).Select(line => line.Replace("synthetic-thread", logical, StringComparison.Ordinal)).ToArray());
            File.Delete(oldPath);
            Execute(StateDb, "UPDATE threads SET id=$id WHERE id='synthetic-thread'", ("$id", logical));
            foreach (var table in new[] { "thread_items", "thread_turns", "thread_history_projection_state" }) Execute(ProjectionDb, $"UPDATE {table} SET thread_id=$id WHERE thread_id='synthetic-thread'", ("$id", segment));
            Execute(ProjectionDb, "UPDATE thread_history_projection_state SET next_rollout_byte_offset=$length WHERE thread_id=$id", ("$length", Original.LongLength), ("$id", segment));
            Execute(ProjectionDb, "UPDATE thread_turns SET rollout_byte_offset=$start,rollout_end_byte_offset=$end WHERE thread_id=$id", ("$start", Offset(Original, 1)), ("$end", Offset(Original, 6)), ("$id", segment));
        }
        public List<string> Lines(byte[] bytes) => Encoding.UTF8.GetString(bytes).TrimStart('\uFEFF').Split('\n').Select(line => line.TrimEnd('\r')).Where(line => line.Length > 0).ToList();
        public long Offset(byte[] bytes, int line)
        {
            var offset = 0;
            for (var index = 0; index < line; index++) { var next = Array.IndexOf(bytes, (byte)'\n', offset); if (next < 0) return bytes.Length; offset = next + 1; }
            return offset;
        }
        private static string Event(int ordinal, string id, string type) => JsonSerializer.Serialize(new { ordinal, type = "event_msg", payload = new { type = "item_completed", thread_id = "synthetic-thread", turn_id = "turn-1", item = new { id, type, content = new[] { "界面文字😀" } } } }, new JsonSerializerOptions { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
        public SqliteConnection Open(string path)
        {
            var connection = new SqliteConnection(new SqliteConnectionStringBuilder { DataSource = path, Pooling = false }.ConnectionString); connection.Open(); return connection;
        }
        public void Execute(string database, string sql, params (string, object)[] values) { using var connection = Open(database); Execute(connection, sql, values); }
        public void Execute(SqliteConnection connection, string sql, params (string, object)[] values)
        {
            using var command = connection.CreateCommand(); command.CommandText = sql;
            foreach (var (key, value) in values) command.Parameters.AddWithValue(key, value); command.ExecuteNonQuery();
        }
        public object? Scalar(string database, string sql) { using var connection = Open(database); using var command = connection.CreateCommand(); command.CommandText = sql; var value = command.ExecuteScalar(); return value is DBNull ? null : value; }
        public long Number(string sql) => Convert.ToInt64(Scalar(ProjectionDb, sql));
        public string UiSnapshot() => Dump(ProjectionDb, "SELECT thread_id,turn_id,item_id,rollout_ordinal,created_at_ms,item_json,item_type,updated_at_ordinal,started_at_ms,completed_at_ms,unknown_date,hex(unknown_blob) FROM thread_items ORDER BY thread_id,item_id");
        public string DatabaseSnapshot() => Dump(StateDb, "SELECT id,model_provider,hex(unknown_blob),unknown_value FROM threads ORDER BY id") + UiSnapshot() + Dump(ProjectionDb, "SELECT * FROM thread_turns ORDER BY thread_id") + Dump(ProjectionDb, "SELECT * FROM thread_history_projection_state ORDER BY thread_id");
        private string Dump(string path, string sql)
        {
            using var connection = Open(path); using var command = connection.CreateCommand(); command.CommandText = sql; using var reader = command.ExecuteReader(); var rows = new List<object?[]>();
            while (reader.Read()) { var values = new object[reader.FieldCount]; reader.GetValues(values); rows.Add(values.Select(value => value is DBNull ? null : value).ToArray()); }
            return JsonSerializer.Serialize(rows);
        }
        public string Manifest() => Directory.GetFiles(Paths.HistoryBackupsDirectory, "manifest.json", SearchOption.AllDirectories).Single();
        public void RestoreDatabase(string database, string backup) { using var source = Open(backup); using var destination = Open(database); source.BackupDatabase(destination); }
        public void Dispose() { SqliteConnection.ClearAllPools(); Directory.Delete(Root, true); }
    }

    private static byte[] ReadShared(string path)
    {
        using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var output = new MemoryStream(); input.CopyTo(output); return output.ToArray();
    }

    private sealed class InterceptFiles(ISwitcherFileSystem inner, Action<string, bool> action) : ISwitcherFileSystem
    {
        private bool _invoked;
        private void Invoke(string path, bool after) { if (_invoked) return; try { action(path, after); } catch { _invoked = true; throw; } }
        public bool FileExists(string path) => inner.FileExists(path);
        public bool DirectoryExists(string path) => inner.DirectoryExists(path);
        public byte[] ReadAllBytes(string path) => inner.ReadAllBytes(path);
        public string ReadAllText(string path) => inner.ReadAllText(path);
        public DateTimeOffset GetLastWriteTimeUtc(string path) => inner.GetLastWriteTimeUtc(path);
        public void WriteAtomic(string path, ReadOnlySpan<byte> contents) { Invoke(path, false); inner.WriteAtomic(path, contents); Invoke(path, true); }
        public bool TryCreateAtomic(string path, ReadOnlySpan<byte> contents) => inner.TryCreateAtomic(path, contents);
        public void DeleteFile(string path) => inner.DeleteFile(path);
        public void CreateDirectory(string path) => inner.CreateDirectory(path);
        public IEnumerable<string> EnumerateFiles(string path, string pattern, SearchOption option) => inner.EnumerateFiles(path, pattern, option);
    }
}
