using System.Text.Json.Nodes;
using Switcher.Infrastructure.History;

namespace Switcher.Infrastructure.Tests;

public sealed class InheritedHistoryBehaviorTests
{
    [Theory]
    [InlineData(false, "\n", true, false)]
    [InlineData(true, "\r\n", false, false)]
    [InlineData(false, "\r\n", true, true)]
    public async Task Subagent_parent_metadata_is_replay_context_and_only_the_child_projection_is_updated(bool bom, string newline, bool finalNewline, bool combined)
    {
        using var fixture = new PaginatedHistoryBehaviorTests.Fixture(bom, newline, finalNewline, combined);
        UseInheritedPrefix(fixture);
        var ui = fixture.UiSnapshot(); var original = fixture.Lines(fixture.Original);

        var result = await fixture.Service.PrepareAsync(false, null, CancellationToken.None);

        Assert.True(result.Prepared); Assert.True(result.Changed);
        var targetBytes = File.ReadAllBytes(fixture.Journal); var target = fixture.Lines(targetBytes);
        Assert.Equal(fixture.Original.AsSpan().StartsWith(System.Text.Encoding.UTF8.Preamble), targetBytes.AsSpan().StartsWith(System.Text.Encoding.UTF8.Preamble));
        Assert.Equal(finalNewline, targetBytes[^1] == '\n');
        Assert.Equal(original.Count, target.Count); Assert.Equal(ui, fixture.UiSnapshot());
        for (var index = 0; index < target.Count; index++)
        {
            var expected = JsonNode.Parse(original[index])!;
            if (index is 0 or 1) expected["payload"]!["model_provider"] = "openai";
            if (index == 4) expected["payload"]!["id"] = null;
            if (index == 7) expected["payload"]!["replacement_history"]![0]!["id"] = null;
            Assert.True(JsonNode.DeepEquals(expected, JsonNode.Parse(target[index])), $"Unexpected change in record {index}");
            if (index is not (0 or 1 or 4 or 7)) Assert.Equal(original[index], target[index]);
        }
        Assert.Equal(targetBytes.LongLength, fixture.Number("SELECT next_rollout_byte_offset FROM thread_history_projection_state WHERE thread_id='synthetic-thread'"));
        Assert.Equal(9, fixture.Number("SELECT next_rollout_ordinal FROM thread_history_projection_state WHERE thread_id='synthetic-thread'"));
        Assert.Equal(fixture.Offset(targetBytes, 2), fixture.Number("SELECT rollout_byte_offset FROM thread_turns WHERE thread_id='synthetic-thread'"));
        Assert.Equal(fixture.Offset(targetBytes, 7), fixture.Number("SELECT rollout_end_byte_offset FROM thread_turns WHERE thread_id='synthetic-thread'"));
        Assert.Equal("openai", fixture.Scalar(fixture.StateDb, "SELECT model_provider FROM threads WHERE id='synthetic-thread'"));
        Assert.Equal("relay", fixture.Scalar(fixture.StateDb, "SELECT model_provider FROM threads WHERE id='synthetic-parent'"));
        Assert.Equal(751581, fixture.Number("SELECT next_rollout_byte_offset FROM thread_history_projection_state WHERE thread_id='synthetic-parent'"));
        Assert.False((await fixture.Service.PrepareAsync(false, null, CancellationToken.None)).Changed);
        Assert.False((await fixture.Service.PrepareAsync(true, null, CancellationToken.None)).Changed);
        Assert.Single(Directory.GetDirectories(fixture.Paths.HistoryBackupsDirectory));
    }

