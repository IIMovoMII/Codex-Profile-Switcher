#requires -Version 5.1
[CmdletBinding()]
param()
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot


Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$repairScript = Join-Path $script:ProjectRoot "codex-history-compat.ps1"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-event-projection-test-" + [Guid]::NewGuid().ToString("N"))
$utf8 = New-Object Text.UTF8Encoding($false)
$sqlite = (Get-Command sqlite3.exe -ErrorAction Stop).Source

function Assert-True([bool]$Value, [string]$Message) {
    if (-not $Value) { throw $Message }
}
function Invoke-Sql([string]$Path, [string]$Sql) {
    $result = @($Sql | & $sqlite -batch -bail -noheader $Path 2>&1)
    if ($LASTEXITCODE -ne 0) { throw ($result -join "`n") }
    return $result
}
function New-Fixture([string]$Name) {
    $dir = Join-Path $testRoot $Name
    [void][IO.Directory]::CreateDirectory((Join-Path $dir "sessions"))
    $path = Join-Path $dir "sessions\rollout.jsonl"
    $records = @(
        @{ ordinal=0; type="session_meta"; payload=@{ id="event-thread"; model_provider="openai"; history_mode="paginated" } },
        # A standards-shaped rs_ ID is still unusable when the relay returns
        # only an ID and a zero-width summary. Keep the UI event, remove only
        # this model-facing persisted-item reference.
        @{ ordinal=1; type="event_msg"; payload=@{ type="item_completed"; thread_id="event-thread"; turn_id="turn-1"; item=@{ type="Reasoning"; id="rs_id_only"; summary_text=@("visible reasoning stays"); raw_content=@() } } },
        @{ ordinal=2; type="response_item"; payload=@{ type="reasoning"; id="rs_id_only"; summary=@(@{ type="summary_text"; text=([string][char]0x200B) }); content=$null; encrypted_content=$null } },
        @{ ordinal=3; type="event_msg"; payload=@{ type="item_completed"; thread_id="event-thread"; turn_id="turn-1"; item=@{ type="AgentMessage"; id="item_message"; content=@(@{ type="Text"; text="visible answer stays" }) } } },
        @{ ordinal=4; type="response_item"; payload=@{ type="message"; id="item_message"; role="assistant"; content=@(@{ type="output_text"; text="visible answer stays" }) } },
        @{ ordinal=5; type="response_item"; payload=@{ type="function_call"; id="item_call"; name="example"; arguments="{}"; call_id="call_unchanged" } },
        @{ ordinal=6; type="response_item"; payload=@{ type="function_call_output"; call_id="call_unchanged"; output="ok" } },
        @{ ordinal=7; type="event_msg"; payload=@{ type="item_completed"; thread_id="event-thread"; turn_id="turn-1"; item=@{ type="Extension"; kind="clock.sleep"; id="call_sleep"; durationMs=1000 } } },
        @{ ordinal=8; type="event_msg"; payload=@{ type="item_completed"; thread_id="event-thread"; turn_id="turn-1"; item=@{ type="Extension"; kind="web.search"; id="exec_search"; query="fixture query"; action=@{type="search"; query=$null; queries=@("fixture query")}; results=@() } } }
    )
    $lines = @($records | ForEach-Object { $_ | ConvertTo-Json -Depth 20 -Compress })
    [IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), $utf8)
    $db = Join-Path $dir "thread_history_1.sqlite"
    $length = (Get-Item -LiteralPath $path).Length
    [void](Invoke-Sql $db @"
CREATE TABLE thread_history_projection_state (thread_id TEXT PRIMARY KEY, next_rollout_byte_offset INTEGER NOT NULL, next_rollout_ordinal INTEGER NOT NULL);
CREATE TABLE thread_items (thread_id TEXT NOT NULL, turn_id TEXT NOT NULL, item_id TEXT NOT NULL, rollout_ordinal INTEGER NOT NULL, created_at_ms INTEGER NOT NULL, item_json TEXT NOT NULL, item_type TEXT NOT NULL, updated_at_ordinal INTEGER NOT NULL, PRIMARY KEY(thread_id,turn_id,item_id));
CREATE TABLE thread_turns (thread_id TEXT NOT NULL, turn_id TEXT NOT NULL, rollout_ordinal INTEGER NOT NULL, status TEXT NOT NULL, first_user_item_id TEXT, final_agent_item_id TEXT, PRIMARY KEY(thread_id,turn_id));
INSERT INTO thread_history_projection_state VALUES ('event-thread',$length,9);
INSERT INTO thread_items VALUES ('event-thread','turn-1','rs_id_only',1,1000,'{"type":"reasoning","id":"rs_id_only","summary":["visible reasoning stays"],"content":[]}','reasoning',1);
INSERT INTO thread_items VALUES ('event-thread','turn-1','item_message',3,1001,'{"type":"agentMessage","id":"item_message","text":"visible answer stays","phase":null,"memoryCitation":null,"delivery":null,"questions":null}','agentMessage',3);
INSERT INTO thread_turns VALUES ('event-thread','turn-1',1,'completed',NULL,'item_message');
INSERT INTO thread_items VALUES ('event-thread','turn-1','call_sleep',7,1002,'{"type":"sleep","id":"call_sleep","durationMs":1000}','sleep',7);
INSERT INTO thread_items VALUES ('event-thread','turn-1','exec_search',8,1003,'{"type":"webSearch","id":"exec_search","query":"fixture query","action":{"type":"search","query":null,"queries":["fixture query"]},"results":[]}','webSearch',8);
INSERT INTO thread_items VALUES ('unrelated-thread','other-turn','other-item',99,9000,'{"id":"other-item"}','agentMessage',99);
"@)
    return @{ Home=$dir; Path=$path; Db=$db; Backups=(Join-Path $dir "backups") }
}

