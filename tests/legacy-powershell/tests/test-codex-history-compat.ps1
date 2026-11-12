#requires -Version 5.1

[CmdletBinding()]
param()
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot


Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repairScript = Join-Path $script:ProjectRoot "codex-history-compat.ps1"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-history-compat-test-" + [Guid]::NewGuid().ToString("N"))
$utf8 = New-Object System.Text.UTF8Encoding($false)
$sqliteCommand = Get-Command sqlite3.exe -ErrorAction SilentlyContinue
if ($null -eq $sqliteCommand) {
    $sqliteCommand = Get-Command sqlite3 -ErrorAction SilentlyContinue
}
if ($null -eq $sqliteCommand) {
    throw "History compatibility tests require sqlite3.exe."
}
$sqliteExecutable = [string]$sqliteCommand.Source

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Write-Jsonl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object[]]$Records
    )

    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    $lines = @($Records | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 20 })
    [IO.File]::WriteAllText($Path, ([string]::Join("`n", $lines) + "`n"), $utf8)
}

function Get-LineStartOffsets {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $offsets = New-Object System.Collections.Generic.List[long]
    $offsets.Add(0L)
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        if ($bytes[$index] -eq 10 -and ($index + 1) -lt $bytes.Length) {
            $offsets.Add([long]($index + 1))
        }
    }
    return $offsets.ToArray()
}

function New-TestHome {
    param([Parameter(Mandatory = $true)][string]$Name)

    $testCodexHome = Join-Path $tempRoot $Name
    [IO.Directory]::CreateDirectory($testCodexHome) | Out-Null
    return $testCodexHome
}

function Invoke-TestSqlite {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Sql,
        [switch]$ReadOnly
    )

    $arguments = @("-batch", "-bail", "-noheader", "-cmd", ".timeout 5000")
    if ($ReadOnly) {
        $arguments = @("-readonly") + $arguments
    }
    # Windows PowerShell 5.1 strips nested JSON quotes in native arguments.
    # Use stdin, as the production SQLite writer does.
    $output = $Sql | & $sqliteExecutable @arguments $Path 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Test SQLite command failed: $($output -join '; ')"
    }
    return @($output | ForEach-Object { [string]$_ })
}

