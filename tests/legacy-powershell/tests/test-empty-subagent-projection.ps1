#requires -Version 5.1
[CmdletBinding()]
param([string[]]$Cases = @('valid', 'valid-crlf', 'valid-incremental', 'valid-interrupted',
    'valid-interrupted-crlf', 'valid-interrupted-incremental', 'regular-thread',
    'foreign-parent', 'foreign-settings', 'assistant-output', 'foreign-recipient',
    'unknown-event', 'unfinished-turn', 'missing-error', 'interrupted-wrong-reason',
    'interrupted-wrong-turn', 'interrupted-wrong-root', 'interrupted-status-mismatch', 'dangling-reference',
    'wrong-turn', 'wrong-end-offset', 'direct-model-ui', 'unknown-record'))
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot


Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repairScript = Join-Path $script:ProjectRoot 'codex-history-compat.ps1'
$utf8 = New-Object Text.UTF8Encoding($false)
$sqlite = (Get-Command sqlite3.exe -ErrorAction Stop).Source
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-empty-subagent-test-' + [Guid]::NewGuid().ToString('N'))
function Check([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Sql([string]$Path, [string]$Query) {
    $result = @($Query | & $sqlite -batch -bail -noheader $Path 2>&1)
    if ($LASTEXITCODE -ne 0) { throw ($result -join "`n") }
    return $result
}

try {
    foreach ($variant in $Cases) {
        $caseHome = Join-Path $testRoot $variant
        $archive = Join-Path $caseHome 'archived_sessions'
        [void][IO.Directory]::CreateDirectory($archive)
        $path = Join-Path $archive 'rollout.jsonl'
        # A native subagent can fail before producing any UI item. Its initial
        # prompt and incoming agent message still have optional model-input IDs.
        $records = @(
            @{ordinal=0;type='session_meta';payload=@{id='empty-child';session_id='parent';parent_thread_id='parent';
                thread_source='subagent';source=@{subagent=@{thread_spawn=@{parent_thread_id='parent';depth=1;agent_path='/root/child'}}};
                history_mode='paginated';model_provider='openai'}},
            @{ordinal=1;type='event_msg';payload=@{type='task_started';turn_id='turn';root_turn_id='root-turn'}},
            @{ordinal=2;type='response_item';payload=@{type='additional_tools';id='at_initial';role='developer';tools=@()}},
            @{ordinal=3;type='response_item';payload=@{type='message';id='msg_rules';role='developer';content=@(@{type='input_text';text='保留中文规则'})}},
            @{ordinal=4;type='response_item';payload=@{type='message';id='msg_prompt';role='user';content=@(@{type='input_text';text='保留原任务'})}},
            @{ordinal=5;type='world_state';payload=@{full=$true;state=@{}}},
            @{ordinal=6;type='turn_context';payload=@{turn_id='turn';root_turn_id='root-turn';model='fixture-model'}},
            @{ordinal=7;type='event_msg';payload=@{type='thread_settings_applied';thread_id='empty-child';thread_settings=@{model_provider_id='openai'}}},
            @{ordinal=8;type='inter_agent_communication_metadata';payload=@{trigger_turn=@{turn_id='turn'}}},
            @{ordinal=9;type='response_item';payload=@{type='agent_message';id='amsg_incoming';author='/root';recipient='/root/child';content=@(@{type='input_text';text='保留父任务消息'})}},
            @{ordinal=10;type='event_msg';payload=@{type='token_count';info=$null;rate_limits=$null}},
            @{ordinal=11;type='event_msg';payload=@{type='task_complete';turn_id='turn';root_turn_id='root-turn';last_agent_message=$null;error=@{message='synthetic failure'}}}
        )
        $isInterrupted = $variant -like '*interrupted*'
        $status = if ($isInterrupted) { 'interrupted' } elseif ($variant -eq 'unfinished-turn') { 'inProgress' } else { 'failed' }
        if ($isInterrupted) {
            $records[11].payload = @{type='turn_aborted';turn_id='turn';root_turn_id='root-turn';reason='interrupted'}
        }
        switch ($variant) {
            'regular-thread' { $records[0].payload.source='cli'; $records[0].payload.thread_source='cli' }
            'foreign-parent' { $records[0].payload.parent_thread_id='other-parent' }
            'foreign-settings' { $records[7].payload.thread_id='other-child' }
            'assistant-output' { $records[4].payload.role='assistant' }
            'foreign-recipient' { $records[9].payload.recipient='/root/other' }
            'unknown-event' { $records[10].payload.type='future_visual_event' }
            'unknown-record' { $records[5].type='future_history_record' }
            'missing-error' { $records[11].payload.error=$null }
            'wrong-turn' { $records[11].payload.turn_id='other-turn' }
            'interrupted-wrong-reason' { $records[11].payload.reason='user_cancelled' }
            'interrupted-wrong-turn' { $records[11].payload.turn_id='other-turn' }
            'interrupted-wrong-root' { $records[11].payload.root_turn_id='other-root' }
            'interrupted-status-mismatch' { $status='failed' }
        }
        $newline = if ($variant -like '*crlf') { "`r`n" } else { "`n" }
        $lines = @($records | ForEach-Object { $_ | ConvertTo-Json -Depth 25 -Compress })
        [IO.File]::WriteAllText($path, ([string]::Join($newline, [string[]]$lines) + $newline), $utf8)
        $length = (Get-Item -LiteralPath $path).Length
        $startOffset = $utf8.GetByteCount($lines[0] + $newline)
        $endOffset = if ($variant -eq 'wrong-end-offset') { $length - 1 } else { $length }
        $first = if ($variant -eq 'dangling-reference') { "'msg_prompt'" } else { 'NULL' }
        $db = Join-Path $caseHome 'thread_history_1.sqlite'
        [void](Sql $db @"
CREATE TABLE thread_history_projection_state(thread_id TEXT PRIMARY KEY,next_rollout_byte_offset INTEGER,next_rollout_ordinal INTEGER);
CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_id TEXT,rollout_ordinal INTEGER,created_at_ms INTEGER,item_json TEXT,item_type TEXT,updated_at_ordinal INTEGER);
CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,rollout_ordinal INTEGER,status TEXT,first_user_item_id TEXT,final_agent_item_id TEXT,rollout_byte_offset INTEGER,rollout_end_ordinal INTEGER,rollout_end_byte_offset INTEGER,root_turn_id TEXT);
INSERT INTO thread_history_projection_state VALUES('empty-child',$length,12);
INSERT INTO thread_turns VALUES('empty-child','turn',1,'$status',$first,NULL,$startOffset,11,$endOffset,'root-turn');
INSERT INTO thread_items VALUES('unrelated','turn','keep',3,100,'{"id":"keep","type":"agentMessage"}','agentMessage',3);
"@)
        if ($variant -eq 'direct-model-ui') {
            [void](Sql $db @'
INSERT INTO thread_items VALUES('empty-child','turn','msg_prompt',4,100,'{"id":"msg_prompt","type":"userMessage"}','userMessage',4);
'@)
        }
        $before = [IO.File]::ReadAllBytes($path)
        $beforeDb = (Get-FileHash -LiteralPath $db).Hash
        $backups = Join-Path $caseHome 'backups'
        $failed = $false
        $failure = ''
        $result = $null
        try {
            $result = & $repairScript -Command repair -CodexHome $caseHome -BackupRoot $backups -PortableInputIds -Incremental:($variant -like '*incremental')
        } catch { $failed = $true; $failure = $_.Exception.Message }
        if ($variant -like 'valid*') {
            Check (-not $failed) ("Native terminal subagent was refused ($variant): $failure")
            Check ($result.RepairedFiles -eq 1 -and $result.RepairedDatabases -eq 0) 'Repair scope is not model-only.'
            $afterLines = [IO.File]::ReadAllLines($path)
            Check ($afterLines.Count -eq $lines.Count) 'The record count changed.'
            for ($i=0; $i -lt $lines.Count; $i++) {
                $expected = if ($records[$i].type -eq 'response_item') { [CodexHistoryCompat.PortableHistory]::Clear($lines[$i]) } else { $lines[$i] }
                Check ($afterLines[$i] -ceq $expected) "A non-ID field changed at line $i."
                Check ($utf8.GetByteCount($afterLines[$i]) -eq $utf8.GetByteCount($lines[$i])) 'A byte boundary changed.'
            }
            $again = & $repairScript -Command repair -CodexHome $caseHome -BackupRoot $backups -PortableInputIds -Incremental:($variant -like '*incremental')
            Check ($again.AffectedFiles -eq 0) 'Repeated preparation changed the clean file.'
            [void](& $repairScript -Command rollback -CodexHome $caseHome -BackupRoot $backups -ManifestPath $result.ManifestPath)
        } else {
            Check $failed "Unverified empty projection was accepted: $variant"
        }
        Check ((Get-FileHash -LiteralPath $db).Hash -ceq $beforeDb) "UI database changed: $variant"
        Check ([Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -ceq [Convert]::ToBase64String($before)) "Refusal/rollback changed history: $variant"
    }
    Write-Host ("Empty-subagent projection tests passed: {0} cases." -f $Cases.Count)
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -match '^codex-empty-subagent-test-[0-9a-f]{32}$' -and
        [IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
