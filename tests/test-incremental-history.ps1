#requires -Version 5.1
[CmdletBinding()] param()
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$repair=Join-Path $script:ProjectRoot 'codex-history-compat.ps1'
$utf8=New-Object Text.UTF8Encoding($false)
$sqlite=(Get-Command sqlite3.exe -ErrorAction Stop).Source
$root=Join-Path ([IO.Path]::GetTempPath()) ('codex-incremental-test-'+[Guid]::NewGuid().ToString('N'))
function Check([bool]$Value,[string]$Message) { if (-not $Value) { throw $Message } }
function Sql([string]$Db,[string]$Query) { $out=@($Query | & $sqlite -batch -bail $Db 2>&1); if ($LASTEXITCODE) { throw ($out -join '; ') } }
function Line($Record) { return ($Record | ConvertTo-Json -Compress -Depth 30)+"`n" }
function New-Case([string]$Name) {
    $dir=Join-Path $root $Name
    [void][IO.Directory]::CreateDirectory((Join-Path $dir 'sessions'))
    $path=Join-Path $dir 'sessions\rollout.jsonl'
    $text=(Line @{ordinal=0;type='session_meta';payload=@{id='incremental-thread';model_provider='openai';history_mode='paginated'}})+
        (Line @{ordinal=1;type='event_msg';payload=@{type='item_completed';thread_id='incremental-thread';turn_id='turn';item=@{id='ui-old';type='AgentMessage';text='中文旧内容'}}})+
        (Line @{ordinal=2;type='response_item';payload=@{type='message';id=$null;role='assistant';content=@(@{type='output_text';text='中文旧内容'})}})
    [IO.File]::WriteAllText($path,$text,$utf8)
    $other=Join-Path $dir 'sessions\unchanged.jsonl'
    [IO.File]::WriteAllText($other,(Line @{type='session_meta';payload=@{id='other';model_provider='openai'}}),$utf8)
    $db=Join-Path $dir 'thread_history_1.sqlite'; $len=(Get-Item -LiteralPath $path).Length
    Sql $db @"
CREATE TABLE thread_history_projection_state(thread_id TEXT PRIMARY KEY,next_rollout_byte_offset INTEGER,next_rollout_ordinal INTEGER);
CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_id TEXT,rollout_ordinal INTEGER,created_at_ms INTEGER,item_json TEXT,item_type TEXT,updated_at_ordinal INTEGER);
CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,rollout_ordinal INTEGER,status TEXT,first_user_item_id TEXT,final_agent_item_id TEXT);
INSERT INTO thread_history_projection_state VALUES('incremental-thread',$len,3);
INSERT INTO thread_items VALUES('incremental-thread','turn','ui-old',1,1,'{"id":"ui-old","type":"agentMessage","text":"中文旧内容"}','agentMessage',1);
INSERT INTO thread_turns VALUES('incremental-thread','turn',1,'completed',NULL,'ui-old');
"@
    return @{Home=$dir;Path=$path;Db=$db;Backups=(Join-Path $dir 'backups');Original=$text;Other=$other}
}
function Run($Case,[string]$Command,[bool]$Increment=$true) {
    return & $repair -Command $Command -CodexHome $Case.Home -BackupRoot $Case.Backups -PortableInputIds -Incremental:$Increment
}
function Findings($Report) {
    $values=@(foreach ($file in @($Report.Files | Sort-Object Path)) {
        $providers=[ordered]@{}
        foreach ($key in @($file.ProviderCounts.Keys | Sort-Object)) { $providers[$key]=$file.ProviderCounts[$key] }
        [ordered]@{path=$file.Path;paginated=$file.IsPaginated;fork=$file.IsMaterializedFork;threads=@($file.ThreadIds | Sort-Object);
            providers=$providers;issues=@($file.FileIssues);
            items=@($file.Items | Sort-Object LineNumber | Select-Object LineNumber,Type,Action,OldId,NewId,CallId,OldLineSha256,UnsupportedReason,RolloutOrdinal);
            provider_items=@($file.ProviderItems | Sort-Object LineNumber | Select-Object LineNumber,RecordType,Field,ThreadId,OldProvider,NewProvider,OldLineSha256,UnsupportedReason)}
    })
    return ConvertTo-Json -InputObject $values -Depth 20 -Compress
}
function Append-Case($Case) {
    $text=(Line @{ordinal=3;type='event_msg';payload=@{type='item_completed';thread_id='incremental-thread';turn_id='turn';item=@{id='ui-new';type='AgentMessage';text='新增中文😀'}}})+
        (Line @{ordinal=4;type='response_item';payload=@{type='message';id='msg_new';role='assistant';content=@(@{type='output_text';text='新增中文😀'})}})+
        (Line @{ordinal=5;type='compacted';payload=@{replacement_history=@(@{type='message';id='msg_in_compact';role='user';content=@(@{type='input_text';text='保留'})},@{type='compaction';id='cmp_new';encrypted_content='encrypted-kept'});guardian_history=@(@{type='message';id='msg_guardian';content=@()})}})
    [IO.File]::AppendAllText($Case.Path,$text,$utf8)
    $len=(Get-Item -LiteralPath $Case.Path).Length
    Sql $Case.Db "UPDATE thread_history_projection_state SET next_rollout_byte_offset=$len,next_rollout_ordinal=6; INSERT INTO thread_items VALUES('incremental-thread','turn','ui-new',3,2,'{""id"":""ui-new"",""type"":""agentMessage"",""text"":""新增中文😀""}','agentMessage',3);"
}
try {
    $c=New-Case 'append'
    $baseline=Run $c repair
    Check ($baseline.ScanMetrics.FullFiles -eq 2) 'Initial baseline must inspect all new files.'
    $idle=Run $c repair
    Check ($idle.ScanMetrics.SkippedFiles -eq 2 -and $idle.ScanMetrics.ParsedBytes -eq 0) 'Idle preparation reparsed old history.'
    Append-Case $c
    $before=[IO.File]::ReadAllBytes($c.Path); $dbHash=(Get-FileHash -LiteralPath $c.Db).Hash
    $full=Run $c scan $false; $delta=Run $c scan
    Check ($delta.ScanMetrics.TailFiles -eq 1 -and $delta.ScanMetrics.SkippedFiles -eq 1) 'Appended journal did not use the tail.'
    Check ($delta.PortableRecords -eq $full.PortableRecords -and $delta.Drops -eq $full.Drops -and $delta.ProviderChanges -eq $full.ProviderChanges) 'Incremental findings differ from full scan.'
    Check ((Findings $delta) -ceq (Findings $full)) 'Incremental issue locations or actions differ from the full scan.'
    $done=Run $c repair
    $manifest=[IO.File]::ReadAllText($done.ManifestPath) | ConvertFrom-Json
    Check ($manifest.files[0].kind -ceq 'fixed_slots') 'Append repair copied/replaced the whole file.'
    Check ((Get-Item -LiteralPath $manifest.files[0].backup_path).Length -lt 1000) 'Fixed-slot backup is not small.'
    $after=[IO.File]::ReadAllLines($c.Path)
    Check ($null -eq ($after[4] | ConvertFrom-Json).payload.id) 'Added message ID remains.'
    $compact=($after[5] | ConvertFrom-Json).payload
    Check ($null -eq $compact.replacement_history[0].id -and $null -eq $compact.replacement_history[1].id) 'Nested compacted IDs were missed.'
    Check ($compact.replacement_history[1].encrypted_content -ceq 'encrypted-kept' -and $compact.guardian_history[0].id -ceq 'msg_guardian') 'Encrypted/guardian data changed.'
    Check ((Get-FileHash -LiteralPath $c.Db).Hash -ceq $dbHash) 'Incremental repair changed UI database.'
    $repaired=[IO.File]::ReadAllText($c.Path)
    [void](& $repair -Command rollback -CodexHome $c.Home -BackupRoot $c.Backups -ManifestPath $done.ManifestPath)
    Check ([Convert]::ToBase64String([IO.File]::ReadAllBytes($c.Path)) -ceq [Convert]::ToBase64String($before)) 'Field rollback failed exact-byte comparison.'
    [IO.File]::WriteAllText($c.Path,$repaired,$utf8)
    [void](Run $c repair)
    # Restore after an unrelated append is forbidden; the append must remain.
    [IO.File]::AppendAllText($c.Path,(Line @{ordinal=6;type='event_msg';payload=@{type='token_count';info=$null;rate_limits=$null}}),$utf8)
    $appendedHash=(Get-FileHash -LiteralPath $c.Path).Hash; $refused=$false
    try { [void](& $repair -Command rollback -CodexHome $c.Home -BackupRoot $c.Backups -ManifestPath $done.ManifestPath) } catch {$refused=$true}
    Check ($refused -and (Get-FileHash -LiteralPath $c.Path).Hash -ceq $appendedHash) 'Rollback overwrote subsequent activity.'

    # Reuse proven old UI sources; only new rows/records need source parsing.
    $w=New-Case 'projection-witness'; [void](Run $w repair); Append-Case $w; [void](Run $w repair)
    $extra=Line @{ordinal=6;type='compacted';payload=@{replacement_history=@(@{type='compaction';id='cmp_witness';encrypted_content='kept'})}}
    [IO.File]::AppendAllText($w.Path,$extra,$utf8)
    $len=(Get-Item -LiteralPath $w.Path).Length
    Sql $w.Db "UPDATE thread_history_projection_state SET next_rollout_byte_offset=$len,next_rollout_ordinal=7;"
    $reuse=Run $w repair
    if ([CodexHistoryCompat.PortableHistory]::SupportsFastJson) {
        Check ($reuse.ScanMetrics.ProjectionTailFiles -eq 1 -and $reuse.ScanMetrics.ProjectionFullFiles -eq 0) 'Previously proved UI sources were reparsed.'
    } else {
        Check ($reuse.ScanMetrics.ProjectionFullFiles -eq 1) 'Legacy PowerShell must retain the full UI source check.'
    }
    [IO.File]::AppendAllText($w.Path,(Line @{ordinal=7;type='compacted';payload=@{replacement_history=@(@{type='compaction';id='cmp_refuse';encrypted_content='kept'})}}),$utf8)
    $len=(Get-Item -LiteralPath $w.Path).Length
    Sql $w.Db "UPDATE thread_history_projection_state SET next_rollout_byte_offset=$len,next_rollout_ordinal=8; UPDATE thread_items SET item_json='{""id"":""wrong"",""type"":""agentMessage""}' WHERE item_id='ui-old';"
    $hash=(Get-FileHash -LiteralPath $w.Path).Hash; $bad=$false
    try {[void](Run $w repair)} catch {$bad=$true}
    Check ($bad -and (Get-FileHash -LiteralPath $w.Path).Hash -ceq $hash) 'Changed old UI projection bypassed source validation.'

    $encoding=New-Case 'bom-crlf'
    $bom=New-Object Text.UTF8Encoding($true)
    [IO.File]::WriteAllText($encoding.Path,$encoding.Original.Replace("`n","`r`n"),$bom)
    [void](Run $encoding repair); Append-Case $encoding
    $textBytes=[IO.File]::ReadAllBytes($encoding.Path)
    [void](Run $encoding repair)
    $now=[IO.File]::ReadAllBytes($encoding.Path)
    Check ($now.Length -eq $textBytes.Length -and $now[0] -eq 239 -and $now[1] -eq 187 -and $now[2] -eq 191) 'Incremental UTF-8/BOM/CRLF layout changed.'

    foreach ($variant in @('rewrite','truncate','replace','partial','metadata','archive','corrupt-cache','provider')) {
        $f=New-Case $variant; [void](Run $f repair)
        switch ($variant) {
            'rewrite' { [IO.File]::WriteAllText($f.Path,$f.Original.Replace('中文旧内容','中文改内容'),$utf8); Append-Case $f }
            'truncate' { [IO.File]::WriteAllText($f.Path,(Line @{ordinal=0;type='session_meta';payload=@{id='incremental-thread';model_provider='openai';history_mode='paginated'}}),$utf8) }
            'replace' { $tmp=$f.Path+'.new'; [IO.File]::WriteAllText($tmp,$f.Original,$utf8); [IO.File]::Delete($f.Path); [IO.File]::Move($tmp,$f.Path) }
            'partial' { [IO.File]::AppendAllText($f.Path,'{"ordinal":3', $utf8) }
            'metadata' { [IO.File]::AppendAllText($f.Path,(Line @{ordinal=3;type='session_meta';payload=@{id='incremental-thread';model_provider='openai';history_mode='paginated'}}),$utf8) }
            'archive' { [void][IO.Directory]::CreateDirectory((Join-Path $f.Home 'archived_sessions')); $dest=Join-Path $f.Home 'archived_sessions\rollout.jsonl'; [IO.File]::Move($f.Path,$dest); $f.Path=$dest }
            'corrupt-cache' { [IO.File]::WriteAllText((Join-Path $f.Backups 'incremental-cache.json'),'{}',$utf8) }
            'provider' { [IO.File]::AppendAllText($f.Path,(Line @{ordinal=3;type='event_msg';payload=@{type='thread_settings_applied';thread_settings=@{model_provider_id='relay'}}}),$utf8) }
        }
        if ($variant -eq 'partial') { $bad=$false; try {[void](Run $f scan)} catch {$bad=$true}; Check $bad 'Incomplete added JSON was accepted.'; continue }
        $d=Run $f scan; $a=Run $f scan $false
        Check ($d.PortableRecords -eq $a.PortableRecords -and $d.ProviderChanges -eq $a.ProviderChanges -and $d.Unsupported -eq $a.Unsupported) "Findings differ for $variant."
        Check ((Findings $d) -ceq (Findings $a)) "Issue locations or actions differ for $variant."
        if ($variant -ne 'provider') { Check ($d.ScanMetrics.FullFiles -ge 1) "Unsafe tail reuse for $variant." }
    }
    # A new file is fully inspected without reparsing the existing two.
    $n=New-Case 'new-file'; [void](Run $n repair)
    [IO.File]::WriteAllText((Join-Path $n.Home 'sessions\new.jsonl'),(Line @{type='session_meta';payload=@{id='new-thread';model_provider='openai'}}),$utf8)
    $new=Run $n repair
    Check ($new.ScanMetrics.FullFiles -eq 1 -and $new.ScanMetrics.SkippedFiles -eq 2) 'New file caused a global reparse.'

    # Old-style journals retain full-file semantic checks when they change.
    [IO.File]::AppendAllText($n.Other,(Line @{type='response_item';payload=@{type='message';id='item_legacy';role='assistant';content=@(@{type='output_text';text='旧格式'})}}),$utf8)
    $legacy=Run $n scan
    Check ($legacy.ScanMetrics.FullFiles -eq 1 -and $legacy.Renames -eq 1) 'Changed legacy history incorrectly reused a prefix.'
    # Database-only provider changes must not hide behind clean file certificates.
    $s=New-Case 'database-only'; [void](Run $s repair)
    Sql $s.Db "CREATE TABLE threads(id TEXT PRIMARY KEY,model_provider TEXT); INSERT INTO threads VALUES('incremental-thread','openai');"
    $schema=Run $s repair
    Check ($schema.ScanMetrics.FullFiles -eq 2) 'Related schema change reused stale certificates.'
    Sql $s.Db "UPDATE threads SET model_provider='relay';"
    $dbOnly=Run $s scan
    Check ($dbOnly.ScanMetrics.SkippedFiles -eq 2 -and $dbOnly.ProviderDatabaseChanges -eq 1) 'Database provider drift was skipped.'
    [void](Run $s repair)

    foreach ($ordinalJson in @('3.5','-1','2')) {
        $invalid=New-Case ('invalid-ordinal-'+$ordinalJson); [void](Run $invalid repair)
        [IO.File]::AppendAllText($invalid.Path,'{"ordinal":'+$ordinalJson+',"type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":null}}'+"`n",$utf8)
        $invalidHash=(Get-FileHash -LiteralPath $invalid.Path).Hash; $refused=$false
        try { [void](Run $invalid repair) } catch {$refused=$true}
        Check ($refused -and (Get-FileHash -LiteralPath $invalid.Path).Hash -ceq $invalidHash) 'Invalid ordinal was rounded, cached or written.'
    }

    # Simulated interrupted writes are normalized back using durable slot data.
    $p=New-Case 'interrupted'; [void](Run $p repair); Append-Case $p
    $scan=Run $p scan
    $originalHash=(Get-FileHash -LiteralPath $p.Path).Hash.ToLowerInvariant(); $originalBytes=[IO.File]::ReadAllBytes($p.Path)
    $slots=[CodexHistoryCompat.IncrementalIo]::BuildSlots($p.Path,$scan.Files[0].ScanStartOffset,$scan.Files[0].ScanFirstLine,[CodexHistoryCompat.PortableRecord[]]$scan.Files[0].Items)
    $journal=Join-Path $p.Backups 'interrupted'; [void][IO.Directory]::CreateDirectory($journal)
    $slotFile=Join-Path $journal 'slots.bin'; [CodexHistoryCompat.IncrementalIo]::SaveSlots($slotFile,$slots)
    $expectedHash=[CodexHistoryCompat.IncrementalIo]::RepairedHash($p.Path,$slots)
    $length=$originalBytes.Length; $injected=$false
    try { [CodexHistoryCompat.IncrementalIo]::ApplySlots($p.Path,$slotFile,$length,$originalHash,$expectedHash,$false,1) } catch {$injected=$true}
    Check $injected 'Interrupted-write fixture did not fail.'
    [CodexHistoryCompat.IncrementalIo]::ApplySlots($p.Path,$slotFile,$length,$originalHash,$expectedHash,$true,-1)
    Check ([Convert]::ToBase64String([IO.File]::ReadAllBytes($p.Path)) -ceq [Convert]::ToBase64String($originalBytes)) 'Partial write did not recover exact original bytes.'
    $identity=[CodexHistoryCompat.IncrementalIo]::Stamp($p.Path).Identity
    $copy=$p.Path+'.replacement'; [IO.File]::Copy($p.Path,$copy); [IO.File]::Delete($p.Path); [IO.File]::Move($copy,$p.Path)
    $replaced=$false
    try { [CodexHistoryCompat.IncrementalIo]::ApplySlots($p.Path,$slotFile,$length,$originalHash,$expectedHash,$false,-1,$identity) } catch {$replaced=$true}
    Check ($replaced -and (Get-FileHash -LiteralPath $p.Path).Hash.ToLowerInvariant() -ceq $originalHash) 'Replaced file was written using another file identity.'
    # Persist an applying manifest, then simulate a torn write inside one ID.
    $entry=@{kind='fixed_slots';path=$p.Path;identity=([CodexHistoryCompat.IncrementalIo]::Stamp($p.Path).Identity);
        backup_path=$slotFile;backup_sha256=(Get-FileHash -LiteralPath $slotFile).Hash.ToLowerInvariant();
        original_length=$length;repaired_length=$length;original_sha256=$originalHash;repaired_sha256=$expectedHash;status='applying'}
    $mf=Join-Path $journal 'manifest.json'
    [IO.File]::WriteAllText($mf,(@{version=3;status='preparing';codex_home=$p.Home;created_utc=[DateTime]::UtcNow.ToString('o');updated_utc=[DateTime]::UtcNow.ToString('o');files=@($entry);databases=@()} | ConvertTo-Json -Depth 15),$utf8)
    [IO.File]::WriteAllText((Join-Path $p.Backups 'active-transaction.json'),(@{manifest=$mf} | ConvertTo-Json),$utf8)
    $file=[IO.File]::Open($p.Path,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {$file.Position=$slots[0].Offset;$file.Write($slots[0].After,0,2);$file.Flush($true)} finally {$file.Dispose()}
    $blocked=$false; try {[void](Run $p scan)} catch {$blocked=$true}; Check $blocked 'Pending transaction was treated as clean.'
    [void](Run $p repair)
    Check (([IO.File]::ReadAllText($mf) | ConvertFrom-Json).status -ceq 'rolled_back') 'Next preparation did not recover a torn write.'
    Check (-not [IO.File]::Exists((Join-Path $p.Backups 'active-transaction.json'))) 'Recovery left a pending marker.'
    'Incremental history checks, fixed-slot repair and rollback passed.'
} finally {
    if ([IO.Directory]::Exists($root)) {
        $resolved=[IO.Path]::GetFullPath($root)
        if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('codex-incremental-test-')) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    }
}