try {
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null

    $testCodexHome = New-TestHome "success"
    $rollout = Join-Path $testCodexHome "sessions\2026\07\30\rollout-test.jsonl"
    $records = @(
        [ordered]@{
            timestamp = "2026-07-30T00:00:00Z"
            type = "session_meta"
            payload = [ordered]@{ id = "thread-test"; model_provider = "legacy-relay" }
        },
        [ordered]@{
            timestamp = "2026-07-30T00:00:00.500Z"
            type = "event_msg"
            payload = [ordered]@{
                type = "thread_settings_applied"
                thread_settings = [ordered]@{ model_provider_id = "relay"; model = "test-model" }
            }
        },
        [ordered]@{
            timestamp = "2026-07-30T00:00:01Z"
            type = "response_item"
            payload = [ordered]@{
                type = "reasoning"
                id = "rs_valid"
                summary = @()
                content = $null
                encrypted_content = "official-encrypted-content"
            }
        },
        [ordered]@{
            timestamp = "2026-07-30T00:00:02Z"
            type = "response_item"
            payload = [ordered]@{
                type = "reasoning"
                id = "item_drop_reasoning"
                summary = @([ordered]@{ type = "summary_text"; text = "relay summary" })
                content = $null
                encrypted_content = $null
            }
        },
        [ordered]@{
            timestamp = "2026-07-30T00:00:03Z"
            type = "event_msg"
            payload = [ordered]@{ type = "agent_reasoning"; text = "visible reasoning event remains" }
        },
        [ordered]@{
            timestamp = "2026-07-30T00:00:04Z"
            type = "response_item"
            payload = [ordered]@{
                type = "message"
                id = "item_message"
                role = "assistant"
                content = @([ordered]@{ type = "output_text"; text = "kept message" })
            }
        },
        [ordered]@{
            timestamp = "2026-07-30T00:00:05Z"
            type = "response_item"
            payload = [ordered]@{
                type = "function_call"
                id = "item_function"
                name = "shell_command"
                arguments = "{}"
                call_id = "call-function"
            }
        },
        [ordered]@{
            timestamp = "2026-07-30T00:00:06Z"
            type = "response_item"
            payload = [ordered]@{
                type = "function_call_output"
                id = "fco_valid"
                call_id = "call-function"
                output = "ok"
            }
        },
        [ordered]@{
            timestamp = "2026-07-30T00:00:07Z"
            type = "response_item"
            payload = [ordered]@{
                type = "custom_tool_call"
                id = "item_custom"
                status = "completed"
                call_id = "call-custom"
                name = "image"
                input = "{}"
            }
        },
        [ordered]@{
            timestamp = "2026-07-30T00:00:08Z"
            type = "response_item"
            payload = [ordered]@{
                type = "custom_tool_call_output"
                id = "ctco_valid"
                call_id = "call-custom"
                output = "ok"
            }
        },
        [ordered]@{
            timestamp = "2026-07-30T00:00:09Z"
            type = "response_item"
            payload = [ordered]@{
                type = "tool_search_call"
                id = "item_search"
                call_id = "call-search"
                status = "completed"
                execution = "search"
                arguments = [ordered]@{ query = "test" }
            }
        },
        [ordered]@{
            timestamp = "2026-07-30T00:00:10Z"
            type = "response_item"
            payload = [ordered]@{
                type = "reasoning"
                id = "item_encrypted_reasoning"
                summary = @()
                content = $null
                encrypted_content = "relay-preserved-encrypted-content"
            }
        }
    )
    Write-Jsonl -Path $rollout -Records $records
    $archivedRollout = Join-Path $testCodexHome "archived_sessions\rollout-archived.jsonl"
    Write-Jsonl -Path $archivedRollout -Records @(
        [ordered]@{
            timestamp = "2026-07-01T00:00:00Z"
            type = "session_meta"
            payload = [ordered]@{ id = "thread-archived"; model_provider = "old-api" }
        },
        [ordered]@{
            timestamp = "2026-07-01T00:00:01Z"
            type = "response_item"
            payload = [ordered]@{
                type = "message"
                id = "msg_archived"
                role = "assistant"
                content = @([ordered]@{ type = "output_text"; text = "archived" })
            }
        }
    )
    $databasePaths = @(
        (Join-Path $testCodexHome "state_5.sqlite"),
        (Join-Path $testCodexHome "sqlite\state_5.sqlite")
    )
    [IO.Directory]::CreateDirectory((Split-Path -Parent $databasePaths[1])) | Out-Null
    [void](Invoke-TestSqlite -Path $databasePaths[0] -Sql @'
PRAGMA journal_mode=WAL;
CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT NOT NULL);
INSERT INTO threads(id, model_provider) VALUES('thread-test', 'legacy-relay');
INSERT INTO threads(id, model_provider) VALUES('thread-archived', 'old-api');
INSERT INTO threads(id, model_provider) VALUES('cloud-thread', 'cloud-provider');
'@)
    [void](Invoke-TestSqlite -Path $databasePaths[1] -Sql @'
PRAGMA journal_mode=WAL;
CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT NOT NULL);
INSERT INTO threads(id, model_provider) VALUES('thread-test', 'relay');
INSERT INTO threads(id, model_provider) VALUES('thread-archived', 'custom');
INSERT INTO threads(id, model_provider) VALUES('cloud-thread', 'cloud-provider');
'@)
    $originalBytes = [IO.File]::ReadAllBytes($rollout)
    $archivedOriginalBytes = [IO.File]::ReadAllBytes($archivedRollout)
    $backupRoot = Join-Path $tempRoot "success-backups"

    $scan = & $repairScript -Command scan -CodexHome $testCodexHome -BackupRoot $backupRoot
    Assert-True ($scan.FilesScanned -eq 2) "Scan did not inspect active and archived rollouts."
    Assert-True ($scan.AffectedFiles -eq 2) "Scan did not find both affected rollouts."
    Assert-True ($scan.Renames -eq 5) "Scan found the wrong rename count."
    Assert-True ($scan.Drops -eq 1) "Scan found the wrong drop count."
    Assert-True ($scan.ProviderFileChanges -eq 3) "Scan found the wrong JSONL provider change count."
    Assert-True ($scan.ProviderDatabaseChanges -eq 4) "Scan found the wrong SQLite provider change count."
    Assert-True ($scan.DatabasesScanned -eq 2) "Scan did not inspect both state databases."
    Assert-True ($scan.Unsupported -eq 0) "Scan unexpectedly found unsupported records."

    $repair = & $repairScript -Command repair -CodexHome $testCodexHome -BackupRoot $backupRoot
    Assert-True ($repair.RepairedFiles -eq 2) "Repair did not report both repaired rollouts."
    Assert-True ($repair.RepairedDatabases -eq 2) "Repair did not report both repaired SQLite databases."
    Assert-True (Test-Path -LiteralPath $repair.ManifestPath) "Repair manifest was not created."

    $repairedText = [IO.File]::ReadAllText($rollout, $utf8)
    Assert-True (-not $repairedText.Contains('"id":"item_')) "Generic response item IDs remain after repair."
    Assert-True (-not $repairedText.Contains("item_drop_reasoning")) "Unusable relay reasoning record was not removed."
    Assert-True ($repairedText.Contains("visible reasoning event remains")) "Visible reasoning event was removed."
    Assert-True ($repairedText.Contains('"id":"msg_message"')) "Message ID was not normalized."
    Assert-True ($repairedText.Contains('"id":"fc_function"')) "Function-call ID was not normalized."
    Assert-True ($repairedText.Contains('"id":"ctc_custom"')) "Custom-tool ID was not normalized."
    Assert-True ($repairedText.Contains('"id":"tsc_search"')) "Tool-search ID was not normalized."
    Assert-True ($repairedText.Contains('"id":"rs_encrypted_reasoning"')) "Encrypted reasoning ID was not normalized."
    Assert-True ($repairedText.Contains('"call_id":"call-function"')) "Function call pairing was damaged."
    Assert-True ($repairedText.Contains('"call_id":"call-custom"')) "Custom tool pairing was damaged."
    Assert-True ($repairedText.Contains('"model_provider":"openai"')) "Session provider was not normalized."
    Assert-True ($repairedText.Contains('"model_provider_id":"openai"')) "Thread-settings provider was not normalized."
    Assert-True ([IO.File]::ReadAllText($archivedRollout, $utf8).Contains('"model_provider":"openai"')) "Archived session provider was not normalized."
    foreach ($databasePath in $databasePaths) {
        $localProvider = @(Invoke-TestSqlite -Path $databasePath -ReadOnly -Sql "SELECT model_provider FROM threads WHERE id='thread-test';")[0]
        $archivedProvider = @(Invoke-TestSqlite -Path $databasePath -ReadOnly -Sql "SELECT model_provider FROM threads WHERE id='thread-archived';")[0]
        $cloudProvider = @(Invoke-TestSqlite -Path $databasePath -ReadOnly -Sql "SELECT model_provider FROM threads WHERE id='cloud-thread';")[0]
        Assert-True ($localProvider -ceq "openai") "Local SQLite provider was not normalized."
        Assert-True ($archivedProvider -ceq "openai") "Archived SQLite provider was not normalized."
        Assert-True ($cloudProvider -ceq "cloud-provider") "Out-of-scope cloud SQLite row was changed."
    }

    [void](& $repairScript -Command rollback -CodexHome $testCodexHome -BackupRoot $backupRoot -ManifestPath $repair.ManifestPath)
    $restoredBytes = [IO.File]::ReadAllBytes($rollout)
    Assert-True (
        [Convert]::ToBase64String($restoredBytes) -ceq [Convert]::ToBase64String($originalBytes)
    ) "Rollback did not restore the exact original rollout bytes."
    Assert-True (
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($archivedRollout)) -ceq
        [Convert]::ToBase64String($archivedOriginalBytes)
    ) "Rollback did not restore the exact archived rollout bytes."
    Assert-True (@(Invoke-TestSqlite -Path $databasePaths[0] -ReadOnly -Sql "SELECT model_provider FROM threads WHERE id='thread-test';")[0] -ceq "legacy-relay") "Root SQLite provider rollback failed."
    Assert-True (@(Invoke-TestSqlite -Path $databasePaths[1] -ReadOnly -Sql "SELECT model_provider FROM threads WHERE id='thread-test';")[0] -ceq "relay") "Legacy SQLite provider rollback failed."
    Assert-True (@(Invoke-TestSqlite -Path $databasePaths[0] -ReadOnly -Sql "SELECT model_provider FROM threads WHERE id='thread-archived';")[0] -ceq "old-api") "Root archived SQLite provider rollback failed."
    Assert-True (@(Invoke-TestSqlite -Path $databasePaths[1] -ReadOnly -Sql "SELECT model_provider FROM threads WHERE id='thread-archived';")[0] -ceq "custom") "Legacy archived SQLite provider rollback failed."
    foreach ($databasePath in $databasePaths) {
        Assert-True (@(Invoke-TestSqlite -Path $databasePath -ReadOnly -Sql "SELECT model_provider FROM threads WHERE id='cloud-thread';")[0] -ceq "cloud-provider") "Cloud SQLite row changed during rollback."
    }

    # Regression: an already-prefixed 79-character relay ID escaped the old
    # item_-only scanner and poisoned every subsequent official request.
    $longIdHome = New-TestHome "long-id"
    $longIdRollout = Join-Path $longIdHome "sessions\rollout-long-id.jsonl"
    $longReasoningId = "rs_resp_" + ("a" * 36) + "_" + ("b" * 32) + "_0"
    Write-Jsonl -Path $longIdRollout -Records @(
        [ordered]@{ type = "event_msg"; payload = [ordered]@{
            type = "item_completed"; item = [ordered]@{ type = "Reasoning"; id = $longReasoningId; summary_text = @("keep visible history") }
        } },
        [ordered]@{ type = "response_item"; payload = [ordered]@{
            type = "reasoning"; id = $longReasoningId; summary = @(); content = $null; encrypted_content = $null
        } },
        [ordered]@{ type = "response_item"; payload = [ordered]@{
            type = "reasoning"; id = "rs_id_only"; summary = @([ordered]@{ type = "summary_text"; text = ([string][char]0x200B) }); content = $null; encrypted_content = $null
        } },
        [ordered]@{ type = "response_item"; payload = [ordered]@{
            type = "reasoning"; id = "rs_official"; summary = @(); content = $null; encrypted_content = "preserve-encrypted-content"
        } },
        [ordered]@{ type = "response_item"; payload = [ordered]@{
            type = "custom_tool_call"; id = "ctc_existing"; call_id = "call-keep"; name = "test"; input = "{}"
        } },
        [ordered]@{ type = "response_item"; payload = [ordered]@{
            type = "custom_tool_call_output"; id = "ctco_existing"; call_id = "call-keep"; output = "keep result"
        } },
        [ordered]@{ type = "response_item"; payload = [ordered]@{
            type = "message"; id = ("msg_" + ("x" * 60)); role = "assistant"; content = @()
        } }
    )
    $longIdBefore = [IO.File]::ReadAllBytes($longIdRollout)
    $longScan = & $repairScript -Command scan -CodexHome $longIdHome -BackupRoot (Join-Path $tempRoot "long-id-backups")
    Assert-True ($longReasoningId.Length -eq 79 -and $longScan.Drops -eq 2 -and $longScan.Unsupported -eq 0) "Unreplayable reasoning items were not detected regardless of ID prefix or length."
    $longRepair = & $repairScript -Command repair -CodexHome $longIdHome -BackupRoot (Join-Path $tempRoot "long-id-backups")
    $longRecords = @([IO.File]::ReadAllLines($longIdRollout) | ForEach-Object { $_ | ConvertFrom-Json })
    Assert-True ($longRecords.Count -eq 5) "Repair removed more than the two unusable model inputs."
    Assert-True ($longRecords[0].payload.item.id -ceq $longReasoningId) "Visible history event was changed."
    Assert-True ($longRecords[1].payload.encrypted_content -ceq "preserve-encrypted-content") "Official reasoning was changed."
    Assert-True ($longRecords[2].payload.call_id -ceq $longRecords[3].payload.call_id) "Tool call pairing was changed."
    Assert-True ($longRecords[4].payload.id.Length -eq 64) "A valid 64-character ID was changed."
    $secondScan = & $repairScript -Command scan -CodexHome $longIdHome -BackupRoot (Join-Path $tempRoot "long-id-backups")
    Assert-True ($secondScan.AffectedFiles -eq 0) "Long-ID repair was not idempotent."
    [void](& $repairScript -Command rollback -CodexHome $longIdHome -ManifestPath $longRepair.ManifestPath)
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($longIdRollout)) -ceq [Convert]::ToBase64String($longIdBefore)) "Long-ID rollback did not restore exact bytes."

    foreach ($case in @(
        @{ Name = "long-message"; Type = "message"; Id = ("msg_" + ("x" * 61)); Encrypted = $null },
        @{ Name = "long-encrypted"; Type = "reasoning"; Id = $longReasoningId; Encrypted = "preserve" },
        @{ Name = "long-generic"; Type = "message"; Id = ("item_" + ("x" * 70)); Encrypted = $null }
    )) {
        $caseHome = New-TestHome $case.Name
        $caseRollout = Join-Path $caseHome "sessions\rollout.jsonl"
        Write-Jsonl -Path $caseRollout -Records @([ordered]@{ type = "response_item"; payload = [ordered]@{
            type = $case.Type; id = $case.Id; content = $null; encrypted_content = $case.Encrypted
        } })
        $caseBefore = [IO.File]::ReadAllBytes($caseRollout)
        $caseScan = & $repairScript -Command scan -CodexHome $caseHome -BackupRoot (Join-Path $tempRoot ($case.Name + "-backups"))
        Assert-True ($caseScan.Unsupported -eq 1) "Unsafe oversized ID was not reported: $($case.Name)"
        $failed = $false
        try { [void](& $repairScript -Command repair -CodexHome $caseHome -BackupRoot (Join-Path $tempRoot ($case.Name + "-backups"))) }
        catch { $failed = $true }
        Assert-True $failed "Unsafe oversized ID was silently rewritten: $($case.Name)"
        Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($caseRollout)) -ceq [Convert]::ToBase64String($caseBefore)) "Refused repair changed original bytes: $($case.Name)"
    }

    # Paginated history uses byte offsets and ordinals as an index. Safe repairs
    # must keep every line's byte size unchanged and update thread_items in the
    # same transaction; rollback must restore both the journal and projection.
    $paginatedHome = New-TestHome "paginated"
    $paginatedRollout = Join-Path $paginatedHome "sessions\rollout.jsonl"
    $paginatedRecords = @(
        [ordered]@{ ordinal = 1; type = "session_meta"; payload = [ordered]@{ id = "paged-thread"; model_provider = "openai"; history_mode = "paginated" } },
        [ordered]@{ ordinal = 2; type = "response_item"; payload = [ordered]@{ type = "reasoning"; id = $longReasoningId; content = $null; encrypted_content = $null } },
        [ordered]@{ ordinal = 3; type = "response_item"; payload = [ordered]@{ type = "message"; id = "item_message"; role = "assistant"; content = @() } },
        [ordered]@{ ordinal = 4; type = "response_item"; payload = [ordered]@{ type = "function_call"; id = "item_call"; name = "test"; arguments = "{}" } }
    )
    Write-Jsonl -Path $paginatedRollout -Records $paginatedRecords
    $paginatedDb = Join-Path $paginatedHome "thread_history_1.sqlite"
    $dropJson = $paginatedRecords[1].payload | ConvertTo-Json -Compress -Depth 20
    $renameJson = $paginatedRecords[2].payload | ConvertTo-Json -Compress -Depth 20
    $renameJson2 = $paginatedRecords[3].payload | ConvertTo-Json -Compress -Depth 20
    $paginatedLength = ([IO.File]::ReadAllBytes($paginatedRollout)).Length
    $paginatedOffsetsBefore = Get-LineStartOffsets $paginatedRollout
    $paginatedSql = @"
CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT NOT NULL);
CREATE TABLE thread_history_projection_state (thread_id TEXT PRIMARY KEY, next_rollout_byte_offset INTEGER NOT NULL, next_rollout_ordinal INTEGER NOT NULL);
CREATE TABLE thread_items (thread_id TEXT NOT NULL, turn_id TEXT NOT NULL, item_id TEXT NOT NULL, rollout_ordinal INTEGER NOT NULL, created_at_ms INTEGER NOT NULL, item_json TEXT NOT NULL, item_type TEXT NOT NULL, updated_at_ordinal INTEGER NOT NULL, PRIMARY KEY(thread_id,turn_id,item_id));
CREATE TABLE thread_turns (thread_id TEXT NOT NULL, turn_id TEXT NOT NULL, rollout_ordinal INTEGER NOT NULL, status TEXT NOT NULL, first_user_item_id TEXT, final_agent_item_id TEXT, PRIMARY KEY(thread_id,turn_id));
INSERT INTO threads VALUES ('paged-thread','legacy-relay');
INSERT INTO threads VALUES ('unrelated-thread','legacy-relay');
INSERT INTO thread_history_projection_state VALUES ('paged-thread',$paginatedLength,5);
INSERT INTO thread_items VALUES ('paged-thread','turn-1','$longReasoningId',2,1000,'$($dropJson.Replace("'", "''"))','reasoning',2);
INSERT INTO thread_items VALUES ('paged-thread','turn-1','item_message',3,1001,'$($renameJson.Replace("'", "''"))','message',3);
INSERT INTO thread_items VALUES ('paged-thread','turn-1','item_call',4,1002,'$($renameJson2.Replace("'", "''"))','function_call',4);
INSERT INTO thread_turns VALUES ('paged-thread','turn-1',1,'completed','item_message','item_call');
"@
    [void](Invoke-TestSqlite -Path $paginatedDb -Sql $paginatedSql)
    $paginatedBefore = [IO.File]::ReadAllBytes($paginatedRollout)
    $paginatedDbBefore = @(Invoke-TestSqlite -Path $paginatedDb -ReadOnly -Sql "SELECT rollout_ordinal||':'||item_id||':'||item_json FROM thread_items ORDER BY rollout_ordinal;")
    $paginatedScan = & $repairScript -Command scan -CodexHome $paginatedHome -BackupRoot (Join-Path $tempRoot "paginated-backups")
    Assert-True ($paginatedScan.Unsupported -eq 0 -and $paginatedScan.Drops -eq 1 -and $paginatedScan.Renames -eq 2) "Paginated safe changes were not recognized."
    $paginatedRepair = & $repairScript -Command repair -CodexHome $paginatedHome -BackupRoot (Join-Path $tempRoot "paginated-backups")
    Assert-True ($paginatedRepair.RepairedFiles -eq 1 -and $paginatedRepair.RepairedDatabases -eq 1) "Paginated transaction did not include both journal and projection."
    Assert-True (@(Invoke-TestSqlite -Path $paginatedDb -ReadOnly -Sql "SELECT model_provider FROM threads WHERE id='paged-thread';")[0] -ceq "openai") "Paginated thread provider was not included in the merged database entry."
    Assert-True (@(Invoke-TestSqlite -Path $paginatedDb -ReadOnly -Sql "SELECT model_provider FROM threads WHERE id='unrelated-thread';")[0] -ceq "legacy-relay") "Unrelated thread provider was modified."
    Assert-True (([IO.File]::ReadAllBytes($paginatedRollout)).Length -eq $paginatedLength) "Paginated repair changed the journal byte length."
    $paginatedOffsetsAfter = Get-LineStartOffsets $paginatedRollout
    Assert-True ([string]::Join(",", $paginatedOffsetsAfter) -ceq [string]::Join(",", $paginatedOffsetsBefore)) "Paginated repair changed line byte offsets."
    $paginatedLines = [IO.File]::ReadAllLines($paginatedRollout)
    Assert-True ($paginatedLines[1] -match 'token_count' -and $paginatedLines[1] -match '"ordinal"\s*:\s*2') "Dropped paginated item did not preserve its indexed slot."
    Assert-True ($paginatedLines[2] -match '"id"\s*:\s*"msg_message"' -and $paginatedLines[2] -match '"ordinal"\s*:\s*3') "Paginated rename did not preserve its indexed slot."
    Assert-True ($paginatedLines[3] -match '"id"\s*:\s*"fc_call"' -and $paginatedLines[3] -match '"ordinal"\s*:\s*4') "Second paginated rename did not preserve its indexed slot."
    Assert-True (@(Invoke-TestSqlite -Path $paginatedDb -ReadOnly -Sql "SELECT COUNT(*) FROM thread_items WHERE rollout_ordinal=2;")[0] -eq "0") "Dropped paginated projection row remains."
    Assert-True (@(Invoke-TestSqlite -Path $paginatedDb -ReadOnly -Sql "SELECT item_id FROM thread_items WHERE rollout_ordinal=3;")[0] -ceq "msg_message") "Renamed paginated projection row was not updated."
    Assert-True (@(Invoke-TestSqlite -Path $paginatedDb -ReadOnly -Sql "SELECT item_id FROM thread_items WHERE rollout_ordinal=4;")[0] -ceq "fc_call") "Second renamed paginated projection row was not updated."
    $turnAfterRepair = @(Invoke-TestSqlite -Path $paginatedDb -ReadOnly -Sql "SELECT first_user_item_id||':'||final_agent_item_id FROM thread_turns WHERE thread_id='paged-thread' AND turn_id='turn-1';")[0]
    Assert-True ($turnAfterRepair -ceq "msg_message:fc_call") "Renamed paginated thread_turns references were not updated together."
    [void](& $repairScript -Command rollback -CodexHome $paginatedHome -ManifestPath $paginatedRepair.ManifestPath)
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($paginatedRollout)) -ceq [Convert]::ToBase64String($paginatedBefore)) "Paginated rollback did not restore exact journal bytes."
    Assert-True (@(Invoke-TestSqlite -Path $paginatedDb -ReadOnly -Sql "SELECT model_provider FROM threads WHERE id='paged-thread';")[0] -ceq "legacy-relay") "Paginated rollback did not restore the provider row."
    Assert-True (@(Invoke-TestSqlite -Path $paginatedDb -ReadOnly -Sql "SELECT model_provider FROM threads WHERE id='unrelated-thread';")[0] -ceq "legacy-relay") "Paginated rollback changed an unrelated provider row."
    $paginatedDbAfterRollback = @(Invoke-TestSqlite -Path $paginatedDb -ReadOnly -Sql "SELECT rollout_ordinal||':'||item_id||':'||item_json FROM thread_items ORDER BY rollout_ordinal;")
    Assert-True ([string]::Join("`n", $paginatedDbAfterRollback) -ceq [string]::Join("`n", $paginatedDbBefore)) "Paginated rollback did not restore projection rows."
    Assert-True (@(Invoke-TestSqlite -Path $paginatedDb -ReadOnly -Sql "SELECT first_user_item_id||':'||final_agent_item_id FROM thread_turns WHERE thread_id='paged-thread' AND turn_id='turn-1';")[0] -ceq "item_message:item_call") "Paginated rollback did not restore the thread_turns references."
    [void](& $repairScript -Command rollback -CodexHome $paginatedHome -ManifestPath $paginatedRepair.ManifestPath)

    # A missing projection row must refuse the repair before touching the journal.
    $paginatedMismatchHome = New-TestHome "paginated-mismatch"
    $paginatedMismatchRollout = Join-Path $paginatedMismatchHome "sessions\rollout.jsonl"
    Write-Jsonl -Path $paginatedMismatchRollout -Records @(
        [ordered]@{ ordinal = 1; type = "session_meta"; payload = [ordered]@{ id = "paged-mismatch"; model_provider = "openai"; history_mode = "paginated" } },
        [ordered]@{ ordinal = 2; type = "response_item"; payload = [ordered]@{ type = "reasoning"; id = $longReasoningId; content = $null; encrypted_content = $null } }
    )
    $paginatedMismatchDb = Join-Path $paginatedMismatchHome "thread_history_1.sqlite"
    $mismatchLength = ([IO.File]::ReadAllBytes($paginatedMismatchRollout)).Length
    [void](Invoke-TestSqlite -Path $paginatedMismatchDb -Sql @"
CREATE TABLE thread_history_projection_state (thread_id TEXT PRIMARY KEY, next_rollout_byte_offset INTEGER NOT NULL, next_rollout_ordinal INTEGER NOT NULL);
CREATE TABLE thread_items (thread_id TEXT NOT NULL, turn_id TEXT NOT NULL, item_id TEXT NOT NULL, rollout_ordinal INTEGER NOT NULL, created_at_ms INTEGER NOT NULL, item_json TEXT NOT NULL, item_type TEXT NOT NULL, updated_at_ordinal INTEGER NOT NULL, PRIMARY KEY(thread_id,turn_id,item_id));
INSERT INTO thread_history_projection_state VALUES ('paged-mismatch',$mismatchLength,3);
"@)
    $mismatchBefore = [IO.File]::ReadAllBytes($paginatedMismatchRollout)
    $failed = $false
    try { [void](& $repairScript -Command repair -CodexHome $paginatedMismatchHome -BackupRoot (Join-Path $tempRoot "paginated-mismatch-backups")) }
    catch { $failed = $true }
    Assert-True $failed "Paginated projection mismatch was not refused."
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($paginatedMismatchRollout)) -ceq [Convert]::ToBase64String($mismatchBefore)) "Projection mismatch changed the journal."

    # A dropped item referenced by thread_turns must be refused before any
    # JSONL or projection write, because deleting it would leave a dangling
    # turn endpoint.
    $paginatedReferencedDropHome = New-TestHome "paginated-referenced-drop"
    $paginatedReferencedDropRollout = Join-Path $paginatedReferencedDropHome "sessions\rollout.jsonl"
    Write-Jsonl -Path $paginatedReferencedDropRollout -Records $paginatedRecords
    $paginatedReferencedDropDb = Join-Path $paginatedReferencedDropHome "thread_history_1.sqlite"
    $referencedDropLength = ([IO.File]::ReadAllBytes($paginatedReferencedDropRollout)).Length
    [void](Invoke-TestSqlite -Path $paginatedReferencedDropDb -Sql @"
CREATE TABLE thread_history_projection_state (thread_id TEXT PRIMARY KEY, next_rollout_byte_offset INTEGER NOT NULL, next_rollout_ordinal INTEGER NOT NULL);
CREATE TABLE thread_items (thread_id TEXT NOT NULL, turn_id TEXT NOT NULL, item_id TEXT NOT NULL, rollout_ordinal INTEGER NOT NULL, created_at_ms INTEGER NOT NULL, item_json TEXT NOT NULL, item_type TEXT NOT NULL, updated_at_ordinal INTEGER NOT NULL, PRIMARY KEY(thread_id,turn_id,item_id));
CREATE TABLE thread_turns (thread_id TEXT NOT NULL, turn_id TEXT NOT NULL, rollout_ordinal INTEGER NOT NULL, status TEXT NOT NULL, first_user_item_id TEXT, final_agent_item_id TEXT, PRIMARY KEY(thread_id,turn_id));
INSERT INTO thread_history_projection_state VALUES ('paged-thread',$referencedDropLength,5);
INSERT INTO thread_items VALUES ('paged-thread','turn-1','$longReasoningId',2,1000,'$($dropJson.Replace("'", "''"))','reasoning',2);
INSERT INTO thread_items VALUES ('paged-thread','turn-1','item_message',3,1001,'$($renameJson.Replace("'", "''"))','message',3);
INSERT INTO thread_items VALUES ('paged-thread','turn-1','item_call',4,1002,'$($renameJson2.Replace("'", "''"))','function_call',4);
INSERT INTO thread_turns VALUES ('paged-thread','turn-1',1,'completed','$longReasoningId','item_call');
"@)
    $referencedDropBefore = [IO.File]::ReadAllBytes($paginatedReferencedDropRollout)
    $failed = $false
    try { [void](& $repairScript -Command repair -CodexHome $paginatedReferencedDropHome -BackupRoot (Join-Path $tempRoot "paginated-referenced-drop-backups")) }
    catch { $failed = $true }
    Assert-True $failed "Referenced paginated drop was not refused."
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($paginatedReferencedDropRollout)) -ceq [Convert]::ToBase64String($referencedDropBefore)) "Referenced drop refusal changed the journal."
    Assert-True (@(Invoke-TestSqlite -Path $paginatedReferencedDropDb -ReadOnly -Sql "SELECT first_user_item_id||':'||final_agent_item_id FROM thread_turns WHERE thread_id='paged-thread' AND turn_id='turn-1';")[0] -ceq ($longReasoningId + ":item_call")) "Referenced drop refusal changed thread_turns."

    # Exercise failure after the journal replacement: the transaction must
    # restore both the file and projection rows.
    $paginatedFailureHome = New-TestHome "paginated-failure"
    $paginatedFailureRollout = Join-Path $paginatedFailureHome "sessions\rollout.jsonl"
    Write-Jsonl -Path $paginatedFailureRollout -Records $paginatedRecords
    $paginatedFailureDb = Join-Path $paginatedFailureHome "thread_history_1.sqlite"
    $failureLength = ([IO.File]::ReadAllBytes($paginatedFailureRollout)).Length
    [void](Invoke-TestSqlite -Path $paginatedFailureDb -Sql @"
CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT NOT NULL);
CREATE TABLE thread_history_projection_state (thread_id TEXT PRIMARY KEY, next_rollout_byte_offset INTEGER NOT NULL, next_rollout_ordinal INTEGER NOT NULL);
CREATE TABLE thread_items (thread_id TEXT NOT NULL, turn_id TEXT NOT NULL, item_id TEXT NOT NULL, rollout_ordinal INTEGER NOT NULL, created_at_ms INTEGER NOT NULL, item_json TEXT NOT NULL, item_type TEXT NOT NULL, updated_at_ordinal INTEGER NOT NULL, PRIMARY KEY(thread_id,turn_id,item_id));
CREATE TABLE thread_turns (thread_id TEXT NOT NULL, turn_id TEXT NOT NULL, rollout_ordinal INTEGER NOT NULL, status TEXT NOT NULL, first_user_item_id TEXT, final_agent_item_id TEXT, PRIMARY KEY(thread_id,turn_id));
INSERT INTO threads VALUES ('paged-thread','legacy-relay');
INSERT INTO thread_history_projection_state VALUES ('paged-thread',$failureLength,5);
INSERT INTO thread_items VALUES ('paged-thread','turn-1','$longReasoningId',2,1000,'$($dropJson.Replace("'", "''"))','reasoning',2);
INSERT INTO thread_items VALUES ('paged-thread','turn-1','item_message',3,1001,'$($renameJson.Replace("'", "''"))','message',3);
INSERT INTO thread_items VALUES ('paged-thread','turn-1','item_call',4,1002,'$($renameJson2.Replace("'", "''"))','function_call',4);
INSERT INTO thread_turns VALUES ('paged-thread','turn-1',1,'completed','item_message','item_call');
CREATE TRIGGER reject_projection_drop BEFORE DELETE ON thread_items WHEN OLD.item_id='$longReasoningId' BEGIN SELECT RAISE(ABORT,'injected projection failure'); END;
"@)
    $failureBefore = [IO.File]::ReadAllBytes($paginatedFailureRollout)
    $failureDbBefore = @(Invoke-TestSqlite -Path $paginatedFailureDb -ReadOnly -Sql "SELECT rollout_ordinal||':'||item_id||':'||item_json FROM thread_items ORDER BY rollout_ordinal;")
    $failed = $false
    try { [void](& $repairScript -Command repair -CodexHome $paginatedFailureHome -BackupRoot (Join-Path $tempRoot "paginated-failure-backups")) }
    catch { $failed = $true }
    Assert-True $failed "Injected paginated database failure was not surfaced."
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($paginatedFailureRollout)) -ceq [Convert]::ToBase64String($failureBefore)) "Failure rollback did not restore the journal."
    $failureDbAfter = @(Invoke-TestSqlite -Path $paginatedFailureDb -ReadOnly -Sql "SELECT rollout_ordinal||':'||item_id||':'||item_json FROM thread_items ORDER BY rollout_ordinal;")
    Assert-True ([string]::Join("`n", $failureDbAfter) -ceq [string]::Join("`n", $failureDbBefore)) "Failure rollback did not restore projection rows."
    Assert-True (@(Invoke-TestSqlite -Path $paginatedFailureDb -ReadOnly -Sql "SELECT model_provider FROM threads WHERE id='paged-thread';")[0] -ceq "legacy-relay") "Failure rollback did not restore the provider row."
    Assert-True (@(Invoke-TestSqlite -Path $paginatedFailureDb -ReadOnly -Sql "SELECT first_user_item_id||':'||final_agent_item_id FROM thread_turns WHERE thread_id='paged-thread' AND turn_id='turn-1';")[0] -ceq "item_message:item_call") "Failure rollback did not restore thread_turns."

    $unsupportedHome = New-TestHome "unsupported"
    $unsupportedRollout = Join-Path $unsupportedHome "sessions\2026\07\30\rollout-unsupported.jsonl"
    Write-Jsonl -Path $unsupportedRollout -Records @(
        [ordered]@{
            timestamp = "2026-07-30T00:00:00Z"
            type = "response_item"
            payload = [ordered]@{ type = "future_tool_call"; id = "item_unknown" }
        }
    )
    $unsupportedBefore = [IO.File]::ReadAllBytes($unsupportedRollout)
    $failed = $false
    try {
        [void](& $repairScript -Command repair -CodexHome $unsupportedHome -BackupRoot (Join-Path $tempRoot "unsupported-backups"))
    }
    catch {
        $failed = $true
    }
    Assert-True $failed "Unsupported response item type was repaired without an explicit rule."
    Assert-True (
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($unsupportedRollout)) -ceq
        [Convert]::ToBase64String($unsupportedBefore)
    ) "Unsupported repair attempt changed the rollout."

    $emptyHome = New-TestHome "empty-rollout"
    $emptyRollout = Join-Path $emptyHome "sessions\2026\07\30\rollout-empty.jsonl"
    [IO.Directory]::CreateDirectory((Split-Path -Parent $emptyRollout)) | Out-Null
    [IO.File]::WriteAllBytes($emptyRollout, [byte[]]@())
    $emptyScan = & $repairScript -Command scan -CodexHome $emptyHome -BackupRoot (Join-Path $tempRoot "empty-backups")
    Assert-True ($emptyScan.Unsupported -eq 1 -and $emptyScan.AffectedFiles -eq 1) "An empty rollout without session_meta was silently ignored."
    $emptyBefore = [IO.File]::ReadAllBytes($emptyRollout)
    $failed = $false
    try {
        [void](& $repairScript -Command repair -CodexHome $emptyHome -BackupRoot (Join-Path $tempRoot "empty-backups"))
    }
    catch {
        $failed = $true
    }
    Assert-True $failed "Repair attempted to rewrite a rollout without a usable header."
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($emptyRollout)) -ceq [Convert]::ToBase64String($emptyBefore)) "Headerless rollout changed after refusal."

    $lockedHome = New-TestHome "locked"
    $lockedRollout = Join-Path $lockedHome "sessions\2026\07\30\rollout-locked.jsonl"
    Write-Jsonl -Path $lockedRollout -Records @(
        [ordered]@{
            timestamp = "2026-07-30T00:00:00Z"
            type = "response_item"
            payload = [ordered]@{
                type = "message"
                id = "item_locked"
                role = "assistant"
                content = @([ordered]@{ type = "output_text"; text = "locked" })
            }
        }
    )
    $lockedBefore = [IO.File]::ReadAllBytes($lockedRollout)
    $heldStream = [IO.File]::Open($lockedRollout, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $failed = $false
        try {
            [void](& $repairScript -Command repair -CodexHome $lockedHome -BackupRoot (Join-Path $tempRoot "locked-backups"))
        }
        catch {
            $failed = $true
        }
        Assert-True $failed "Repair did not refuse a rollout held open by another process."
    }
    finally {
        $heldStream.Dispose()
    }
    Assert-True (
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($lockedRollout)) -ceq
        [Convert]::ToBase64String($lockedBefore)
    ) "Locked rollout changed after the refused repair."

    Write-Host "Codex history compatibility tests passed."
}
finally {
    if ([IO.Directory]::Exists($tempRoot)) {
        $resolvedTempRoot = Resolve-Path -LiteralPath $tempRoot
        $systemTempRoot = Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())
        if (-not $resolvedTempRoot.Path.StartsWith($systemTempRoot.Path, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove test data outside the system temporary directory."
        }
        Remove-Item -LiteralPath $resolvedTempRoot.Path -Recurse -Force
    }
}