    [Theory]
    [InlineData("missing-parent")]
    [InlineData("wrong-fork")]
    [InlineData("wrong-source-parent")]
    [InlineData("wrong-session")]
    [InlineData("not-subagent")]
    [InlineData("not-paginated")]
    [InlineData("missing-boundary")]
    [InlineData("boundary-too-early")]
    [InlineData("boundary-beyond-eof")]
    [InlineData("fractional-boundary")]
    [InlineData("foreign-metadata-after-boundary")]
    [InlineData("foreign-event-after-boundary")]
    [InlineData("unrelated-prefix-event")]
    [InlineData("ordinal-gap")]
    [InlineData("own-history-base")]
    [InlineData("third-identity")]
    public async Task Unverified_inheritance_stops_before_any_history_write(string problem)
    {
        using var fixture = new PaginatedHistoryBehaviorTests.Fixture(); UseInheritedPrefix(fixture);
        var records = fixture.Lines(fixture.Original).Select(line => JsonNode.Parse(line)!).ToArray();
        var meta = records[0]["payload"]!;
        switch (problem)
        {
            case "missing-parent": meta.AsObject().Remove("parent_thread_id"); break;
            case "wrong-fork": meta["forked_from_id"] = "unrelated"; break;
            case "wrong-source-parent": meta["source"]!["subagent"]!["thread_spawn"]!["parent_thread_id"] = "unrelated"; break;
            case "wrong-session": records[1]["payload"]!["session_id"] = "unrelated"; break;
            case "not-subagent": meta["thread_source"] = "user"; break;
            case "not-paginated": meta["history_mode"] = "complete"; break;
            case "missing-boundary": meta.AsObject().Remove("subagent_history_start_ordinal"); break;
            case "boundary-too-early": meta["subagent_history_start_ordinal"] = 1; break;
            case "boundary-beyond-eof": meta["subagent_history_start_ordinal"] = 1000; break;
            case "fractional-boundary": meta["subagent_history_start_ordinal"] = 3.5; break;
            case "foreign-metadata-after-boundary": records[8] = records[1].DeepClone(); records[8]["ordinal"] = 8; break;
            case "foreign-event-after-boundary": records[3]["payload"]!["thread_id"] = "synthetic-parent"; break;
            case "unrelated-prefix-event": records[2]["payload"]!["thread_id"] = "unrelated"; break;
            case "ordinal-gap": records[2]["ordinal"] = 99; break;
            case "own-history-base": meta["history_base"] = new JsonObject { ["thread_id"] = "another-segment", ["end_byte_offset"] = 20, ["end_ordinal_exclusive"] = 1 }; break;
            case "third-identity": records[1]["payload"]!["id"] = "unrelated"; break;
        }
        fixture.WriteJournal(records.Select(record => record.ToJsonString()).ToArray());
        var database = fixture.DatabaseSnapshot();
        await Assert.ThrowsAsync<InvalidDataException>(() => fixture.Service.PrepareAsync(true, null, CancellationToken.None));
        Assert.Equal(fixture.Original, File.ReadAllBytes(fixture.Journal)); Assert.Equal(database, fixture.DatabaseSnapshot());
        Assert.False(Directory.Exists(fixture.Paths.HistoryBackupsDirectory)); Assert.False(File.Exists(fixture.Paths.HistoryReadyFile));
    }

    [Fact]
    public async Task Copied_parent_events_cannot_prove_child_ui_item_sources()
    {
        using var fixture = new PaginatedHistoryBehaviorTests.Fixture(); UseInheritedPrefix(fixture);
        var records = fixture.Lines(fixture.Original).Select(line => JsonNode.Parse(line)!).ToArray();
        records[2] = records[3].DeepClone(); records[2]["ordinal"] = 2;
        fixture.WriteJournal(records.Select(record => record.ToJsonString()).ToArray());
        fixture.Execute(fixture.ProjectionDb, "UPDATE thread_items SET rollout_ordinal=2,updated_at_ordinal=2 WHERE item_id='visible-user'");
        var database = fixture.DatabaseSnapshot();
        await Assert.ThrowsAsync<InvalidDataException>(() => fixture.Service.PrepareAsync(true, null, CancellationToken.None));
        Assert.Equal(fixture.Original, File.ReadAllBytes(fixture.Journal)); Assert.Equal(database, fixture.DatabaseSnapshot());
    }

