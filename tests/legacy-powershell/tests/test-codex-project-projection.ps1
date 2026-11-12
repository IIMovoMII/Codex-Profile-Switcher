#requires -Version 7.0

[CmdletBinding()]
param()
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot


Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptPath = Join-Path $script:ProjectRoot "codex-project-projection.ps1"
$sqlite = (Get-Command sqlite3.exe -ErrorAction Stop).Source
$utf8 = New-Object Text.UTF8Encoding($false)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-project-projection-test-" + [Guid]::NewGuid().ToString("N"))

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-Sql {
    param([string]$Path, [string]$Sql, [switch]$ReadOnly)
    $arguments = @("-batch", "-bail", "-noheader", "-cmd", ".timeout 5000")
    if ($ReadOnly) { $arguments = @("-readonly") + $arguments }
    $output = @($Sql | & $sqlite @arguments $Path 2>&1)
    if ($LASTEXITCODE -ne 0) { throw ($output -join " | ") }
    return @($output | ForEach-Object { [string]$_ })
}

try {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $fixtureHome = Join-Path $testRoot "codex-home"
    $store = Join-Path $testRoot "store"
    [IO.Directory]::CreateDirectory($fixtureHome) | Out-Null
    [IO.Directory]::CreateDirectory($store) | Out-Null
    $db = Join-Path $fixtureHome "state_5.sqlite"
    $global = Join-Path $fixtureHome ".codex-global-state.json"
    $homeKey = [IO.Path]::GetFullPath($fixtureHome).TrimEnd('\')

    [void](Invoke-Sql $db @"
CREATE TABLE projects(id TEXT PRIMARY KEY,name TEXT NOT NULL,position INTEGER NOT NULL,updated_at_ms INTEGER NOT NULL);
CREATE TABLE project_roots(project_id TEXT NOT NULL,position INTEGER NOT NULL,path TEXT NOT NULL,PRIMARY KEY(project_id,position));
CREATE TABLE threads(id TEXT PRIMARY KEY,cwd TEXT,project_id TEXT,archived INTEGER NOT NULL DEFAULT 0,agent_role TEXT);
INSERT INTO projects VALUES('backend-p1','求职',0,1);
INSERT INTO projects VALUES('backend-p2','Codex切换',1,1);
INSERT INTO project_roots VALUES('backend-p1',0,'D:\求职');
INSERT INTO project_roots VALUES('backend-p2',0,'D:\Codex切换');
INSERT INTO threads VALUES('t-by-cwd','\\?\D:\求职',NULL,0,NULL);
INSERT INTO threads VALUES('t-explicit','\\?\D:\求职',NULL,0,NULL);
INSERT INTO threads VALUES('t-projectless','\\?\D:\求职',NULL,0,NULL);
INSERT INTO threads VALUES('t-unknown','\\?\C:\Temp',NULL,0,NULL);
INSERT INTO threads VALUES('t-subagent','\\?\D:\求职',NULL,0,'guardian');
INSERT INTO threads VALUES('t-hidden-source','\\?\D:\求职',NULL,0,NULL);
ALTER TABLE threads ADD COLUMN source TEXT DEFAULT 'vscode';
UPDATE threads SET source='{"subagent":{"other":"guardian"}}' WHERE id='t-hidden-source';
"@)

    $globalValue = [ordered]@{
        "local-projects" = [ordered]@{
            "legacy-p1" = [ordered]@{ id = "legacy-p1"; name = "求职"; rootPaths = @("D:\求职") }
            "legacy-p2" = [ordered]@{ id = "legacy-p2"; name = "Codex切换"; rootPaths = @("D:\Codex切换") }
        }
        "app-server-project-id-by-legacy-project-id-by-host" = [ordered]@{
            ("local:" + $homeKey) = [ordered]@{ "legacy-p1" = "backend-p1"; "legacy-p2" = "backend-p2" }
        }
        "thread-project-assignments" = [ordered]@{
            "t-explicit" = [ordered]@{ projectKind = "local"; projectId = "legacy-p2" }
        }
        "projectless-thread-ids" = @("t-projectless")
    }
    [IO.File]::WriteAllText($global, (($globalValue | ConvertTo-Json -Depth 12) + [Environment]::NewLine), $utf8)
    $globalBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes($global))

    $output = @(& pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath `
        -Command repair -CodexHome $fixtureHome -BackupRoot $store -SkipProcessGate -InferFromCwd 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) ("Projection repair failed: " + ($output -join " | "))
    $rows = @(Invoke-Sql $db "SELECT id||'='||coalesce(project_id,'') FROM threads ORDER BY id;" -ReadOnly)
    Assert-True (($rows -join "`n") -match "t-by-cwd=backend-p1") "CWD project assignment was not materialized."
    Assert-True (($rows -join "`n") -match "t-explicit=backend-p2") "Explicit project assignment did not win over CWD."
    Assert-True (($rows -join "`n") -match "t-projectless=") "Projectless thread was not kept in Recent."
    Assert-True (($rows -join "`n") -match "t-unknown=") "Unknown-root thread was changed."
    Assert-True ($rows -contains 't-subagent=') "Subagent project was changed."
    Assert-True ($rows -contains 't-hidden-source=') "Source-only subagent project was changed."
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($global)) -ceq $globalBefore) "Desktop global state was modified."

    $manifests = @(Get-ChildItem -LiteralPath $store -Filter manifest.json -Recurse -File)
    Assert-True ($manifests.Count -eq 1) "Repair did not create exactly one manifest."
    $manifest = Get-Content -Raw -LiteralPath $manifests[0].FullName | ConvertFrom-Json
    Assert-True ($manifest.status -ceq "complete" -and $manifest.planned_changes -eq 2) "Repair manifest is incorrect."

    $repeat = @(& pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath `
        -Command repair -CodexHome $fixtureHome -BackupRoot $store -SkipProcessGate 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) ("Idempotent projection repair failed: " + ($repeat -join " | "))
    $manifestsAfter = @(Get-ChildItem -LiteralPath $store -Filter manifest.json -Recurse -File)
    Assert-True ($manifestsAfter.Count -eq 1) "Idempotent repair created an unnecessary second backup."
    Assert-True (($repeat -join "`n") -match "无需写入") "Idempotent repair did not report a clean projection."

    # Ordinary checks must not repeatedly undo historical data. Such cleanup
    # belongs to a separate one-time operation, outside this switcher.
    [void](Invoke-Sql $db "UPDATE threads SET project_id='backend-p1' WHERE id='t-hidden-source';")
    $preserve = @(& powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Command repair -CodexHome $fixtureHome -BackupRoot $store -SkipProcessGate 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) ('Explicit-only repair failed: ' + ($preserve -join ' | '))
    $hiddenProject = @(Invoke-Sql $db "SELECT coalesce(project_id,'NULL') FROM threads WHERE id='t-hidden-source';" -ReadOnly)
    Assert-True ($hiddenProject[0] -ceq 'backend-p1') 'Ordinary repair changed a historical subagent assignment.'
    [void](Invoke-Sql $db "UPDATE threads SET project_id=NULL WHERE id='t-by-cwd';")
    $safeDefault = @(& pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath -Command repair -CodexHome $fixtureHome -BackupRoot $store -SkipProcessGate 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) ('Default explicit-only repair failed: ' + ($safeDefault -join ' | '))
    $cwdProject = @(Invoke-Sql $db "SELECT coalesce(project_id,'NULL') FROM threads WHERE id='t-by-cwd';" -ReadOnly)
    Assert-True ($cwdProject[0] -ceq 'NULL') 'Default repair inferred membership from CWD.'

    # The preflight must see the configured inactive account without rewriting
    # the global state, and must never guess another account by enumeration.
    $owner = 'b' * 64
    $otherOwner = 'a' * 64
    $foreign = @{ 'local-projects' = @{}; 'thread-project-assignments' = @{ 't-explicit' = @{ projectKind = 'local'; projectId = 'backend-p1' } } }
    $enveloped = @{ 'electron-account-renderer-state-v1' = @{ owner = $null; inactive = @{ $otherOwner = @{ atoms = @{}; globals = $foreign }; $owner = @{ atoms = @{}; globals = $globalValue } } } }
    [IO.File]::WriteAllText($global, (ConvertTo-Json -InputObject $enveloped -Depth 20), $utf8)
    $stateHash = (Get-FileHash -LiteralPath $global).Hash
    [void](Invoke-Sql $db "UPDATE threads SET project_id=NULL WHERE id='t-explicit';")
    $unknown = @(& pwsh -NoLogo -NoProfile -File $scriptPath -Command repair -CodexHome $fixtureHome -BackupRoot $store -SkipProcessGate -DesktopOwner ('c' * 64) 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) ('Unknown account scan failed: ' + ($unknown -join ' | '))
    Assert-True ((@(Invoke-Sql $db "SELECT coalesce(project_id,'NULL') FROM threads WHERE id='t-explicit';" -ReadOnly))[0] -ceq 'NULL') 'Preflight guessed an unrelated account.'
    $inactive = @(& powershell -NoLogo -NoProfile -File $scriptPath -Command repair -CodexHome $fixtureHome -BackupRoot $store -SkipProcessGate -DesktopOwner $owner 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) ('Inactive account projection failed: ' + ($inactive -join ' | '))
    Assert-True ((@(Invoke-Sql $db "SELECT project_id FROM threads WHERE id='t-explicit';" -ReadOnly))[0] -ceq 'backend-p2') 'Configured inactive projection was not used.'
    Assert-True ((Get-FileHash -LiteralPath $global).Hash -ceq $stateHash) 'Inactive preflight rewrote Desktop state.'

    # A prior switch can have moved that account into the encrypted archive.
    $archive = @{ version = 1; codex_home = $homeKey; profiles = @{ $owner = @{ atoms = @{}; globals = $globalValue } }; api = @{ atoms = @{}; globals = @{} } }
    $archivePath = Join-Path $store 'desktop-renderer-state.dpapi'
    $plain = $utf8.GetBytes((ConvertTo-Json -InputObject $archive -Depth 20))
    try { $protected = [Security.Cryptography.ProtectedData]::Protect($plain, $utf8.GetBytes('CodexProfileSwitcher/v1|' + $homeKey), [Security.Cryptography.DataProtectionScope]::CurrentUser) }
    finally { [Array]::Clear($plain, 0, $plain.Length) }
    [IO.File]::WriteAllBytes($archivePath, $protected)
    [IO.File]::WriteAllText($global, '{}', $utf8)
    [void](Invoke-Sql $db "UPDATE threads SET project_id=NULL WHERE id='t-explicit';")
    $archiveHash = (Get-FileHash -LiteralPath $archivePath).Hash
    $archived = @(& pwsh -NoLogo -NoProfile -File $scriptPath -Command repair -CodexHome $fixtureHome -BackupRoot $store -SkipProcessGate -DesktopOwner $owner -RendererArchivePath $archivePath 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) ('Archived account projection failed: ' + ($archived -join ' | '))
    Assert-True ((@(Invoke-Sql $db "SELECT project_id FROM threads WHERE id='t-explicit';" -ReadOnly))[0] -ceq 'backend-p2') 'Archived projection was not used.'
    Assert-True ((Get-FileHash -LiteralPath $archivePath).Hash -ceq $archiveHash -and [IO.File]::ReadAllText($global) -ceq '{}') 'Archive preflight changed its sources.'
    [IO.File]::WriteAllText($global, '{"local-projects":{}}', $utf8)
    [void](Invoke-Sql $db "UPDATE threads SET project_id=NULL WHERE id='t-explicit';")
    $emptyList = @(& pwsh -NoLogo -NoProfile -File $scriptPath -Command repair -CodexHome $fixtureHome -BackupRoot $store -SkipProcessGate -DesktopOwner $owner -RendererArchivePath $archivePath 2>&1)
    Assert-True ($LASTEXITCODE -eq 0) ('Empty local list failed: ' + ($emptyList -join ' | '))
    Assert-True ((@(Invoke-Sql $db "SELECT coalesce(project_id,'NULL') FROM threads WHERE id='t-explicit';" -ReadOnly))[0] -ceq 'NULL') 'Explicit empty local list was resurrected from archive.'

    Write-Host ("Codex project projection tests passed: active/inactive/archive identity, explicit empty list, no source-state writes, PS 5.1/7. " + $PSVersionTable.PSVersion)
}
finally {
    if ([IO.Directory]::Exists($testRoot)) {
        $resolved = [IO.Path]::GetFullPath($testRoot)
        $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not $resolved.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'codex-project-projection-test-*') { throw 'Unsafe test cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
