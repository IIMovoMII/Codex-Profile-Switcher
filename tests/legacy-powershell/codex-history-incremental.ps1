# Internal helpers; loaded in the history transaction's scope, never a launcher.
$script:HistoryCachePath = Join-Path $BackupRoot 'incremental-cache.json'
$script:HistoryActivePath = Join-Path $BackupRoot 'active-transaction.json'
$script:FileCertificates = @{}
$script:CurrentFileStamps = @{}
$script:HistoryPostPass = $false
$script:ProjectionWitnesses = @{}
$script:ScanCounters = @{ SkippedFiles=0; TailFiles=0; FullFiles=0; ParsedBytes=0L; PrefixVerifiedBytes=0L; ProjectionTailFiles=0; ProjectionFullFiles=0 }
$ruleText = [IO.File]::ReadAllText($PSCommandPath) + [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'codex-history-compat.ps1')) +
    [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'CodexPortableHistory.cs'))
$schemaParts=New-Object Collections.Generic.List[string]
foreach ($database in @(Get-StateDatabaseFiles)) {
    $rows=@(Invoke-SqliteLines -Path $database -ReadOnly -Sql "SELECT type||'|'||name||'|'||COALESCE(sql,'') FROM sqlite_master WHERE tbl_name IN ('threads','thread_items','thread_turns','thread_history_projection_state') ORDER BY type,name;")
    if ($rows.Count -gt 0) { $schemaParts.Add($database+'|'+[string]::Join("`n",[string[]]$rows)) }
}
$ruleText += '|schema=' + [string]::Join("`n",$schemaParts.ToArray())
$script:IncrementalRulesHash = Get-TextSha256 ($ruleText + '|portable=' + [string][bool]$PortableInputIds)

