#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("scan", "repair")]
    [string]$Command = "scan",

    [string]$CodexHome,
    [string]$BackupRoot,
    [ValidatePattern('^[a-f0-9]{64}$')][string]$DesktopOwner,
    [string]$RendererArchivePath,
    [switch]$InferFromCwd,
    [switch]$SkipProcessGate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
try {
    $utf8 = New-Object Text.UTF8Encoding($false)
    [Console]::InputEncoding = $utf8
    [Console]::OutputEncoding = $utf8
    $global:OutputEncoding = $utf8
} catch {}

if ($env:OS -ne "Windows_NT") {
    throw "项目归属投影处理目前只支持 Windows。"
}

function Resolve-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path)).TrimEnd([IO.Path]::DirectorySeparatorChar)
}

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    $CodexHome = if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        $env:CODEX_HOME
    }
    else {
        Join-Path $env:USERPROFILE ".codex"
    }
}
$CodexHome = Resolve-NormalizedPath $CodexHome
if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
    $localDataRoot = if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $env:LOCALAPPDATA } else { Join-Path $env:USERPROFILE "AppData\Local" }
    $BackupRoot = Join-Path $localDataRoot "CodexProfileSwitcher\project-projection-repair"
}
$BackupRoot = Resolve-NormalizedPath $BackupRoot
$StateDatabase = Join-Path $CodexHome "state_5.sqlite"
$GlobalStatePath = Join-Path $CodexHome ".codex-global-state.json"