try {
    # Persisted-item lookup is also triggered by valid IDs when an official
    # WebSocket continues after prewarm. Remove only optional model-input IDs;
    # keep byte slots and independently projected UI IDs, including compaction.
    $portable = New-Fixture "portable-input"
    $portableRows = [IO.File]::ReadAllLines($portable.Path)
    $portableReasoning = $portableRows[2] | ConvertFrom-Json
    $portableReasoning.payload.encrypted_content = 'keep-encrypted-reasoning'
    $portableRows[2] = $portableReasoning | ConvertTo-Json -Depth 20 -Compress
    $compact = [ordered]@{ordinal=9;type='compacted';payload=[ordered]@{
        replacement_history=@(
            [ordered]@{type='message';id='msg_repeated';role='user';content=@(@{type='input_text';text='中文 "id":"keep text"'})},
            [ordered]@{type='compaction';id='cmp_valid';encrypted_content='keep-encrypted-compaction'}
        )
        guardian_history=@(@{type='message';id='msg_repeated';content=@(@{type='input_text';text='audit'})})
        replacement_history_metadata=@(@{retained_source=@{id=@{message_id='msg_repeated'}}},@{})
    }} | ConvertTo-Json -Depth 30 -Compress
    [IO.File]::WriteAllText($portable.Path, (($portableRows -join "`n") + "`n" + $compact + "`n"), $utf8)
    $portableLength = (Get-Item -LiteralPath $portable.Path).Length
    [void](Invoke-Sql $portable.Db "UPDATE thread_history_projection_state SET next_rollout_byte_offset=$portableLength,next_rollout_ordinal=10;")
    $portableBefore = [IO.File]::ReadAllBytes($portable.Path)
    $portableLinesBefore = [IO.File]::ReadAllLines($portable.Path)
    $portableDbBefore = (Get-FileHash -LiteralPath $portable.Db).Hash
    $portableResult = & $repairScript -Command repair -CodexHome $portable.Home -BackupRoot $portable.Backups -PortableInputIds
    Assert-True ($portableResult.RepairedFiles -eq 1 -and $portableResult.RepairedDatabases -eq 0) 'Portable repair changed a UI database.'
    $portableLinesAfter = [IO.File]::ReadAllLines($portable.Path)
    for ($index=0; $index -lt $portableLinesBefore.Count; $index++) {
        Assert-True ($utf8.GetByteCount($portableLinesBefore[$index]) -eq $utf8.GetByteCount($portableLinesAfter[$index])) 'Portable repair moved a byte boundary.'
        if ($index -notin @(2,4,5,9)) { Assert-True ($portableLinesBefore[$index] -ceq $portableLinesAfter[$index]) 'Portable repair changed an unrelated line.' }
    }
    Assert-True ($null -eq ($portableLinesAfter[2] | ConvertFrom-Json).payload.id) 'Reasoning input ID remains.'
    Assert-True (($portableLinesAfter[2] | ConvertFrom-Json).payload.encrypted_content -ceq 'keep-encrypted-reasoning') 'Encrypted reasoning changed.'
    $portableCompact = ($portableLinesAfter[9] | ConvertFrom-Json).payload
    Assert-True ($null -eq $portableCompact.replacement_history[0].id -and $null -eq $portableCompact.replacement_history[1].id) 'Compacted replacement IDs remain.'
    Assert-True ($portableCompact.guardian_history[0].id -ceq 'msg_repeated') 'Guardian history changed.'
    Assert-True ($portableCompact.replacement_history_metadata[0].retained_source.id.message_id -ceq 'msg_repeated') 'Retained-source metadata changed.'
    Assert-True ((Get-FileHash -LiteralPath $portable.Db).Hash -ceq $portableDbBefore) 'Portable repair changed visible history.'
    $portableAgain = & $repairScript -Command scan -CodexHome $portable.Home -BackupRoot $portable.Backups -PortableInputIds
    Assert-True ($portableAgain.AffectedFiles -eq 0) 'Portable repair is not idempotent.'
    [void](& $repairScript -Command rollback -CodexHome $portable.Home -BackupRoot $portable.Backups -ManifestPath $portableResult.ManifestPath)
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($portable.Path)) -ceq [Convert]::ToBase64String($portableBefore)) 'Portable rollback did not restore exact bytes.'
    foreach ($invalid in @(
        '{"ordinal":1,"type":"response_item","payload":{"type":"message","id":12}}',
        '{"ordinal":1,"type":"response_item","payload":{"type":"message","id":"msg_a","id":"msg_b"}}',
        '{"ordinal":1,"type":"response_item","payload":{"type":"message","i\u0064":"msg_a"}}',
        '{"ordinal":1,"type":"response_item","payload":{"type":"future_unknown","id":"foo_id"}}'
    )) {
        $refused=$false
        try { $candidate=[CodexHistoryCompat.PortableHistory]::Inspect($invalid,1); $refused=$null -ne $candidate -and -not [string]::IsNullOrWhiteSpace($candidate.UnsupportedReason) } catch { $refused=$true }
        Assert-True $refused 'Unknown/ambiguous input ID encoding was silently accepted.'
    }

    foreach ($variant in @('valid','changed-live','changed-backup')) {
        $legacy = New-Fixture ('legacy-layout-' + $variant)
        [void][IO.Directory]::CreateDirectory((Join-Path $legacy.Backups 'old-v2'))
        $legacySource = Join-Path $legacy.Backups 'old-v2\original.jsonl'
        [IO.File]::Copy($legacy.Path,$legacySource)
        $legacyRows = [IO.File]::ReadAllLines($legacySource)
        $oldHash = (Get-FileHash -LiteralPath $legacySource).Hash.ToLowerInvariant()
        $newMessage = $legacyRows[4].Replace('item_message','msg_message')
        $legacyLive = @($legacyRows[0],$legacyRows[1],$legacyRows[3],$newMessage) + $legacyRows[5..8]
        [IO.File]::WriteAllText($legacy.Path,(($legacyLive -join "`n")+"`n"),$utf8)
        $legacyBefore = [IO.File]::ReadAllBytes($legacy.Path)
        $legacyDbHash = (Get-FileHash -LiteralPath $legacy.Db).Hash
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $dropHash = [BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($legacyRows[2]))).Replace('-','').ToLowerInvariant()
            $messageHash = [BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($legacyRows[4]))).Replace('-','').ToLowerInvariant()
            $newMessageHash = [BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($newMessage))).Replace('-','').ToLowerInvariant()
        } finally { $sha.Dispose() }
        $oldManifest = @{version=2;status='complete';files=@(@{path=$legacy.Path;backup_path=$legacySource;original_sha256=$oldHash;
            original_length=(Get-Item -LiteralPath $legacySource).Length;repaired_sha256=(Get-FileHash -LiteralPath $legacy.Path).Hash.ToLowerInvariant();
            status='applied';changes=@(
                @{kind='response_item';action='drop';line_number=3;old_id='rs_id_only';old_line_sha256=$dropHash},
                @{kind='response_item';action='rename';line_number=5;old_id='item_message';new_id='msg_message';old_line_sha256=$messageHash;new_line_sha256=$newMessageHash}
            )})}
        [IO.File]::WriteAllText((Join-Path $legacy.Backups 'old-v2\manifest.json'),($oldManifest|ConvertTo-Json -Depth 20),$utf8)
        if ($variant -eq 'changed-live') { [IO.File]::AppendAllText($legacy.Path,' ',$utf8) }
        if ($variant -eq 'changed-backup') { [IO.File]::AppendAllText($legacySource,' ',$utf8) }
        if ($variant -ne 'valid') {
            $unchanged = (Get-FileHash -LiteralPath $legacy.Path).Hash
            $refused = $false
            try { [void](& $repairScript -Command repair -CodexHome $legacy.Home -BackupRoot $legacy.Backups -PortableInputIds) } catch { $refused=$true }
            Assert-True $refused 'Unverified old layout was accepted.'
            Assert-True ((Get-FileHash -LiteralPath $legacy.Path).Hash -ceq $unchanged) 'Failed old-layout verification wrote live history.'
            continue
        }
        $legacyResult = & $repairScript -Command repair -CodexHome $legacy.Home -BackupRoot $legacy.Backups -PortableInputIds
        $legacyAfter = [IO.File]::ReadAllLines($legacy.Path)
        Assert-True ($legacyAfter.Count -eq $legacyRows.Count) 'Missing ordinal slot was not restored.'
        for ($index=0;$index -lt $legacyRows.Count;$index++) {
            Assert-True ($utf8.GetByteCount($legacyAfter[$index]) -eq $utf8.GetByteCount($legacyRows[$index])) 'Recovered layout moved an original byte boundary.'
        }
        Assert-True (($legacyAfter[2]|ConvertFrom-Json).ordinal -eq 2 -and $legacyAfter[2].Contains('token_count')) 'Removed reasoning was not restored as a non-model slot.'
        Assert-True ((Get-FileHash -LiteralPath $legacy.Db).Hash -ceq $legacyDbHash) 'Layout recovery changed the UI database.'
        [void](& $repairScript -Command rollback -CodexHome $legacy.Home -BackupRoot $legacy.Backups -ManifestPath $legacyResult.ManifestPath)
        Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($legacy.Path)) -ceq [Convert]::ToBase64String($legacyBefore)) 'Layout rollback did not exactly restore the pre-transaction file.'
    }

    foreach ($variant in @('valid','bad-thread','dangling-turn')) {
        $empty = New-Fixture ('empty-projection-' + $variant)
        $emptyRows = [IO.File]::ReadAllLines($empty.Path)
        $reasoning = $emptyRows[2] | ConvertFrom-Json
        $reasoning.payload.encrypted_content = 'replayable'
        $emptyRows[2] = $reasoning | ConvertTo-Json -Depth 20 -Compress
        if ($variant -eq 'bad-thread') { $emptyRows[1] = $emptyRows[1].Replace('event-thread','wrong-thread') }
        [IO.File]::WriteAllText($empty.Path,(($emptyRows -join "`n")+"`n"),$utf8)
        $length = (Get-Item -LiteralPath $empty.Path).Length
        [void](Invoke-Sql $empty.Db "DELETE FROM thread_items WHERE thread_id='event-thread'; UPDATE thread_history_projection_state SET next_rollout_byte_offset=$length WHERE thread_id='event-thread';")
        if ($variant -ne 'dangling-turn') { [void](Invoke-Sql $empty.Db "DELETE FROM thread_turns WHERE thread_id='event-thread';") }
        $beforeHash = (Get-FileHash -LiteralPath $empty.Path).Hash
        $refused=$false
        try { $emptyResult = & $repairScript -Command repair -CodexHome $empty.Home -BackupRoot $empty.Backups -PortableInputIds } catch { $refused=$true }
        if ($variant -eq 'valid') {
            Assert-True (-not $refused) 'Verified empty projection was refused.'
            [void](& $repairScript -Command rollback -CodexHome $empty.Home -BackupRoot $empty.Backups -ManifestPath $emptyResult.ManifestPath)
        } else { Assert-True $refused 'Unverified empty projection was accepted.' }
        Assert-True ((Get-FileHash -LiteralPath $empty.Path).Hash -ceq $beforeHash) 'Empty projection refusal/rollback changed source bytes.'
    }

    $f = New-Fixture "event-backed"
    $before = [IO.File]::ReadAllBytes($f.Path)
    $beforeLines = [IO.File]::ReadAllLines($f.Path)
    $dbBefore = (Get-FileHash -LiteralPath $f.Db).Hash
    $result = & $repairScript -Command repair -CodexHome $f.Home -BackupRoot $f.Backups
    Assert-True ($result.RepairedFiles -eq 1 -and $result.RepairedDatabases -eq 0) "UI projection must not be rewritten for response-only repairs."
    Assert-True ((Get-FileHash -LiteralPath $f.Db).Hash -ceq $dbBefore) "Visible history database changed."
    $afterLines = [IO.File]::ReadAllLines($f.Path)
    for ($i=0; $i -lt $beforeLines.Count; $i++) {
        Assert-True ($utf8.GetByteCount($beforeLines[$i]) -eq $utf8.GetByteCount($afterLines[$i])) "Line byte offsets changed."
        if ($i -notin @(2,4,5)) { Assert-True ($beforeLines[$i] -ceq $afterLines[$i]) "Unrelated/UI event line changed." }
    }
    Assert-True ($afterLines[1] -match 'rs_id_only' -and $afterLines[2] -match 'token_count' -and $afterLines[4] -match 'msg_message' -and $afterLines[5] -match 'fc_call') "Response history was not repaired or the visible event was lost."
    Assert-True (($afterLines[5] | ConvertFrom-Json).payload.call_id -ceq "call_unchanged") "Tool pairing changed."
    [void](& $repairScript -Command rollback -CodexHome $f.Home -ManifestPath $result.ManifestPath)
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($f.Path)) -ceq [Convert]::ToBase64String($before)) "Rollback did not restore original bytes."
    Assert-True ((Get-FileHash -LiteralPath $f.Db).Hash -ceq $dbBefore) "Rollback changed untouched UI projection."

    # Older segments can have a visible event with a different UI ID and no
    # thread_items row for the adjacent model reasoning item. Removing the
    # model item must still be allowed without touching the projection.
    $orphan = New-Fixture "orphan-model-item"
    [void](Invoke-Sql $orphan.Db "DELETE FROM thread_items WHERE item_id='rs_id_only';")
    $orphanBefore = [IO.File]::ReadAllBytes($orphan.Path)
    $orphanDbHash = (Get-FileHash -LiteralPath $orphan.Db).Hash
    $orphanResult = & $repairScript -Command repair -CodexHome $orphan.Home -BackupRoot $orphan.Backups
    Assert-True ($orphanResult.RepairedFiles -eq 1 -and $orphanResult.RepairedDatabases -eq 0) "Orphan model item was not repaired."
    Assert-True ((Get-FileHash -LiteralPath $orphan.Db).Hash -ceq $orphanDbHash) "Orphan repair changed the UI projection."
    Assert-True (([IO.File]::ReadAllLines($orphan.Path)[2]) -match 'token_count') "Orphan model item was not replaced."
    [void](& $repairScript -Command rollback -CodexHome $orphan.Home -ManifestPath $orphanResult.ManifestPath)
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($orphan.Path)) -ceq [Convert]::ToBase64String($orphanBefore)) "Orphan rollback did not restore the model history."

    # An empty UI reasoning summary is still an independently sourced event,
    # not a model input. Its ID may differ from the adjacent response_item.
    # Removing the unusable model item must never erase that UI row.
    $emptyUi = New-Fixture "empty-ui-reasoning"
    $emptyUiRows = [IO.File]::ReadAllLines($emptyUi.Path)
    $emptyUiEvent = $emptyUiRows[1] | ConvertFrom-Json
    $emptyUiEvent.payload.item.id = "item-ui-only"
    $emptyUiEvent.payload.item.summary_text = @([string][char]0x200B)
    $emptyUiEvent.payload.item.raw_content = @()
    $emptyUiRows[1] = $emptyUiEvent | ConvertTo-Json -Depth 20 -Compress
    [IO.File]::WriteAllText($emptyUi.Path, ([string]::Join([string][char]10, $emptyUiRows) + [char]10), $utf8)
    $emptyUiLength = (Get-Item -LiteralPath $emptyUi.Path).Length
    [void](Invoke-Sql $emptyUi.Db @"
UPDATE thread_items SET item_id='item-ui-only', item_json='{"type":"reasoning","id":"item-ui-only","summary":["\u200b"],"content":[]}' WHERE item_id='rs_id_only';
UPDATE thread_history_projection_state SET next_rollout_byte_offset=$emptyUiLength WHERE thread_id='event-thread';
"@)
    $emptyUiBefore = [IO.File]::ReadAllBytes($emptyUi.Path)
    $emptyUiDbHash = (Get-FileHash -LiteralPath $emptyUi.Db).Hash
    $emptyUiResult = & $repairScript -Command repair -CodexHome $emptyUi.Home -BackupRoot $emptyUi.Backups
    Assert-True ($emptyUiResult.RepairedFiles -eq 1 -and $emptyUiResult.RepairedDatabases -eq 0) "An empty UI summary must not be deleted as model history."
    Assert-True ((Get-FileHash -LiteralPath $emptyUi.Db).Hash -ceq $emptyUiDbHash) "Empty reasoning repair changed the UI database."
    Assert-True (([IO.File]::ReadAllLines($emptyUi.Path)[1]) -ceq $emptyUiRows[1]) "Empty reasoning repair changed its independent UI event."
    Assert-True (([IO.File]::ReadAllLines($emptyUi.Path)[2]) -match "token_count") "Empty reasoning repair did not remove the unusable model item."
    [void](& $repairScript -Command rollback -CodexHome $emptyUi.Home -ManifestPath $emptyUiResult.ManifestPath)
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($emptyUi.Path)) -ceq [Convert]::ToBase64String($emptyUiBefore)) "Empty reasoning rollback did not restore the original journal bytes."
    Assert-True ((Get-FileHash -LiteralPath $emptyUi.Db).Hash -ceq $emptyUiDbHash) "Empty reasoning rollback modified its preserved UI row."

    # A continuation keeps the logical session ID in JSONL, while SQLite keys
    # its projection by the second UUID in the native rollout filename.
    $f = New-Fixture "continued-segment"
    $logicalId = "11111111-1111-7111-8111-111111111111"
    $segmentId = "22222222-2222-7222-8222-222222222222"
    $segmentPath = Join-Path $f.Home "sessions\rollout-2026-10-01T03-08-54-${logicalId}_${segmentId}.jsonl"
    $segmentLines = @([IO.File]::ReadAllLines($f.Path) | ForEach-Object {
        $record = $_.Replace('event-thread', $logicalId) | ConvertFrom-Json
        $record.ordinal += 20
        if ($record.type -eq 'session_meta') {
            $record.payload | Add-Member -NotePropertyName history_base -NotePropertyValue @{
                thread_id=$logicalId; end_ordinal_exclusive=20; end_byte_offset=1000
            }
        }
        $record | ConvertTo-Json -Depth 20 -Compress
    })
    [IO.File]::WriteAllText($segmentPath, (($segmentLines -join "`n") + "`n"), $utf8)
    Remove-Item -LiteralPath $f.Path
    $f.Path = $segmentPath
    $segmentLength = (Get-Item -LiteralPath $f.Path).Length
    [void](Invoke-Sql $f.Db @"
UPDATE thread_items SET thread_id='$segmentId', rollout_ordinal=rollout_ordinal+20, updated_at_ordinal=updated_at_ordinal+20 WHERE thread_id='event-thread';
UPDATE thread_turns SET thread_id='$segmentId', rollout_ordinal=rollout_ordinal+20 WHERE thread_id='event-thread';
UPDATE thread_history_projection_state SET thread_id='$segmentId', next_rollout_ordinal=29, next_rollout_byte_offset=$segmentLength WHERE thread_id='event-thread';
INSERT INTO thread_history_projection_state VALUES ('$logicalId',1000,20);
INSERT INTO thread_items VALUES ('$logicalId','base-turn','base-item',19,900,'{"id":"base-item","type":"agentMessage"}','agentMessage',19);
"@)
    $before = [IO.File]::ReadAllBytes($f.Path)
    $dbBefore = (Get-FileHash -LiteralPath $f.Db).Hash
    $result = & $repairScript -Command repair -CodexHome $f.Home -BackupRoot $f.Backups
    Assert-True ($result.RepairedFiles -eq 1 -and $result.RepairedDatabases -eq 0) "Continuation must repair model IDs using its own projection."
    Assert-True ((Get-FileHash -LiteralPath $f.Db).Hash -ceq $dbBefore) "Continuation or inherited UI changed."
    Assert-True ((Get-Item -LiteralPath $f.Path).Length -eq $segmentLength) "Continuation byte layout changed."
    [void](& $repairScript -Command rollback -CodexHome $f.Home -BackupRoot $f.Backups -ManifestPath $result.ManifestPath)
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($f.Path)) -ceq [Convert]::ToBase64String($before)) "Continuation rollback changed bytes."

    $segmentDbBefore = [IO.File]::ReadAllBytes($f.Db)
    foreach ($case in @('missing-segment', 'wrong-segment-cursor', 'wrong-logical-id', 'wrong-base-boundary')) {
        [IO.File]::WriteAllBytes($f.Path, $before)
        [IO.File]::WriteAllBytes($f.Db, $segmentDbBefore)
        switch ($case) {
            'missing-segment' { [void](Invoke-Sql $f.Db "DELETE FROM thread_history_projection_state WHERE thread_id='$segmentId';") }
            'wrong-segment-cursor' { [void](Invoke-Sql $f.Db "UPDATE thread_history_projection_state SET next_rollout_ordinal=30 WHERE thread_id='$segmentId';") }
            'wrong-logical-id' {
                $rows = [IO.File]::ReadAllLines($f.Path)
                $rows[1] = $rows[1].Replace($logicalId, $segmentId)
                [IO.File]::WriteAllText($f.Path, (($rows -join "`n") + "`n"), $utf8)
            }
            'wrong-base-boundary' {
                $rows = [IO.File]::ReadAllLines($f.Path)
                $metaRecord = $rows[0] | ConvertFrom-Json
                $metaRecord.payload.history_base.end_ordinal_exclusive = 21
                $rows[0] = $metaRecord | ConvertTo-Json -Depth 20 -Compress
                [IO.File]::WriteAllText($f.Path, (($rows -join "`n") + "`n"), $utf8)
            }
        }
        $fileHash = (Get-FileHash -LiteralPath $f.Path).Hash
        $dbHash = (Get-FileHash -LiteralPath $f.Db).Hash
        $failed = $false
        try { [void](& $repairScript -Command repair -CodexHome $f.Home -BackupRoot $f.Backups) }
        catch { $failed = $true }
        Assert-True $failed "Unsafe continuation accepted: $case"
        Assert-True ((Get-FileHash -LiteralPath $f.Path).Hash -ceq $fileHash) "Rejected continuation was changed."
        Assert-True ((Get-FileHash -LiteralPath $f.Db).Hash -ceq $dbHash) "Rejected continuation projection was changed."
    }
    [IO.File]::WriteAllBytes($f.Path, $before)
    [IO.File]::WriteAllBytes($f.Db, $segmentDbBefore)

    # Exercise the user's actual one-key workflow, with only temporary home,
    # fake credentials and fake login. No real config/auth is used.
    [IO.File]::WriteAllText((Join-Path $f.Home 'config.toml'), "model_provider = `"openai`"`nopenai_base_url = `"https://relay.example/v1`"`nmodel = `"fixture`"`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $f.Home 'auth.json'), '{"OPENAI_API_KEY":"fixture-secret"}', $utf8)
    $fake = Join-Path $f.Home 'fake-login.ps1'
    [IO.File]::WriteAllText($fake, @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
if ($Arguments[0] -ne 'login') { exit 3 }
if ($Arguments.Count -ge 2 -and $Arguments[1] -eq 'status') {
    $auth = [IO.File]::ReadAllText((Join-Path $env:CODEX_HOME 'auth.json')) | ConvertFrom-Json
    if ($null -ne $auth.PSObject.Properties['auth_mode'] -and $auth.auth_mode -eq 'chatgpt') { Write-Output 'Logged in using ChatGPT' }
    else { Write-Output 'Logged in using an API key' }
    exit 0
}
[IO.File]::WriteAllText((Join-Path $env:CODEX_HOME 'auth.json'), '{"auth_mode":"chatgpt","tokens":{"id_token":"fixture-id","access_token":"fixture-access","refresh_token":"fixture-refresh"}}')
exit 0
'@, $utf8)
    $store = Join-Path $f.Home 'switcher-state'
    $shell = (Get-Process -Id $PID).Path
    $switcher = Join-Path $script:ProjectRoot 'codex-profile-switcher.ps1'
    $commonArgs = @('-NoProfile', '-File', $switcher, '-CodexHome', $f.Home, '-DataDir', $store,
        '-MonitorDataDir', (Join-Path $store 'monitor'), '-CodexExecutable', $fake, '-UnsafeAllowRunningCodex')
    $output = @(& $shell @commonArgs -Command toggle 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) ("One-key automatic segment repair failed: " + ($output -join ' | '))
    Assert-True (([IO.File]::ReadAllText((Join-Path $f.Home 'auth.json')) | ConvertFrom-Json).auth_mode -eq 'chatgpt') "One-key workflow did not reach official mode."
    Assert-True (([IO.File]::ReadAllText((Join-Path $store 'history-compat-ready.json')) | ConvertFrom-Json).version -eq 3) "One-key workflow did not prepare history."
    Assert-True ((Get-FileHash -LiteralPath $f.Db).Hash -ceq $dbBefore) "One-key workflow changed UI or baseline."
    $output = @(& $shell @commonArgs -Command toggle 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) ("Reverse switch failed: " + ($output -join ' | '))
    Assert-True (([IO.File]::ReadAllText((Join-Path $f.Home 'auth.json')) | ConvertFrom-Json).OPENAI_API_KEY -eq 'fixture-secret') "Reverse switch lost relay credentials."

    # An independently materialized continuation retains its two-UUID filename
    # and segment-keyed UI projection, but has no parent base and starts at 0.
    # Do not infer that such a segment is truncated just from its filename.
    $f = New-Fixture 'independent-segment'
    $independentPath = Join-Path $f.Home "sessions\rollout-2026-10-10T21-04-21-${logicalId}_${segmentId}.jsonl"
    $independentLines = @([IO.File]::ReadAllLines($f.Path) | ForEach-Object {
        $record = $_.Replace('event-thread', $logicalId) | ConvertFrom-Json
        if ($record.type -eq 'session_meta') {
            $record.payload | Add-Member -NotePropertyName session_id -NotePropertyValue $logicalId
        }
        $record | ConvertTo-Json -Depth 20 -Compress
    })
    # Materialization can preserve several metadata records from the old
    # chain. They must all name the independent owner and contain no base.
    $laterMeta = $independentLines[0] | ConvertFrom-Json
    $laterMeta.ordinal = 9
    $independentLines += ($laterMeta | ConvertTo-Json -Depth 20 -Compress)
    [IO.File]::WriteAllText($independentPath, (($independentLines -join "`n") + "`n"), $utf8)
    Remove-Item -LiteralPath $f.Path
    $f.Path = $independentPath
    $independentLength = (Get-Item -LiteralPath $f.Path).Length
    [void](Invoke-Sql $f.Db @"
UPDATE thread_items SET thread_id='$segmentId' WHERE thread_id='event-thread';
UPDATE thread_turns SET thread_id='$segmentId' WHERE thread_id='event-thread';
UPDATE thread_history_projection_state SET thread_id='$segmentId',next_rollout_ordinal=10,next_rollout_byte_offset=$independentLength WHERE thread_id='event-thread';
INSERT INTO thread_history_projection_state VALUES ('$logicalId',1000,20);
INSERT INTO thread_items VALUES ('$logicalId','base-turn','base-item',19,900,'{"id":"base-item","type":"agentMessage"}','agentMessage',19);
"@)
    $independentBefore = [IO.File]::ReadAllBytes($f.Path)
    $independentDbBefore = [IO.File]::ReadAllBytes($f.Db)
    $independentDbHash = (Get-FileHash -LiteralPath $f.Db).Hash
    $result = & $repairScript -Command repair -CodexHome $f.Home -BackupRoot $f.Backups -PortableInputIds
    Assert-True ($result.RepairedFiles -eq 1 -and $result.RepairedDatabases -eq 0) 'Independent segment must use its segment projection without recreating a parent base.'
    Assert-True ((Get-FileHash -LiteralPath $f.Db).Hash -ceq $independentDbHash) 'Independent repair changed UI or unrelated logical-thread projection.'
    Assert-True ((Get-Item -LiteralPath $f.Path).Length -eq $independentLength) 'Independent repair shifted byte positions.'
    $afterMeta = [IO.File]::ReadAllLines($f.Path)[0] | ConvertFrom-Json
    Assert-True ($afterMeta.ordinal -eq 0 -and $null -eq $afterMeta.payload.PSObject.Properties['history_base']) 'Independent repair recreated inheritance.'
    [void](& $repairScript -Command rollback -CodexHome $f.Home -BackupRoot $f.Backups -ManifestPath $result.ManifestPath)
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($f.Path)) -ceq [Convert]::ToBase64String($independentBefore)) 'Independent rollback changed original bytes.'
    foreach ($case in @('nonzero-without-base','partial-base','dangling-fork','dangling-fork-ordinal','conflicting-session-id','missing-segment','wrong-cursor','foreign-ui','ordinal-gap','later-metadata-base')) {
        [IO.File]::WriteAllBytes($f.Path,$independentBefore)
        [IO.File]::WriteAllBytes($f.Db,$independentDbBefore)
        $lines = [IO.File]::ReadAllLines($f.Path)
        $meta = $lines[0] | ConvertFrom-Json
        switch ($case) {
            'nonzero-without-base' { $meta.ordinal = 20 }
            'partial-base' { $meta.payload | Add-Member -NotePropertyName history_base -NotePropertyValue @{thread_id=$logicalId} }
            'dangling-fork' { $meta.payload | Add-Member -NotePropertyName forked_from_id -NotePropertyValue $logicalId }
            'dangling-fork-ordinal' { $meta.payload | Add-Member -NotePropertyName forked_from_ordinal_exclusive -NotePropertyValue 20 }
            'conflicting-session-id' { $meta.payload.session_id = $segmentId }
            'missing-segment' { [void](Invoke-Sql $f.Db "DELETE FROM thread_history_projection_state WHERE thread_id='$segmentId';") }
            'wrong-cursor' { [void](Invoke-Sql $f.Db "UPDATE thread_history_projection_state SET next_rollout_ordinal=11 WHERE thread_id='$segmentId';") }
            'foreign-ui' { $lines[1] = $lines[1].Replace($logicalId,$segmentId) }
            'ordinal-gap' {
                for ($index = 7; $index -lt $lines.Count; $index++) {
                    $record = $lines[$index] | ConvertFrom-Json
                    $record.ordinal++
                    $lines[$index] = $record | ConvertTo-Json -Depth 20 -Compress
                }
                [void](Invoke-Sql $f.Db "UPDATE thread_history_projection_state SET next_rollout_ordinal=11 WHERE thread_id='$segmentId';")
            }
            'later-metadata-base' {
                $record = $lines[9] | ConvertFrom-Json
                $record.payload | Add-Member -NotePropertyName history_base -NotePropertyValue @{thread_id=$logicalId;end_ordinal_exclusive=9;end_byte_offset=1000}
                $lines[9] = $record | ConvertTo-Json -Depth 20 -Compress
            }
        }
        $lines[0] = $meta | ConvertTo-Json -Depth 20 -Compress
        [IO.File]::WriteAllText($f.Path,(($lines -join "`n")+"`n"),$utf8)
        [void](Invoke-Sql $f.Db "UPDATE thread_history_projection_state SET next_rollout_byte_offset=$((Get-Item -LiteralPath $f.Path).Length) WHERE thread_id='$segmentId';")
        $fileHash = (Get-FileHash -LiteralPath $f.Path).Hash
        $dbHash = (Get-FileHash -LiteralPath $f.Db).Hash
        $failed = $false
        try { [void](& $repairScript -Command repair -CodexHome $f.Home -BackupRoot $f.Backups -PortableInputIds) }
        catch { $failed = $true }
        Assert-True $failed "Unsafe independent segment accepted: $case"
        Assert-True ((Get-FileHash -LiteralPath $f.Path).Hash -ceq $fileHash) "Rejected independent segment was changed: $case"
        Assert-True ((Get-FileHash -LiteralPath $f.Db).Hash -ceq $dbHash) "Rejected independent projection was changed: $case"
    }
    [IO.File]::WriteAllBytes($f.Path,$independentBefore)
    [IO.File]::WriteAllBytes($f.Db,$independentDbBefore)
    # The same verified layout remains supported in archived_sessions.
    $archive = Join-Path $f.Home 'archived_sessions'
    [void][IO.Directory]::CreateDirectory($archive)
    $archivedPath = Join-Path $archive ([IO.Path]::GetFileName($f.Path))
    Move-Item -LiteralPath $f.Path -Destination $archivedPath
    $f.Path = $archivedPath
    $result = & $repairScript -Command repair -CodexHome $f.Home -BackupRoot $f.Backups -PortableInputIds
    Assert-True ($result.RepairedFiles -eq 1 -and $result.RepairedDatabases -eq 0) 'Archived independent segment was not prepared.'
    [void](& $repairScript -Command rollback -CodexHome $f.Home -BackupRoot $f.Backups -ManifestPath $result.ManifestPath)
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($f.Path)) -ceq [Convert]::ToBase64String($independentBefore)) 'Archived independent rollback changed bytes.'

    # Menu 1 calls this same toggle entrypoint. Exercise both directions using
    # an archived independent segment; all auth/config and login are fixtures.
    [IO.File]::WriteAllText((Join-Path $f.Home 'config.toml'), "model_provider = `"openai`"`nopenai_base_url = `"https://relay.example/v1`"`nmodel = `"fixture`"`n", $utf8)
    [IO.File]::WriteAllText((Join-Path $f.Home 'auth.json'), '{"OPENAI_API_KEY":"fixture-secret"}', $utf8)
    $independentStore = Join-Path $f.Home 'switcher-state'
    $independentArgs = @('-NoProfile','-File',$switcher,'-CodexHome',$f.Home,'-DataDir',$independentStore,
        '-MonitorDataDir',(Join-Path $independentStore 'monitor'),'-CodexExecutable',$fake,'-UnsafeAllowRunningCodex')
    $output = @(& $shell @independentArgs -Command toggle 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) ('Independent one-key preparation failed: ' + ($output -join ' | '))
    Assert-True (([IO.File]::ReadAllText((Join-Path $f.Home 'auth.json')) | ConvertFrom-Json).auth_mode -eq 'chatgpt') 'Independent toggle did not activate fixture official auth.'
    Assert-True ((Get-FileHash -LiteralPath $f.Db).Hash -ceq $independentDbHash) 'Independent toggle changed UI projection.'
    $output = @(& $shell @independentArgs -Command toggle 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) ('Independent reverse toggle failed: ' + ($output -join ' | '))
    Assert-True (([IO.File]::ReadAllText((Join-Path $f.Home 'auth.json')) | ConvertFrom-Json).OPENAI_API_KEY -eq 'fixture-secret') 'Independent reverse toggle lost fixture API auth.'

    # A materialized fork starts with its own metadata, then copied ancestry.
    # Every UI event belongs to the child; the parent DB must remain untouched.
    $f = New-Fixture 'materialized-fork'
    $childId = '33333333-3333-7333-8333-333333333333'
    $parentId = '44444444-4444-7444-8444-444444444444'
    $forkPath = Join-Path $f.Home "sessions\rollout-2026-10-08T19-00-01-$childId.jsonl"
    $forkRecords = @([IO.File]::ReadAllLines($f.Path) | ForEach-Object {
        $record = $_.Replace('event-thread', $childId) | ConvertFrom-Json
        $record.ordinal++
        if ($record.type -eq 'session_meta') { $record.payload.id = $parentId }
        $record
    })
    $childMeta = @{ordinal=0; type='session_meta'; payload=@{
        id=$childId; forked_from_id=$parentId; history_mode='paginated'; model_provider='openai'
    }}
    $forkLines = @(@($childMeta) + $forkRecords | ForEach-Object { $_ | ConvertTo-Json -Depth 20 -Compress })
    [IO.File]::WriteAllText($forkPath, (($forkLines -join "`n") + "`n"), $utf8)
    Remove-Item -LiteralPath $f.Path
    $f.Path = $forkPath
    $forkLength = (Get-Item -LiteralPath $forkPath).Length
    [void](Invoke-Sql $f.Db @"
UPDATE thread_items SET thread_id='$childId',rollout_ordinal=rollout_ordinal+1,updated_at_ordinal=updated_at_ordinal+1 WHERE thread_id='event-thread';
UPDATE thread_turns SET thread_id='$childId',rollout_ordinal=rollout_ordinal+1 WHERE thread_id='event-thread';
UPDATE thread_history_projection_state SET thread_id='$childId',next_rollout_ordinal=10,next_rollout_byte_offset=$forkLength WHERE thread_id='event-thread';
CREATE TABLE threads (id TEXT PRIMARY KEY,model_provider TEXT NOT NULL);
INSERT INTO threads VALUES ('$childId','openai');
INSERT INTO threads VALUES ('$parentId','custom');
INSERT INTO thread_items VALUES ('$parentId','parent-turn','parent-item',19,900,'{"id":"parent-item","type":"agentMessage"}','agentMessage',19);
"@)
    $forkBefore = [IO.File]::ReadAllBytes($f.Path)
    $forkDbBefore = [IO.File]::ReadAllBytes($f.Db)
    $fileHash = (Get-FileHash -LiteralPath $f.Path).Hash
    $dbHash = (Get-FileHash -LiteralPath $f.Db).Hash
    $result = & $repairScript -Command repair -CodexHome $f.Home -BackupRoot $f.Backups
    Assert-True ($result.RepairedFiles -eq 1 -and $result.RepairedDatabases -eq 0) 'Fork repair changed a database or ancestor provider.'
    Assert-True ((Get-FileHash -LiteralPath $f.Db).Hash -ceq $dbHash) 'Fork repair changed parent or child projections.'
    Assert-True ((Get-Item -LiteralPath $f.Path).Length -eq $forkLength) 'Fork repair moved original byte positions.'
    [void](& $repairScript -Command rollback -CodexHome $f.Home -ManifestPath $result.ManifestPath)
    Assert-True ((Get-FileHash -LiteralPath $f.Path).Hash -ceq $fileHash) 'Fork rollback did not restore exact bytes.'
    # Copied parent base metadata is inert only behind a full materialized
    # compaction baseline; the child's own base is still forbidden here.
    $withBase = @([IO.File]::ReadAllLines($f.Path) | ForEach-Object { $_ | ConvertFrom-Json })
    $withBase[1].payload | Add-Member -NotePropertyName history_base -NotePropertyValue @{thread_id=$parentId;end_ordinal_exclusive=90;end_byte_offset=9000}
    foreach ($record in $withBase[2..9]) { $record.ordinal++ }
    $fullBaseline = @{ordinal=2;type='compacted';payload=@{replacement_history=@(@{type='compaction';id='cmp_base';encrypted_content='fixture-baseline'})}}
    $baseLines = @(@($withBase[0],$withBase[1],$fullBaseline) + $withBase[2..9] | ForEach-Object { $_ | ConvertTo-Json -Depth 20 -Compress })
    [IO.File]::WriteAllText($f.Path,(($baseLines -join "`n")+"`n"),$utf8)
    [void](Invoke-Sql $f.Db "UPDATE thread_items SET rollout_ordinal=rollout_ordinal+1,updated_at_ordinal=updated_at_ordinal+1 WHERE thread_id='$childId'; UPDATE thread_turns SET rollout_ordinal=rollout_ordinal+1 WHERE thread_id='$childId'; UPDATE thread_history_projection_state SET next_rollout_ordinal=11,next_rollout_byte_offset=$((Get-Item -LiteralPath $f.Path).Length) WHERE thread_id='$childId';")
    $baseHash = (Get-FileHash -LiteralPath $f.Path).Hash
    $baseDbHash = (Get-FileHash -LiteralPath $f.Db).Hash
    $baseResult = & $repairScript -Command repair -CodexHome $f.Home -BackupRoot $f.Backups -PortableInputIds
    Assert-True ((Get-FileHash -LiteralPath $f.Db).Hash -ceq $baseDbHash) 'Materialized baseline repair changed a projection.'
    [void](& $repairScript -Command rollback -CodexHome $f.Home -BackupRoot $f.Backups -ManifestPath $baseResult.ManifestPath)
    Assert-True ((Get-FileHash -LiteralPath $f.Path).Hash -ceq $baseHash) 'Materialized baseline rollback changed bytes.'
    [IO.File]::WriteAllBytes($f.Path,$forkBefore)
    [IO.File]::WriteAllBytes($f.Db,$forkDbBefore)
    foreach ($case in @('wrong-fork-parent', 'wrong-fork-filename', 'wrong-fork-ordinal', 'foreign-fork-event', 'unknown-fork-base')) {
        [IO.File]::WriteAllBytes($f.Path, $forkBefore)
        [IO.File]::WriteAllBytes($f.Db, $forkDbBefore)
        $records = @([IO.File]::ReadAllLines($f.Path) | ForEach-Object { $_ | ConvertFrom-Json })
        switch ($case) {
            'wrong-fork-parent' { $records[0].payload.forked_from_id = '55555555-5555-7555-8555-555555555555' }
            'wrong-fork-filename' { $records[0].payload.id = '55555555-5555-7555-8555-555555555555' }
            'wrong-fork-ordinal' { $records[1].ordinal = 0 }
            'foreign-fork-event' { $records[2].payload.thread_id = $parentId }
            'unknown-fork-base' { $records[0].payload | Add-Member -NotePropertyName history_base -NotePropertyValue @{thread_id=$parentId;end_ordinal_exclusive=20;end_byte_offset=1000} }
        }
        $lines = @($records | ForEach-Object { $_ | ConvertTo-Json -Depth 20 -Compress })
        [IO.File]::WriteAllText($f.Path, (($lines -join "`n") + "`n"), $utf8)
        [void](Invoke-Sql $f.Db "UPDATE thread_history_projection_state SET next_rollout_byte_offset=$((Get-Item -LiteralPath $f.Path).Length) WHERE thread_id='$childId';")
        $fileHash = (Get-FileHash -LiteralPath $f.Path).Hash
        $dbHash = (Get-FileHash -LiteralPath $f.Db).Hash
        $failed = $false
        try { [void](& $repairScript -Command repair -CodexHome $f.Home -BackupRoot $f.Backups) } catch { $failed = $true }
        Assert-True $failed "Unsafe fork accepted: $case"
        Assert-True ((Get-FileHash -LiteralPath $f.Path).Hash -ceq $fileHash) 'Rejected fork file changed.'
        Assert-True ((Get-FileHash -LiteralPath $f.Db).Hash -ceq $dbHash) 'Rejected fork database changed.'
    }

    foreach ($case in @("wrong-event", "missing-message", "wrong-turn", "wrong-cursor", "missing-tool-output", "unknown-web-kind", "wrong-web-id", "wrong-web-turn", "wrong-web-type")) {
        $f = New-Fixture $case
        switch ($case) {
            "wrong-event" { [void](Invoke-Sql $f.Db "UPDATE thread_items SET rollout_ordinal=0 WHERE item_id='rs_id_only';") }
            "missing-message" { [void](Invoke-Sql $f.Db "DELETE FROM thread_items WHERE item_id='item_message';") }
            "wrong-turn" { [void](Invoke-Sql $f.Db "UPDATE thread_items SET turn_id='wrong' WHERE item_id='rs_id_only';") }
            "wrong-cursor" { [void](Invoke-Sql $f.Db "UPDATE thread_history_projection_state SET next_rollout_ordinal=10;") }
            "unknown-web-kind" {
                $rows = [IO.File]::ReadAllLines($f.Path)
                $rows[8] = $rows[8].Replace('web.search', 'web.future')
                [IO.File]::WriteAllText($f.Path, (($rows -join "`n") + "`n"), $utf8)
            }
            "wrong-web-id" { [void](Invoke-Sql $f.Db "UPDATE thread_items SET item_id='wrong' WHERE item_id='exec_search';") }
            "wrong-web-turn" { [void](Invoke-Sql $f.Db "UPDATE thread_items SET turn_id='wrong' WHERE item_id='exec_search';") }
            "wrong-web-type" { [void](Invoke-Sql $f.Db "UPDATE thread_items SET item_type='sleep' WHERE item_id='exec_search';") }
            "missing-tool-output" {
                # Keep the call intact but break its matching output.
                $rows = [IO.File]::ReadAllLines($f.Path)
                $rows[6] = $rows[6].Replace('call_unchanged', 'call_different')
                [IO.File]::WriteAllText($f.Path, (($rows -join "`n") + "`n"), $utf8)
                [void](Invoke-Sql $f.Db "UPDATE thread_history_projection_state SET next_rollout_byte_offset=$((Get-Item -LiteralPath $f.Path).Length);")
            }
        }
        $fileHash = (Get-FileHash -LiteralPath $f.Path).Hash
        $dbHash = (Get-FileHash -LiteralPath $f.Db).Hash
        $failed = $false
        try { [void](& $repairScript -Command repair -CodexHome $f.Home -BackupRoot $f.Backups) }
        catch { $failed = $true }
        Assert-True $failed "Unsafe event projection was accepted: $case"
        Assert-True ((Get-FileHash -LiteralPath $f.Path).Hash -ceq $fileHash) "Refusal changed rollout: $case"
        Assert-True ((Get-FileHash -LiteralPath $f.Db).Hash -ceq $dbHash) "Refusal changed projection: $case"
    }
    Write-Host "Event-backed paginated history tests passed."
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolved = [IO.Path]::GetFullPath($testRoot)
        $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not $resolved.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe test cleanup path." }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