function Write-HistoryStateJson {
    param([string]$Path, $Value)
    $temp = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    try {
        $bytes = $script:Utf8NoBom.GetBytes(($Value | ConvertTo-Json -Depth 40 -Compress))
        $stream = New-Object IO.FileStream($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, 65536, [IO.FileOptions]::WriteThrough)
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        Move-ReplaceFile -Source $temp -Destination $Path
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

if ($Incremental -and [IO.File]::Exists($script:HistoryCachePath)) {
    try {
        $envelope = [IO.File]::ReadAllText($script:HistoryCachePath) | ConvertFrom-Json
        if ((Get-TextSha256 ([string]$envelope.payload)) -cne [string]$envelope.sha256) { throw 'Invalid cache checksum.' }
        $cache = ([string]$envelope.payload) | ConvertFrom-Json
        if ($cache.version -ne 1 -or $cache.codex_home -cne $CodexHome -or $cache.rules -cne $script:IncrementalRulesHash) { throw 'Stale cache.' }
        foreach ($entry in @($cache.files)) {
            if ($entry.Length -le 0 -or $entry.Lines -le 0 -or $entry.Sha256 -cnotmatch '^[0-9a-f]{64}$' -or
                [string]::IsNullOrWhiteSpace([string]$entry.Identity) -or $null -eq $entry.Report -or
                @($entry.Report.ThreadIds).Count -ne 1 -or $entry.WriteTicks -le 0 -or
                $entry.Length -ne [long]$entry.Length -or $entry.Lines -ne [int]$entry.Lines -or
                $entry.Report.IsPaginated -isnot [bool] -or $entry.Report.IsMaterializedFork -isnot [bool] -or
                $entry.EndsWithNewline -isnot [bool] -or $null -eq $entry.Report.ProviderCounts -or
                [string]::IsNullOrWhiteSpace([string]$entry.Report.ThreadIds[0]) -or
                ($entry.Report.IsPaginated -and $entry.LastOrdinal -lt 0) -or
                $script:FileCertificates.ContainsKey([string]$entry.Path)) { throw 'Incomplete certificate.' }
            foreach ($count in $entry.Report.ProviderCounts.PSObject.Properties) {
                if ($count.Name -cne 'openai' -or [int]$count.Value -lt 1) { throw 'Unprepared provider in certificate.' }
            }
            $script:FileCertificates[[string]$entry.Path] = $entry
        }
    } catch {
        $script:FileCertificates.Clear()
        Write-Host '增量检查记录缺失、损坏或规则已更新，将重新建立已验证记录。'
    }
}

function Test-HistoryStampEqual {
    param($Left, $Right)
    return $Left.Identity -ceq $Right.Identity -and $Left.Length -eq $Right.Length -and $Left.WriteTicks -eq $Right.WriteTicks
}

function Get-HistoryRangeInfo {
    param([string]$Path,[long]$Offset,[int]$FirstLine,[bool]$Paginated,[long]$PreviousOrdinal)
    if ([CodexHistoryCompat.PortableHistory]::SupportsFastJson) {
        return [CodexHistoryCompat.PortableHistory]::ValidateRange($Path,$Offset,$FirstLine,$Paginated,$PreviousOrdinal)
    }
    $result = [CodexHistoryCompat.JournalRange]::new()
    $result.LastOrdinal = $PreviousOrdinal
    foreach ($line in [CodexHistoryCompat.IncrementalIo]::ReadLines($Path,$Offset,$FirstLine)) {
        $record = $line.Text | ConvertFrom-Json -ErrorAction Stop
        if ($Paginated) {
            $ordinalValue = Get-JsonPropertyValue $record 'ordinal'; $ordinal=0L
            if ($null -eq $ordinalValue -or
                -not [long]::TryParse([string]$ordinalValue,[Globalization.NumberStyles]::Integer,[Globalization.CultureInfo]::InvariantCulture,[ref]$ordinal) -or
                $ordinal -le $result.LastOrdinal -or $ordinal -lt 0) { throw "新增分页序号无效：$Path" }
            $result.LastOrdinal = $ordinal
        }
        if ([string](Get-JsonPropertyValue $record 'type') -ceq 'session_meta') { $result.HasMetadata=$true }
        $result.Lines++
    }
    $result.EndsWithNewline = [CodexHistoryCompat.IncrementalIo]::EndsWithNewline($Path)
    return $result
}

function Get-CertificateReport {
    param($Entry,[string]$Path,[bool]$Excluded)
    $counts=@{}
    foreach ($p in $Entry.Report.ProviderCounts.PSObject.Properties) { $counts[$p.Name]=[int]$p.Value }
    return [pscustomobject]@{
        Path=$Path; IsPaginated=[bool]$Entry.Report.IsPaginated; IsMaterializedFork=[bool]$Entry.Report.IsMaterializedFork
        Excluded=$Excluded; Items=@(); ProviderItems=@(); ProviderCounts=$counts
        ThreadIds=@($Entry.Report.ThreadIds); FileIssues=@()
    }
}

function Get-IncrementalFileReport {
    param([string]$Path,$ExcludedPaths)
    $before=[CodexHistoryCompat.IncrementalIo]::Stamp($Path)
    $entry=$script:FileCertificates[$Path]
    $useCertificate=($Incremental -or $script:HistoryPostPass) -and -not $ExcludedPaths.Contains($Path)
    if ($useCertificate -and $null -ne $entry -and (Test-HistoryStampEqual $before $entry)) {
        $script:ScanCounters.SkippedFiles++
        $script:CurrentFileStamps[$Path]=$before
        return Get-CertificateReport -Entry $entry -Path $Path -Excluded $false
    }
    $offset=0L; $firstLine=0; $range=$null; $previous=$null
    if ($useCertificate -and $null -ne $entry -and $PortableInputIds -and [bool]$entry.Report.IsPaginated -and
        $before.Identity -ceq $entry.Identity -and $before.Length -gt $entry.Length -and [bool]$entry.EndsWithNewline) {
        $script:ScanCounters.PrefixVerifiedBytes += [long]$entry.Length
        if ([CodexHistoryCompat.IncrementalIo]::HashPrefix($Path,[long]$entry.Length) -ceq [string]$entry.Sha256) {
            $range=Get-HistoryRangeInfo -Path $Path -Offset $entry.Length -FirstLine $entry.Lines -Paginated $true -PreviousOrdinal $entry.LastOrdinal
            if (-not $range.HasMetadata -and $range.EndsWithNewline) {
                $offset=[long]$entry.Length; $firstLine=[int]$entry.Lines; $previous=$entry.Report
            }
        }
    }
    $report=Get-FileCompatibilityItems -Path $Path -ExcludedPaths $ExcludedPaths -StartOffset $offset -FirstLine $firstLine -PreviousReport $previous
    if ($offset -gt 0) { $script:ScanCounters.TailFiles++ } else { $script:ScanCounters.FullFiles++ }
    $script:ScanCounters.ParsedBytes += $before.Length-$offset
    $report | Add-Member -NotePropertyName ScanStartOffset -NotePropertyValue $offset -Force
    $report | Add-Member -NotePropertyName ScanFirstLine -NotePropertyValue $firstLine -Force
    if ($offset -gt 0 -and $null -ne $entry) {
        $report | Add-Member -NotePropertyName PreviousCertificate -NotePropertyValue $entry -Force
        $report | Add-Member -NotePropertyName TailLastOrdinal -NotePropertyValue $range.LastOrdinal -Force
    }
    $after=[CodexHistoryCompat.IncrementalIo]::Stamp($Path)
    if (-not (Test-HistoryStampEqual $before $after)) { throw "历史在检查期间发生变化：$Path" }
    $script:CurrentFileStamps[$Path]=$after
    if (-not $report.Excluded -and $report.Items.Count -eq 0 -and $report.ProviderItems.Count -eq 0 -and
        $report.FileIssues.Count -eq 0 -and $report.ThreadIds.Count -eq 1) {
        if ($offset -eq 0) { $range=Get-HistoryRangeInfo -Path $Path -Offset 0 -FirstLine 0 -Paginated $report.IsPaginated -PreviousOrdinal -1 }
        $sha=[CodexHistoryCompat.IncrementalIo]::HashPrefix($Path,$after.Length)
        if (-not (Test-HistoryStampEqual $after ([CodexHistoryCompat.IncrementalIo]::Stamp($Path)))) { throw "历史在生成增量记录期间变化：$Path" }
        $counts=[ordered]@{}
        foreach ($key in $report.ProviderCounts.Keys) { $counts[$key]=$report.ProviderCounts[$key] }
        $script:FileCertificates[$Path]=[pscustomobject]@{
            Path=$Path; Identity=$after.Identity; Length=$after.Length; WriteTicks=$after.WriteTicks; Sha256=$sha
            Lines=$firstLine+$range.Lines; LastOrdinal=$range.LastOrdinal; EndsWithNewline=$range.EndsWithNewline
            Report=[pscustomobject]@{IsPaginated=$report.IsPaginated;IsMaterializedFork=$report.IsMaterializedFork;
                ThreadIds=@($report.ThreadIds);ProviderCounts=[pscustomobject]$counts}
            ProjectionWitness=$script:ProjectionWitnesses[$Path]
        }
    } elseif ($offset -eq 0) { $script:FileCertificates.Remove($Path) }
    return $report
}

function Assert-HistorySnapshotStable {
    $paths=@(Get-RolloutFiles)
    if ($paths.Count -ne $script:CurrentFileStamps.Count) { throw '检查期间本地历史文件集合变化，已停止。' }
    foreach ($path in $paths) {
        if (-not $script:CurrentFileStamps.ContainsKey($path) -or
            -not (Test-HistoryStampEqual $script:CurrentFileStamps[$path] ([CodexHistoryCompat.IncrementalIo]::Stamp($path)))) {
            throw "检查后历史发生变化，已停止：$path"
        }
    }
}

function Save-HistoryFileCertificates {
    Assert-HistorySnapshotStable
    $entries=@(foreach ($path in @($script:CurrentFileStamps.Keys | Sort-Object)) {
        if ($script:FileCertificates.ContainsKey($path)) { $script:FileCertificates[$path] }
    })
    $payload=[ordered]@{version=1;codex_home=$CodexHome;rules=$script:IncrementalRulesHash;files=$entries} | ConvertTo-Json -Depth 35 -Compress
    Write-HistoryStateJson -Path $script:HistoryCachePath -Value ([ordered]@{payload=$payload;sha256=(Get-TextSha256 $payload)})
}

function Invalidate-HistoryFileCertificates {
    if ([IO.File]::Exists($script:HistoryCachePath)) { [IO.File]::Delete($script:HistoryCachePath) }
}

function Recover-ActiveHistoryTransaction {
    if (-not [IO.File]::Exists($script:HistoryActivePath)) { return }
    if ($Command -ne 'repair' -and $Command -ne 'rollback') { throw '有未完成的历史事务，请停机执行 history-prepare 进行恢复。' }
    $active=[IO.File]::ReadAllText($script:HistoryActivePath) | ConvertFrom-Json
    $path=Resolve-NormalizedPath ([string]$active.manifest)
    if (-not $path.StartsWith($BackupRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($path) -cne 'manifest.json') { throw '未完成事务的清单位置无效。' }
    $manifest=[IO.File]::ReadAllText($path) | ConvertFrom-Json
    if ($manifest.codex_home -cne $CodexHome) { throw '未完成事务属于其他 Codex 数据目录。' }
    if ($manifest.status -notin @('complete','rolled_back')) {
        Write-Host '正在按持久化清单恢复上次未完成的历史修改……'
        Invalidate-HistoryFileCertificates
        $dbs=@($manifest.databases | Where-Object {$null -ne $_})
        for ($i=$dbs.Count-1;$i -ge 0;$i--) {
            $entry=$dbs[$i]
            if ($entry.status -in @('applied','applying')) { Restore-ManifestDatabase $entry }
        }
        $files=@($manifest.files | Where-Object {$null -ne $_})
        for ($i=$files.Count-1;$i -ge 0;$i--) {
            $entry=$files[$i]
            if ($entry.status -in @('applied','applying','prepared')) { Restore-ManifestFile $entry }
        }
        $manifest.status='rolled_back'; Save-Manifest -Manifest $manifest -Path $path
    }
    [IO.File]::Delete($script:HistoryActivePath)
    $script:FileCertificates.Clear()
}