function Get-JsonValue {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) {
        return $Object[$Name]
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-SqliteExecutable {
    $command = Get-Command "sqlite3.exe" -ErrorAction SilentlyContinue
    if ($null -eq $command) { $command = Get-Command "sqlite3" -ErrorAction SilentlyContinue }
    if ($null -eq $command) { throw "找不到 sqlite3.exe，无法检查项目归属投影。" }
    return [string]$command.Source
}

function ConvertFrom-HexUtf8 {
    param([AllowEmptyString()][string]$Hex)
    if ([string]::IsNullOrWhiteSpace($Hex)) { return "" }
    if (($Hex.Length % 2) -ne 0 -or $Hex -notmatch '^[0-9A-Fa-f]+$') {
        throw "SQLite 返回了无效的 UTF-8 十六进制值。"
    }
    $bytes = [byte[]]::new([int]($Hex.Length / 2))
    for ($index = 0; $index -lt $bytes.Length; $index++) {
        $bytes[$index] = [Convert]::ToByte($Hex.Substring($index * 2, 2), 16)
    }
    try {
        return (New-Object Text.UTF8Encoding($false, $true)).GetString($bytes)
    }
    finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function ConvertTo-SqlLiteral {
    param([AllowEmptyString()][string]$Value)
    return "'" + $Value.Replace("'", "''") + "'"
}

function Invoke-SqliteText {
    param(
        [Parameter(Mandatory = $true)][string]$DatabasePath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Sql,
        [switch]$ReadOnly
    )
    $sqlite = Get-SqliteExecutable
    $arguments = @("-batch", "-bail", "-noheader", "-cmd", ".timeout 5000")
    if ($ReadOnly) { $arguments = @("-readonly") + $arguments }
    $databaseArgument = ([Uri][IO.Path]::GetFullPath($DatabasePath)).AbsoluteUri
    $output = @($Sql | & $sqlite @arguments $databaseArgument 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "SQLite 操作失败（$DatabasePath）：$($output -join '; ')"
    }
    return @($output | ForEach-Object { [string]$_ })
}

function Invoke-SqliteJsonRows {
    param(
        [Parameter(Mandatory = $true)][string]$DatabasePath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Sql
    )
    $sqlite = Get-SqliteExecutable
    $databaseArgument = ([Uri][IO.Path]::GetFullPath($DatabasePath)).AbsoluteUri
    $output = @($Sql | & $sqlite -readonly -json -batch -bail -cmd ".timeout 5000" $databaseArgument 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "SQLite 查询失败（$DatabasePath）：$($output -join '; ')"
    }
    $text = [string]::Join([Environment]::NewLine, @($output | ForEach-Object { [string]$_ }))
    if ([string]::IsNullOrWhiteSpace($text) -or $text -eq "[]") { return @() }
    try {
        # Windows PowerShell 5.1 keeps a JSON array as one pipeline item.
        # Enumerate explicitly so row counts and hex fields match PowerShell 7.
        $rows = ConvertFrom-Json -InputObject $text
        foreach ($row in $rows) { Write-Output $row }
    }
    catch {
        throw "SQLite 查询结果不是合法 JSON：$($_.Exception.Message)"
    }
}

function Write-Manifest {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Value)
    $json = ($Value | ConvertTo-Json -Depth 12) + [Environment]::NewLine
    [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
}

function Normalize-ProjectPath {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
    $value = $Path.Replace('/', '\')
    $extendedPrefix = '\\?\'
    if ($value.StartsWith($extendedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        $value = $value.Substring($extendedPrefix.Length)
    }
    return $value.TrimEnd([char[]]@('\', '/')).ToLowerInvariant()
}

function Assert-ProjectRepairProcessGate {
    if ($SkipProcessGate -or $Command -eq 'scan') { return }
    $busy = @(
        Get-Process -Name "codex", "codex-code-mode-host", "ChatGPT" -ErrorAction SilentlyContinue
    )
    if ($busy.Count -gt 0) {
        $summary = ($busy | ForEach-Object { "$($_.ProcessName):$($_.Id)" }) -join ", "
        throw "请先关闭 Codex Desktop 和全部 Codex CLI 进程。仍在运行：$summary"
    }
}

function Read-ProjectionData {
    param([Parameter(Mandatory = $true)][string]$DatabasePath)

    $projectRows = @(Invoke-SqliteJsonRows -DatabasePath $DatabasePath -Sql @"
SELECT hex(id) AS id_hex, hex(name) AS name_hex
FROM projects
ORDER BY position, updated_at_ms DESC;
"@)
    $rootRows = @(Invoke-SqliteJsonRows -DatabasePath $DatabasePath -Sql @"
SELECT hex(project_id) AS project_id_hex, position, hex(path) AS path_hex
FROM project_roots
ORDER BY project_id, position;
"@)
    $columns = @(Invoke-SqliteJsonRows -DatabasePath $DatabasePath -Sql "PRAGMA table_info(threads);")
    $sourceExpression = if (@($columns | Where-Object { $_.name -ceq 'source' }).Count -gt 0) { 'hex(source)' } else { "''" }
    $threadRows = @(Invoke-SqliteJsonRows -DatabasePath $DatabasePath -Sql @"
SELECT hex(id) AS id_hex, hex(cwd) AS cwd_hex, hex(project_id) AS project_id_hex,
       archived, hex(agent_role) AS agent_role_hex, $sourceExpression AS source_hex
FROM threads;
"@)

    $projects = @{}
    foreach ($row in $projectRows) {
        $id = ConvertFrom-HexUtf8 ([string]$row.id_hex)
        if ([string]::IsNullOrWhiteSpace($id)) { throw "projects 表出现空项目 ID。" }
        $projects[$id] = [pscustomobject]@{
            Id = $id
            Name = ConvertFrom-HexUtf8 ([string]$row.name_hex)
        }
    }

    $roots = New-Object System.Collections.Generic.List[object]
    foreach ($row in $rootRows) {
        $projectId = ConvertFrom-HexUtf8 ([string]$row.project_id_hex)
        $path = ConvertFrom-HexUtf8 ([string]$row.path_hex)
        if (-not $projects.ContainsKey($projectId) -or [string]::IsNullOrWhiteSpace($path)) { continue }
        $roots.Add([pscustomobject]@{
            ProjectId = $projectId
            Path = $path
            PathKey = Normalize-ProjectPath $path
        })
    }

    $threads = New-Object System.Collections.Generic.List[object]
    foreach ($row in $threadRows) {
        $source = ConvertFrom-HexUtf8 ([string]$row.source_hex)
        $isSubagent = $source -eq 'subagent'
        if ($source.StartsWith('{')) {
            try { $isSubagent = $null -ne (Get-JsonValue ($source | ConvertFrom-Json) 'subagent') }
            catch { $isSubagent = $true } # Unknown structured source: do not infer.
        }
        $threads.Add([pscustomobject]@{
            Id = ConvertFrom-HexUtf8 ([string]$row.id_hex)
            Cwd = ConvertFrom-HexUtf8 ([string]$row.cwd_hex)
            ProjectId = ConvertFrom-HexUtf8 ([string]$row.project_id_hex)
            Archived = [int]$row.archived
            AgentRole = ConvertFrom-HexUtf8 ([string]$row.agent_role_hex)
            IsSubagent = $isSubagent
        })
    }
    return [pscustomobject]@{ Projects = $projects; Roots = $roots.ToArray(); Threads = $threads.ToArray() }
}

function Resolve-BackendProjectId {
    param(
        [AllowNull()]$LegacyProjectId,
        [AllowNull()]$Mapping,
        [AllowNull()]$LegacyRootToBackend,
        [AllowNull()]$LegacyProjects,
        [Parameter(Mandatory = $true)][hashtable]$KnownProjects
    )
    if ($null -eq $LegacyProjectId) { return $null }
    $legacy = [string]$LegacyProjectId
    if ([string]::IsNullOrWhiteSpace($legacy)) { return $null }
    $mapped = Get-JsonValue $Mapping $legacy
    if (-not [string]::IsNullOrWhiteSpace([string]$mapped) -and $KnownProjects.ContainsKey([string]$mapped)) {
        return [string]$mapped
    }
    if ($KnownProjects.ContainsKey($legacy)) { return $legacy }
    $legacyProject = Get-JsonValue $LegacyProjects $legacy
    $rootPaths = Get-JsonValue $legacyProject "rootPaths"
    foreach ($root in @($rootPaths)) {
        $candidate = Get-JsonValue $LegacyRootToBackend (Normalize-ProjectPath ([string]$root))
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) { return [string]$candidate }
    }
    return $null
}

function Read-GlobalProjection {
    if (-not [IO.File]::Exists($GlobalStatePath)) {
        return [pscustomobject]@{
            Exists = $false
            Root = $null
            Assignments = $null
            Projectless = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            Mapping = $null
            LegacyProjects = $null
            HostIds = $null
        }
    }
    try {
        $root = [IO.File]::ReadAllText($GlobalStatePath) | ConvertFrom-Json
    }
    catch {
        throw "无法读取 Desktop 全局项目状态：$GlobalStatePath；$($_.Exception.Message)"
    }
    if ($root -isnot [pscustomobject]) { throw 'Invalid Desktop global state: expected object.' }
    # An explicitly empty list is authoritative. Only a missing list can be
    # recovered, and only from the configured identity, never an arbitrary one.
    if ($null -eq $root.PSObject.Properties['local-projects'] -and -not [string]::IsNullOrWhiteSpace($DesktopOwner)) {
        $envelope = Get-JsonValue $root 'electron-account-renderer-state-v1'
        $profile = Get-JsonValue (Get-JsonValue $envelope 'inactive') $DesktopOwner
        $globals = Get-JsonValue $profile 'globals'
        if ($null -eq (Get-JsonValue $globals 'local-projects') -and
            -not [string]::IsNullOrWhiteSpace($RendererArchivePath) -and [IO.File]::Exists($RendererArchivePath)) {
            $protected = [IO.File]::ReadAllBytes($RendererArchivePath)
            $plain = $null
            try {
                Add-Type -AssemblyName System.Security
                $entropy = $utf8.GetBytes('CodexProfileSwitcher/v1|' + $CodexHome)
                $plain = [Security.Cryptography.ProtectedData]::Unprotect($protected, $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
                $archive = $utf8.GetString($plain) | ConvertFrom-Json
                if ((Get-JsonValue $archive 'version') -ne 1 -or (Get-JsonValue $archive 'codex_home') -ne $CodexHome) { throw 'Invalid renderer archive.' }
                $profile = Get-JsonValue (Get-JsonValue $archive 'profiles') $DesktopOwner
                $globals = Get-JsonValue $profile 'globals'
                if ($null -eq (Get-JsonValue $globals 'local-projects')) { $globals = Get-JsonValue (Get-JsonValue $archive 'api') 'globals' }
            }
            catch { throw 'Cannot read the encrypted Desktop renderer archive; no projection files were changed.' }
            finally {
                [Array]::Clear($protected, 0, $protected.Length)
                if ($null -ne $plain) { [Array]::Clear($plain, 0, $plain.Length) }
            }
        }
        if ($null -ne (Get-JsonValue $globals 'local-projects')) { $root = $globals }
    }
    $projectless = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @(Get-JsonValue $root "projectless-thread-ids")) {
        if (-not [string]::IsNullOrWhiteSpace([string]$id)) { [void]$projectless.Add([string]$id) }
    }
    $hostKey = "local:" + $CodexHome
    $mappingByHost = Get-JsonValue $root "app-server-project-id-by-legacy-project-id-by-host"
    $mapping = Get-JsonValue $mappingByHost $hostKey
    return [pscustomobject]@{
        Exists = $true
        Root = $root
        Assignments = Get-JsonValue $root "thread-project-assignments"
        Projectless = $projectless
        Mapping = $mapping
        LegacyProjects = Get-JsonValue $root "local-projects"
        HostIds = Get-JsonValue $root "thread-project-membership-host-ids"
    }
}

function Build-ProjectionPlan {
    param(
        [Parameter(Mandatory = $true)]$Data,
        [Parameter(Mandatory = $true)]$Global
    )

    $knownProjects = @{}
    foreach ($key in $Data.Projects.Keys) { $knownProjects[[string]$key] = $true }
    $rootByKey = @{}
    foreach ($root in $Data.Roots) {
        if ([string]::IsNullOrWhiteSpace($root.PathKey)) { continue }
        if (-not $rootByKey.ContainsKey($root.PathKey) -or $root.PathKey.Length -gt $rootByKey[$root.PathKey].PathKey.Length) {
            $rootByKey[$root.PathKey] = $root
        }
    }
    $legacyRootToBackend = @{}
    foreach ($entry in @($Data.Roots)) { $legacyRootToBackend[$entry.PathKey] = $entry.ProjectId }

    $plan = New-Object System.Collections.Generic.List[object]
    $counts = [ordered]@{
        total = $Data.Threads.Count
        explicit = 0
        cwd = 0
        projectless = 0
        preserved = 0
        unresolved_explicit = 0
        changed = 0
    }
    foreach ($thread in $Data.Threads) {
        if ($thread.IsSubagent -or -not [string]::IsNullOrWhiteSpace($thread.AgentRole)) { continue }
        $current = [string]$thread.ProjectId
        $desired = $null
        $reason = ""
        $assignment = Get-JsonValue $Global.Assignments ([string]$thread.Id)
        $legacyProjectId = Get-JsonValue $assignment "projectId"
        $hostId = [string](Get-JsonValue $Global.HostIds ([string]$thread.Id))
        if (-not [string]::IsNullOrWhiteSpace($hostId) -and $hostId -cne ('local:' + $CodexHome)) { continue }
        if ($null -ne $assignment -and (Get-JsonValue $assignment 'projectKind') -ne 'local') { continue }

        if ($Global.Projectless.Contains([string]$thread.Id)) {
            $counts.projectless++
            if (-not [string]::IsNullOrWhiteSpace($current)) {
                $desired = $null
                $reason = "projectless"
            }
            else {
                continue
            }
        }
        elseif ($null -ne $legacyProjectId) {
            $desired = Resolve-BackendProjectId `
                -LegacyProjectId $legacyProjectId `
                -Mapping $Global.Mapping `
                -LegacyRootToBackend $legacyRootToBackend `
                -LegacyProjects $Global.LegacyProjects `
                -KnownProjects $knownProjects
            if ([string]::IsNullOrWhiteSpace([string]$desired)) {
                $counts.unresolved_explicit++
                continue
            }
            $counts.explicit++
            $reason = "explicit"
        }
        elseif (-not [string]::IsNullOrWhiteSpace($current) -and $knownProjects.ContainsKey($current)) {
            $counts.preserved++
            continue
        }
        else {
            if (-not $InferFromCwd -or $thread.Archived -ne 0) { continue }
            $cwdKey = Normalize-ProjectPath $thread.Cwd
            $matches = @($rootByKey.Values | Where-Object {
                $cwdKey -eq $_.PathKey -or $cwdKey.StartsWith($_.PathKey + '\', [StringComparison]::OrdinalIgnoreCase)
            } | Sort-Object { $_.PathKey.Length } -Descending)
            if ($matches.Count -eq 0) { continue }
            $bestLength = $matches[0].PathKey.Length
            $bestProjects = @($Data.Roots | Where-Object { $_.PathKey.Length -eq $bestLength -and $_.PathKey -eq $matches[0].PathKey } | Select-Object -ExpandProperty ProjectId -Unique)
            if ($bestProjects.Count -ne 1) { continue }
            $desired = [string]$matches[0].ProjectId
            $counts.cwd++
            $reason = "cwd"
        }

        if ([string]$desired -cne $current) {
            $plan.Add([pscustomobject]@{ Id = [string]$thread.Id; OldProjectId = if ([string]::IsNullOrWhiteSpace($current)) { $null } else { $current }; ProjectId = if ([string]::IsNullOrWhiteSpace([string]$desired)) { $null } else { [string]$desired }; Reason = $reason })
            $counts.changed++
        }
    }
    return [pscustomobject]@{ Plan = $plan.ToArray(); Counts = $counts; ProjectCount = $Data.Projects.Count; ThreadCount = $Data.Threads.Count }
}

function New-RepairDirectory {
    [IO.Directory]::CreateDirectory($BackupRoot) | Out-Null
    $name = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ") + "-" + [Guid]::NewGuid().ToString("N")
    $path = Join-Path $BackupRoot $name
    [IO.Directory]::CreateDirectory($path) | Out-Null
    return $path
}

function Invoke-ProjectionRepair {
    Assert-ProjectRepairProcessGate
    if (-not [IO.File]::Exists($StateDatabase)) {
        Write-Host "项目归属投影：找不到 state_5.sqlite，未做修改。"
        return
    }
    $data = Read-ProjectionData -DatabasePath $StateDatabase
    $global = Read-GlobalProjection
    $analysis = Build-ProjectionPlan -Data $data -Global $global
    Write-Host ("项目归属投影：{0} 个项目，{1} 条对话，待补齐 {2} 条（明确归属 {3}，工作目录 {4}，需保持最近 {5}）。" -f
        $analysis.ProjectCount, $analysis.ThreadCount, $analysis.Counts.changed, $analysis.Counts.explicit, $analysis.Counts.cwd, $analysis.Counts.projectless)
    if ($analysis.Counts.unresolved_explicit -gt 0) {
        Write-Warning ("有 {0} 条明确项目归属无法映射到当前项目表，已保留原状。" -f $analysis.Counts.unresolved_explicit)
    }
    if ($Command -eq "scan" -or $analysis.Counts.changed -eq 0) {
        if ($analysis.Counts.changed -eq 0) { Write-Host "项目归属投影已经完整，无需写入。" }
        return
    }

    $repairDirectory = New-RepairDirectory
    $backupDatabase = Join-Path $repairDirectory "state_5.sqlite"
    $backupGlobal = Join-Path $repairDirectory ".codex-global-state.json"
    $manifestPath = Join-Path $repairDirectory "manifest.json"
    $backupSql = ".backup " + (ConvertTo-SqlLiteral $backupDatabase)
    [void](Invoke-SqliteText -DatabasePath $StateDatabase -Sql $backupSql)
    if (-not [IO.File]::Exists($backupDatabase)) {
        throw "无法创建 WAL 感知的状态数据库备份。"
    }
    $backupCheck = @(Invoke-SqliteText -DatabasePath $backupDatabase -Sql "PRAGMA quick_check;" -ReadOnly)
    if ($backupCheck.Count -ne 1 -or $backupCheck[0] -cne "ok") {
        throw "状态数据库备份未通过 quick_check。"
    }
    if ($global.Exists) { [IO.File]::Copy($GlobalStatePath, $backupGlobal, $true) }

    $manifest = [ordered]@{
        version = 1
        status = "prepared"
        started_utc = [DateTime]::UtcNow.ToString("o")
        codex_home = $CodexHome
        state_database = $StateDatabase
        backup_database = $backupDatabase
        global_state = $GlobalStatePath
        backup_global_state = if ($global.Exists) { $backupGlobal } else { "" }
        project_count = $analysis.ProjectCount
        thread_count = $analysis.ThreadCount
        planned_changes = $analysis.Counts.changed
        explicit_changes = $analysis.Counts.explicit
        cwd_changes = $analysis.Counts.cwd
        projectless_kept = $analysis.Counts.projectless
        unresolved_explicit = $analysis.Counts.unresolved_explicit
        changes = @($analysis.Plan | ForEach-Object { [ordered]@{ id = $_.Id; old_project_id = $_.OldProjectId; project_id = $_.ProjectId; reason = $_.Reason } })
        global_state_modified = $false
    }
    Write-Manifest -Path $manifestPath -Value $manifest

    $statements = New-Object System.Collections.Generic.List[string]
    $statements.Add("PRAGMA busy_timeout=5000;")
    $statements.Add("BEGIN IMMEDIATE;")
    foreach ($change in $analysis.Plan) {
        $value = if ($null -eq $change.ProjectId) { "NULL" } else { ConvertTo-SqlLiteral ([string]$change.ProjectId) }
        $statements.Add("UPDATE threads SET project_id=$value WHERE id=$(ConvertTo-SqlLiteral ([string]$change.Id));")
    }
    # sqlite3 -bail closes this connection and rolls back the open transaction
    # if a statement or quick_check fails, before COMMIT can run.
    $statements.Add("CREATE TEMP TABLE projection_check(ok TEXT CHECK(ok='ok'));")
    $statements.Add("INSERT INTO projection_check SELECT * FROM pragma_quick_check;")
    $statements.Add("COMMIT;")
    try {
        [void](Invoke-SqliteText -DatabasePath $StateDatabase -Sql ([string]::Join("`n", $statements)))
        $quickCheck = @(Invoke-SqliteText -DatabasePath $StateDatabase -Sql "PRAGMA quick_check;" -ReadOnly)
        if ($quickCheck.Count -ne 1 -or $quickCheck[0] -cne "ok") {
            throw "项目归属写入后 state_5.sqlite 未通过 quick_check。"
        }
        $manifest.status = "complete"
        $manifest.completed_utc = [DateTime]::UtcNow.ToString("o")
        Write-Manifest -Path $manifestPath -Value $manifest
    }
    catch {
        $manifest.status = "failed"
        $manifest.failed_utc = [DateTime]::UtcNow.ToString("o")
        $manifest.error = [string]$_.Exception.Message
        Write-Manifest -Path $manifestPath -Value $manifest
        throw
    }

    Write-Host "项目归属投影修复完成：已写入 $($analysis.Counts.changed) 条 threads.project_id。"
    Write-Host "未修改 .codex-global-state.json；数据库备份：$backupDatabase"
    Write-Host "修复清单：$manifestPath"
}

Invoke-ProjectionRepair
