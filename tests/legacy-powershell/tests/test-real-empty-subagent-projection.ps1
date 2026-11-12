#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$DatabasePath,
    [Parameter(Mandatory = $true)][string]$ThreadId
)
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot


Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repairScript = Join-Path $script:ProjectRoot 'codex-history-compat.ps1'
$sqlite = (Get-Command sqlite3.exe -ErrorAction Stop).Source
$root = Join-Path ([IO.Path]::GetTempPath()) ('codex-real-empty-subagent-' + [Guid]::NewGuid().ToString('N'))

function Invoke-SqlJson([string]$Path, [string]$Query) {
    $lines = @(& $sqlite -readonly -batch -noheader $Path $Query 2>&1)
    if ($LASTEXITCODE -ne 0 -or $lines.Count -ne 1) { throw "Unable to read the source projection: $($lines -join "`n")" }
    return ($lines[0] | ConvertFrom-Json)
}

try {
    if (-not [IO.File]::Exists($SourcePath) -or -not [IO.File]::Exists($DatabasePath)) { throw 'Source files do not exist.' }
    $sourceFull = [IO.Path]::GetFullPath($SourcePath)
    $sourceHash = (Get-FileHash -LiteralPath $sourceFull -Algorithm SHA256).Hash
    $archive = Join-Path $root 'sessions'
    [IO.Directory]::CreateDirectory($archive) | Out-Null
    $copy = Join-Path $archive ([IO.Path]::GetFileName($SourcePath))
    Copy-Item -LiteralPath $sourceFull -Destination $copy

    $threadSql = $ThreadId.Replace("'", "''")
    $snapshot = Invoke-SqlJson $DatabasePath "SELECT json_object('turns',(SELECT COUNT(*) FROM thread_turns WHERE thread_id='$threadSql'),'items',(SELECT COUNT(*) FROM thread_items WHERE thread_id='$threadSql'),'turn',json((SELECT json_object('turn_id',turn_id,'ordinal',rollout_ordinal,'status',status,'first',first_user_item_id,'final',final_agent_item_id,'start',rollout_byte_offset,'end_ordinal',rollout_end_ordinal,'end_offset',rollout_end_byte_offset,'root',root_turn_id) FROM thread_turns WHERE thread_id='$threadSql')),'cursor',json((SELECT json_object('offset',next_rollout_byte_offset,'ordinal',next_rollout_ordinal) FROM thread_history_projection_state WHERE thread_id='$threadSql')));"
    if ($snapshot.turns -ne 1 -or $snapshot.items -ne 0 -or $null -eq $snapshot.cursor) { throw 'Source is not a single empty-projection turn.' }
    $turn = $snapshot.turn
    $cursor = $snapshot.cursor
    if ((Get-FileHash -LiteralPath $sourceFull -Algorithm SHA256).Hash -cne $sourceHash -or
        (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash -cne $sourceHash) { throw 'Source changed during the disposable snapshot.' }
    $first = if ($null -eq $turn.first) { 'NULL' } else { "'$($turn.first.ToString().Replace("'", "''"))'" }
    $final = if ($null -eq $turn.final) { 'NULL' } else { "'$($turn.final.ToString().Replace("'", "''"))'" }
    $status = $turn.status.ToString().Replace("'", "''")
    $turnId = $turn.turn_id.ToString().Replace("'", "''")
    $rootTurn = $turn.root.ToString().Replace("'", "''")
    $db = Join-Path $root 'thread_history_1.sqlite'
    $sql = @"
CREATE TABLE thread_history_projection_state(thread_id TEXT PRIMARY KEY,next_rollout_byte_offset INTEGER,next_rollout_ordinal INTEGER);
CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_id TEXT,rollout_ordinal INTEGER,created_at_ms INTEGER,item_json TEXT,item_type TEXT,updated_at_ordinal INTEGER);
CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,rollout_ordinal INTEGER,status TEXT,first_user_item_id TEXT,final_agent_item_id TEXT,rollout_byte_offset INTEGER,rollout_end_ordinal INTEGER,rollout_end_byte_offset INTEGER,root_turn_id TEXT);
INSERT INTO thread_history_projection_state VALUES('$threadSql',$($cursor.offset),$($cursor.ordinal));
INSERT INTO thread_turns VALUES('$threadSql','$turnId',$($turn.ordinal),'$status',$first,$final,$($turn.start),$($turn.end_ordinal),$($turn.end_offset),'$rootTurn');
"@
    $null = $sql | & $sqlite -batch -bail $db
    if ($LASTEXITCODE -ne 0) { throw 'Unable to build the disposable projection.' }

    $beforeHash = (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash
    $beforeDbHash = (Get-FileHash -LiteralPath $db -Algorithm SHA256).Hash
    $result = & $repairScript -Command repair -CodexHome $root -BackupRoot (Join-Path $root 'backups') -PortableInputIds
    if ($result.RepairedFiles -ne 1 -or $result.RepairedDatabases -ne 0) { throw 'The exact record was not selected as a JSONL-only repair.' }
    $beforeLines = [IO.File]::ReadAllLines($sourceFull)
    $afterLines = [IO.File]::ReadAllLines($copy)
    if ($beforeLines.Count -ne $afterLines.Count) { throw 'The repair changed the record count.' }
    $utf8 = New-Object Text.UTF8Encoding($false)
    for ($i=0; $i -lt $beforeLines.Count; $i++) {
        $expected = [CodexHistoryCompat.PortableHistory]::Clear($beforeLines[$i])
        if ($expected -cne $afterLines[$i] -or $utf8.GetByteCount($beforeLines[$i]) -ne $utf8.GetByteCount($afterLines[$i])) {
            throw "The repair changed a non-ID field or byte boundary at line $i."
        }
    }
    if ((Get-FileHash -LiteralPath $db -Algorithm SHA256).Hash -cne $beforeDbHash) { throw 'Disposable repair changed the database.' }
    $null = & $repairScript -Command rollback -CodexHome $root -BackupRoot (Join-Path $root 'backups') -ManifestPath $result.ManifestPath
    if ((Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash -cne $beforeHash) { throw 'Disposable rollback did not restore the exact source copy.' }
    if ((Get-FileHash -LiteralPath $sourceFull -Algorithm SHA256).Hash -cne $sourceHash) { throw 'Source changed during the dry run.' }
    Write-Host 'Exact terminal subagent dry run passed: JSONL-only repair, unchanged fields/database, and exact rollback.'
}
finally {
    $resolved = [IO.Path]::GetFullPath($root)
    $tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($resolved.StartsWith($tempParent, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -match '^codex-real-empty-subagent-[0-9a-f]{32}$' -and
        [IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