    [Fact]
    public async Task Legacy_conflicting_metadata_still_stops_before_writing()
    {
        using var fixture = new PaginatedHistoryBehaviorTests.Fixture();
        fixture.WriteJournal([
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"synthetic-thread\",\"model_provider\":\"api\"}}",
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"unrelated\",\"model_provider\":\"relay\"}}"
        ]);
        var database = fixture.DatabaseSnapshot();
        await Assert.ThrowsAsync<InvalidDataException>(() => fixture.Service.PrepareAsync(true, null, CancellationToken.None));
        Assert.Equal(fixture.Original, File.ReadAllBytes(fixture.Journal)); Assert.Equal(database, fixture.DatabaseSnapshot());
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task Known_rollout_names_keep_the_first_identity_and_separate_physical_projection(bool segment)
    {
        using var fixture = new PaginatedHistoryBehaviorTests.Fixture(); UseInheritedPrefix(fixture);
        const string logical = "11111111-1111-4111-8111-111111111111";
        const string physical = "22222222-2222-4222-8222-222222222222";
        fixture.UseSegment(logical, segment ? physical : logical);
        if (!segment)
        {
            var path = fixture.Journal.Replace($"_{logical}.jsonl", ".jsonl", StringComparison.Ordinal);
            File.Move(fixture.Journal, path);
        }
        // UseSegment adjusts the original eight-record cursor; this inherited fixture has nine.
        fixture.Execute(fixture.ProjectionDb, "UPDATE thread_history_projection_state SET next_rollout_ordinal=9 WHERE thread_id=$id", ("$id", segment ? physical : logical));
        var result = await fixture.Service.PrepareAsync(true, null, CancellationToken.None);
        Assert.True(result.Changed);
        Assert.Equal(9, fixture.Number($"SELECT next_rollout_ordinal FROM thread_history_projection_state WHERE thread_id='{(segment ? physical : logical)}'"));
        Assert.Equal(751581, fixture.Number("SELECT next_rollout_byte_offset FROM thread_history_projection_state WHERE thread_id='synthetic-parent'"));
    }

    [Fact]
    public async Task Mismatched_known_rollout_name_still_stops_before_writing()
    {
        using var fixture = new PaginatedHistoryBehaviorTests.Fixture(); UseInheritedPrefix(fixture);
        var path = Path.Combine(Path.GetDirectoryName(fixture.Journal)!, "rollout-2026-11-13T10-00-00-11111111-1111-4111-8111-111111111111.jsonl");
        File.Move(fixture.Journal, path);
        var database = fixture.DatabaseSnapshot();
        await Assert.ThrowsAsync<InvalidDataException>(() => fixture.Service.PrepareAsync(true, null, CancellationToken.None));
        Assert.Equal(fixture.Original, File.ReadAllBytes(path)); Assert.Equal(database, fixture.DatabaseSnapshot());
    }

    [Fact]
    public async Task A_separate_local_parent_file_has_its_own_provider_and_projection_plan()
    {
        using var fixture = new PaginatedHistoryBehaviorTests.Fixture(); UseInheritedPrefix(fixture);
        var path = Path.Combine(fixture.Paths.CodexHome, "archived_sessions", "parent.jsonl");
        var parent = System.Text.Encoding.UTF8.GetBytes("{\"ordinal\":0,\"type\":\"session_meta\",\"payload\":{\"id\":\"synthetic-parent\",\"history_mode\":\"paginated\",\"model_provider\":\"relay\"}}\n");
        fixture.Files.WriteAtomic(path, parent);
        fixture.Execute(fixture.ProjectionDb, "UPDATE thread_history_projection_state SET next_rollout_byte_offset=$length,next_rollout_ordinal=1 WHERE thread_id='synthetic-parent'", ("$length", parent.LongLength));
        var ui = fixture.UiSnapshot();
        Assert.True((await fixture.Service.PrepareAsync(true, null, CancellationToken.None)).Changed);
        Assert.Equal("openai", fixture.Scalar(fixture.StateDb, "SELECT model_provider FROM threads WHERE id='synthetic-parent'"));
        Assert.Equal(File.ReadAllBytes(path).LongLength, fixture.Number("SELECT next_rollout_byte_offset FROM thread_history_projection_state WHERE thread_id='synthetic-parent'"));
        Assert.Equal(File.ReadAllBytes(fixture.Journal).LongLength, fixture.Number("SELECT next_rollout_byte_offset FROM thread_history_projection_state WHERE thread_id='synthetic-thread'"));
        Assert.Equal(ui, fixture.UiSnapshot());
        var copiedParent = JsonNode.Parse(fixture.Lines(File.ReadAllBytes(fixture.Journal))[1])!;
        Assert.Equal(751581, copiedParent["payload"]!["history_base"]!["end_byte_offset"]!.GetValue<int>());
    }

    [Fact]
    public async Task Older_ready_cache_is_rescanned_without_changing_recovery_manifest_version()
    {
        using var fixture = new PaginatedHistoryBehaviorTests.Fixture(); UseInheritedPrefix(fixture);
        await fixture.Service.PrepareAsync(false, null, CancellationToken.None);
        var ready = JsonNode.Parse(File.ReadAllText(fixture.Paths.HistoryReadyFile))!;
        Assert.Equal(4, ready["Version"]!.GetValue<int>());
        ready["Version"] = 3;
        fixture.Files.WriteAtomic(fixture.Paths.HistoryReadyFile, System.Text.Encoding.UTF8.GetBytes(ready.ToJsonString()));
        var result = await fixture.Service.PrepareAsync(false, null, CancellationToken.None);
        Assert.False(result.Changed);
        Assert.Equal(4, JsonNode.Parse(File.ReadAllText(fixture.Paths.HistoryReadyFile))!["Version"]!.GetValue<int>());
        Assert.Equal(3, JsonNode.Parse(File.ReadAllText(fixture.Manifest()))!["version"]!.GetValue<int>());
        Assert.Single(Directory.GetDirectories(fixture.Paths.HistoryBackupsDirectory));
    }

    internal static void UseInheritedPrefix(PaginatedHistoryBehaviorTests.Fixture fixture)
    {
        var records = fixture.Lines(fixture.Original).Select(line => JsonNode.Parse(line)!).ToList();
        var primary = records[0]["payload"]!;
        primary["session_id"] = "synthetic-parent"; primary["forked_from_id"] = "synthetic-parent";
        primary["parent_thread_id"] = "synthetic-parent"; primary["thread_source"] = "subagent";
        primary["subagent_history_start_ordinal"] = 3;
        primary["source"] = new JsonObject { ["subagent"] = new JsonObject { ["thread_spawn"] = new JsonObject { ["parent_thread_id"] = "synthetic-parent", ["depth"] = 1 } } };
        records.Insert(1, JsonNode.Parse("""
            {"type":"session_meta","payload":{"id":"synthetic-parent","session_id":"synthetic-parent","history_mode":"paginated","model_provider":"long-parent-relay","history_base":{"thread_id":"retained-parent-segment","end_byte_offset":751581,"end_ordinal_exclusive":2755},"unknown":["父会话前缀😀"]}}
            """)!);
        for (var index = 0; index < records.Count; index++) records[index]["ordinal"] = index;
        records[2]["payload"]!["thread_id"] = "synthetic-parent";
        fixture.WriteJournal(records.Select(record => record.ToJsonString()).ToArray());
        fixture.Execute(fixture.StateDb, "INSERT INTO threads VALUES('synthetic-parent','relay',X'ff00',2.5)");
        fixture.Execute(fixture.ProjectionDb, "UPDATE thread_history_projection_state SET next_rollout_byte_offset=$length,next_rollout_ordinal=9 WHERE thread_id='synthetic-thread'; INSERT INTO thread_history_projection_state VALUES('synthetic-parent',751581,2755)", ("$length", fixture.Original.LongLength));
        fixture.Execute(fixture.ProjectionDb, "UPDATE thread_items SET rollout_ordinal=rollout_ordinal+1,updated_at_ordinal=updated_at_ordinal+1 WHERE thread_id='synthetic-thread'");
        fixture.Execute(fixture.ProjectionDb, "UPDATE thread_turns SET rollout_ordinal=2,rollout_byte_offset=$start,rollout_end_byte_offset=$end,rollout_end_ordinal=6 WHERE thread_id='synthetic-thread'", ("$start", fixture.Offset(fixture.Original, 2)), ("$end", fixture.Offset(fixture.Original, 7)));
    }
}
