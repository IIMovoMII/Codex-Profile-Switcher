#requires -Version 7.0
[CmdletBinding()]
param()
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot


Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-desktop-state-test-' + [Guid]::NewGuid().ToString('N'))
$utf8 = [Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$global:OutputEncoding = $utf8
$switcher = Join-Path $script:ProjectRoot 'codex-profile-switcher.ps1'

function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Write-Json([string]$Path, $Value) { [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 100 -Compress), $utf8) }
function Read-Json([string]$Path) { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable }
function Get-Hash([string]$Path) { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function Invoke-TestAction([string]$Action, [string]$Engine = 'pwsh', [switch]$Fail) {
    $output = @(& $Engine -NoLogo -NoProfile -ExecutionPolicy Bypass -File $switcher -Command $Action -CodexHome $fixtureHome -DataDir $store -MonitorDataDir (Join-Path $store 'monitor') -CodexExecutable $fakeCodex -UnsafeAllowRunningCodex 2>&1)
    if ($Fail) { Assert-True ($LASTEXITCODE -ne 0) 'Expected failure did not occur.' }
    else { Assert-True ($LASTEXITCODE -eq 0) ("Action $Action failed: " + ($output -join ' | ')) }
    return ($output -join "`n")
}

try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    $fixtureHome = Join-Path $testRoot '中文-CODEX目录'
    $store = Join-Path $testRoot '中文-状态目录'
    [void][IO.Directory]::CreateDirectory($fixtureHome)
    $config = Join-Path $fixtureHome 'config.toml'
    $authPath = Join-Path $fixtureHome 'auth.json'
    $globalPath = Join-Path $fixtureHome '.codex-global-state.json'
    [IO.File]::WriteAllText($config, "model_provider = `"openai`"`ncli_auth_credentials_store = `"file`"`n", $utf8)
    $claim = @{ 'https://api.openai.com/auth' = @{ chatgpt_user_id = 'user-local-test'; chatgpt_account_id = 'account-local-test' } }
    $payload = [Convert]::ToBase64String($utf8.GetBytes((ConvertTo-Json -InputObject $claim -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $auth = @{ auth_mode = 'chatgpt'; tokens = @{ id_token = "test.$payload.signature"; access_token = "test.$payload.signature"; refresh_token = 'fixture'; account_id = 'account-local-test' } }
    Write-Json $authPath $auth
    $owner = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($utf8.GetBytes('["user-local-test","account-local-test"]'))).ToLowerInvariant()
    $otherOwner = 'a' * 64
    $localHost = 'local:' + $fixtureHome
    $officialGlobals = @{
        'local-projects' = @{ local1 = @{ id = 'local1'; name = '中文项目'; rootPaths = @('D:\中文项目') } }
        'thread-project-assignments' = @{
            localThread = @{ projectKind = 'local'; projectId = 'local1' }
            remoteThread = @{ projectKind = 'local'; projectId = 'remote1' }
            cloudThread = @{ projectKind = 'chatgpt'; projectId = 'cloud1' }
        }
        'thread-project-membership-host-ids' = @{ localThread = $localHost; remoteThread = 'ssh:elsewhere' }
        'projectless-thread-ids' = @('localRecent')
        'project-order' = @('local1')
        'selected-project' = @{ projectKind = 'chatgpt'; projectId = 'cloud1' }
        'queued-follow-ups' = @{ private = 'official-only' }
    }
    $otherProfile = @{ atoms = @{ cloud = 'other-account' }; globals = @{ 'local-projects' = @{ foreign = @{ name = 'Other'; rootPaths = @('Z:\Other') } } } }
    $welcome = @{ completedConversationalOnboarding = $true; conversationalOnboardingSkipped = $true; roles = @('engineering'); workMode = 'coding'; personalizedSuggestionsEnabled = $false }
    $root = @{
        'electron-persisted-atom-state' = @{ 'last_completed_onboarding' = 12345; 'electron:onboarding-projectless-completed' = $true; 'electron:onboarding-welcome-v2-role-state' = $welcome }
        'electron-account-renderer-state-v1' = @{
            owner = $null
            inactive = @{
                $owner = @{ atoms = @{ 'cloud-cache' = 'official-private'; 'electron:onboarding-welcome-pending' = $true }; globals = $officialGlobals }
                $otherOwner = $otherProfile
            }
        }
        'unrelated-device-data' = @{ value = 'preserve'; nested = @(@('a', 'b'), @(), @(1, @(2, 3))) }
    }
    $fakeCodex = Join-Path $testRoot 'fake-codex.ps1'
    [IO.File]::WriteAllText($fakeCodex, @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
if ($env:DESKTOP_STATE_TEST_FAIL -eq '1') { exit 2 }
$auth = Get-Content -LiteralPath (Join-Path $env:CODEX_HOME 'auth.json') -Raw | ConvertFrom-Json
if ($null -ne $auth.PSObject.Properties['tokens']) { Write-Output 'Logged in using ChatGPT' }
else { Write-Output 'Logged in using an API key' }
exit 0
'@, $utf8)
    $normalFakeCodex = [IO.File]::ReadAllText($fakeCodex)
    [void](Invoke-TestAction init)
    $apiAuth = @{ OPENAI_API_KEY = 'fixture-key' }
    Write-Json $authPath $apiAuth
    [IO.File]::WriteAllText($config, "model_provider = `"openai`"`nopenai_base_url = `"https://relay.example/v1`"`ncli_auth_credentials_store = `"file`"`n", $utf8)
    [void](Invoke-TestAction init)
    Write-Json $globalPath $root
    Write-Json ($globalPath + '.bak') $root
    $sqlite = (Get-Command sqlite3.exe -ErrorAction Stop).Source
    $database = Join-Path $fixtureHome 'state_5.sqlite'
    $databaseArgument = ([Uri][IO.Path]::GetFullPath($database)).AbsoluteUri
    $sql = "CREATE TABLE projects(id TEXT PRIMARY KEY,name TEXT,position INTEGER,updated_at_ms INTEGER); CREATE TABLE project_roots(project_id TEXT,position INTEGER,path TEXT); CREATE TABLE threads(id TEXT PRIMARY KEY,cwd TEXT,project_id TEXT,archived INTEGER DEFAULT 0,agent_role TEXT,source TEXT); INSERT INTO projects VALUES('backend1','fixture',0,1); INSERT INTO project_roots VALUES('backend1',0,'D:\中文项目'); INSERT INTO threads(id,cwd,source) VALUES('localThread','D:\中文项目','vscode');"
    $sql | & $sqlite -batch -bail $databaseArgument
    Assert-True ($LASTEXITCODE -eq 0) 'Unable to create disposable project database.'

    $before = Get-Hash $globalPath
    $scan = Invoke-TestAction desktop-scan
    Assert-True ($scan.Contains('1 个本地项目')) 'Scan did not select the configured official profile.'
    Assert-True ((Get-Hash $globalPath) -ceq $before) 'Scan wrote live global state.'
    [void](Invoke-TestAction desktop-repair powershell)
    $backups = @(Get-ChildItem -LiteralPath (Join-Path $store 'desktop-state-backups') -Filter manifest.json -Recurse -File)
    Assert-True ($backups.Count -eq 1) 'One Desktop repair should create one state plan/backup, not duplicate preflight writes.'
    $project = @(& $sqlite -readonly -noheader $databaseArgument "SELECT project_id FROM threads WHERE id='localThread';")
    Assert-True ($LASTEXITCODE -eq 0 -and $project.Count -eq 1 -and $project[0] -ceq 'backend1') 'Preflight missed the official inactive membership before the Desktop transaction.'
    $g = Read-Json $globalPath
    Assert-True (-not $g.Contains('electron-account-renderer-state-v1')) 'Anonymous startup would clear the state again.'
    Assert-True ($g['local-projects']['local1']['name'] -ceq '中文项目') 'Chinese local project was not restored.'
    Assert-True ($g['thread-project-assignments'].Contains('localThread') -and -not $g['thread-project-assignments'].Contains('remoteThread') -and -not $g['thread-project-assignments'].Contains('cloudThread')) 'Account-specific assignments leaked to API mode.'
    Assert-True (-not $g.Contains('selected-project') -and -not $g.Contains('queued-follow-ups')) 'Cloud selection or queue leaked to API mode.'
    Assert-True (-not $g['electron-persisted-atom-state'].Contains('cloud-cache')) 'Official atom leaked to API mode.'
    Assert-True ($g['electron-persisted-atom-state']['electron:onboarding-welcome-v2-role-state']['personalizedSuggestionsEnabled'] -eq $false) 'User onboarding preference changed.'
    Assert-True ($g['electron-persisted-atom-state']['electron:onboarding-welcome-pending'] -eq $false) 'Completed welcome remains pending.'
    Assert-True ($g['unrelated-device-data']['value'] -ceq 'preserve') 'Unrelated global state changed.'
    Assert-True ($g['unrelated-device-data']['nested'].Count -eq 3 -and $g['unrelated-device-data']['nested'][1].Count -eq 0 -and $g['unrelated-device-data']['nested'][2][1].Count -eq 2) 'Nested JSON arrays were flattened.'
    Assert-True ((Get-Hash $globalPath) -ceq (Get-Hash ($globalPath + '.bak'))) 'Fallback .bak does not match repaired global state.'
    $archivePath = Join-Path $store 'desktop-renderer-state.dpapi'
    $archiveBytes = [IO.File]::ReadAllBytes($archivePath)
    $entropy = $utf8.GetBytes('CodexProfileSwitcher/v1|' + $fixtureHome)
    $plain = [Security.Cryptography.ProtectedData]::Unprotect($archiveBytes, $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    try {
        $archive = $utf8.GetString($plain) | ConvertFrom-Json -AsHashtable
        Assert-True ($archive['profiles'][$otherOwner]['atoms']['cloud'] -ceq 'other-account') 'Another account archive was modified.'
        Assert-True ($archive['profiles'][$owner]['globals']['queued-follow-ups']['private'] -ceq 'official-only') 'Official archive lost private state.'
    } finally { [Array]::Clear($plain, 0, $plain.Length) }

    # The latest local API changes should return to the same official account.
    $g['local-projects']['local2'] = @{ id = 'local2'; name = '新增项目'; rootPaths = @('D:\新增') }
    $g['project-order'] = @('local2', 'local1')
    $g['thread-project-assignments']['apiNewThread'] = @{ projectKind = 'local'; projectId = 'local2' }
    $g['thread-project-membership-host-ids']['apiNewThread'] = $localHost
    $newSql = "INSERT INTO projects VALUES('backend2','api-new',1,2); INSERT INTO project_roots VALUES('backend2',0,'D:\新增'); INSERT INTO threads(id,cwd,source) VALUES('apiNewThread','D:\unrelated','vscode');"
    $newSql | & $sqlite -batch -bail $databaseArgument
    Assert-True ($LASTEXITCODE -eq 0) 'Unable to create API-new project fixture.'
    Write-Json $globalPath $g
    [void](Invoke-TestAction config-official)
    $g = Read-Json $globalPath
    Assert-True ($g['local-projects'].Count -eq 2) 'Latest local project did not follow the switch.'
    Assert-True ($g['electron-persisted-atom-state']['cloud-cache'] -ceq 'official-private') 'Official account state was not restored.'
    Assert-True ($g['selected-project']['projectId'] -ceq 'cloud1') 'Official cloud selection was not restored.'
    $project = @(& $sqlite -readonly -noheader $databaseArgument "SELECT project_id FROM threads WHERE id='apiNewThread';")
    Assert-True ($project.Count -eq 1 -and $project[0] -ceq 'backend2') 'API-new thread membership did not follow the project.'
    [void](Invoke-TestAction config-api powershell)
    $g = Read-Json $globalPath
    Assert-True ($g['local-projects'].Count -eq 2 -and -not $g.Contains('selected-project')) 'API round trip failed.'
    # Official-created projects and their conversations must also travel back,
    # using the current list rather than the old two-project API snapshot.
    [void](Invoke-TestAction config-official powershell)
    $g = Read-Json $globalPath
    $g['local-projects']['local3'] = @{ id = 'local3'; name = '官方新增'; rootPaths = @('D:\官方新增') }
    $g['local-projects']['local2']['name'] = '已重命名项目'
    $g['project-order'] = @('local3', 'local2', 'local1')
    $g['thread-project-assignments']['officialNewThread'] = @{ projectKind = 'local'; projectId = 'local3' }
    $g['thread-project-membership-host-ids']['officialNewThread'] = $localHost
    $newSql = "INSERT INTO projects VALUES('backend3','official-new',2,3); INSERT INTO project_roots VALUES('backend3',0,'D:\官方新增'); INSERT INTO threads(id,cwd,source) VALUES('officialNewThread','D:\unrelated','vscode'); INSERT INTO threads(id,cwd,source) VALUES('stayRecent','D:\官方新增','cli');"
    $newSql | & $sqlite -batch -bail $databaseArgument
    Assert-True ($LASTEXITCODE -eq 0) 'Unable to create official-new project fixture.'
    Write-Json $globalPath $g
    [void](Invoke-TestAction config-api powershell)
    $g = Read-Json $globalPath
    Assert-True ($g['local-projects'].Count -eq 3 -and $g['local-projects']['local3']['rootPaths'][0] -ceq 'D:\官方新增') 'Official-new project was replaced with stale API state.'
    Assert-True ($g['local-projects']['local2']['name'] -ceq '已重命名项目' -and $g['project-order'][0] -ceq 'local3') 'Current project rename/order was lost.'
    Assert-True ($g['thread-project-assignments']['officialNewThread']['projectId'] -ceq 'local3') 'Official-new sidebar membership was lost.'
    $project = @(& $sqlite -readonly -noheader $databaseArgument "SELECT project_id FROM threads WHERE id='officialNewThread';")
    Assert-True ($project.Count -eq 1 -and $project[0] -ceq 'backend3') 'Official-new database membership was lost.'
    $recent = @(& $sqlite -readonly -noheader $databaseArgument "SELECT count(*) FROM threads WHERE id='stayRecent' AND project_id IS NULL;")
    Assert-True ($recent.Count -eq 1 -and $recent[0] -ceq '1') 'A projectless conversation was grouped merely by its working directory.'
    [void](Invoke-TestAction config-official)
    $g = Read-Json $globalPath
    Assert-True ($g['local-projects'].Count -eq 3 -and $g['thread-project-assignments']['apiNewThread']['projectId'] -ceq 'local2' -and $g['thread-project-assignments']['officialNewThread']['projectId'] -ceq 'local3') 'New projects/memberships were lost on the return switch.'
    [void](Invoke-TestAction config-api)
    [void](Invoke-TestAction desktop-repair)
    $stable = Get-Hash $globalPath
    [void](Invoke-TestAction desktop-repair)
    Assert-True ((Get-Hash $globalPath) -ceq $stable) 'Repeated repair is not idempotent.'

    # Fail after auth/config have been replaced. All managed files must roll back.
    $hashes = @{}
    foreach ($path in @($config, $authPath, $globalPath, ($globalPath + '.bak'), $archivePath)) { $hashes[$path] = Get-Hash $path }
    # Capture-CurrentCredentials performs the first login-status call. Fail only
    # the target official call, so the tested failure is inside the transaction.
    [IO.File]::WriteAllText($fakeCodex, @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
$auth = Get-Content -LiteralPath (Join-Path $env:CODEX_HOME 'auth.json') -Raw | ConvertFrom-Json
if ($null -ne $auth.PSObject.Properties['tokens']) { exit 2 }
Write-Output 'Logged in using an API key'
exit 0
'@, $utf8)
    [void](Invoke-TestAction config-official -Fail)
    foreach ($path in $hashes.Keys) { Assert-True ((Get-Hash $path) -ceq $hashes[$path]) ('Rollback changed ' + [IO.Path]::GetFileName($path)) }
    Assert-True (-not [IO.File]::Exists((Join-Path $store 'transaction.dpapi'))) 'Rolled-back journal was not removed.'

    # Force a failure after the main global JSON has already been written.
    [IO.File]::WriteAllText($fakeCodex, $normalFakeCodex, $utf8)
    $lockedBackup = [IO.File]::Open(($globalPath + '.bak'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { [void](Invoke-TestAction config-official -Fail) }
    finally { $lockedBackup.Dispose() }
    foreach ($path in $hashes.Keys) { Assert-True ((Get-Hash $path) -ceq $hashes[$path]) ('Partial-write rollback changed ' + [IO.Path]::GetFileName($path)) }
    Assert-True (-not [IO.File]::Exists((Join-Path $store 'transaction.dpapi'))) 'Partial-write rollback left a journal.'

    # No completed onboarding evidence: preserve the pending first-run flow.
    [IO.File]::Delete($archivePath)
    $fresh = @{ 'electron-persisted-atom-state' = @{ 'electron:onboarding-welcome-pending' = $true }; 'local-projects' = @{} }
    Write-Json $globalPath $fresh
    [void](Invoke-TestAction desktop-repair)
    $g = Read-Json $globalPath
    Assert-True (-not $g['electron-persisted-atom-state'].Contains('electron:onboarding-welcome-v2-role-state')) 'Repair fabricated onboarding consent.'
    Assert-True ($g['local-projects'].Count -eq 0) 'Explicitly deleted project list was resurrected.'
    # Native state already configured outside the switcher must survive the
    # switch. The switcher must not create or enforce a personal role policy.
    $neutral = @{ completedConversationalOnboarding = $true; conversationalOnboardingSkipped = $true; roles = @(); workMode = $null; personalizedSuggestionsEnabled = $false }
    $g['electron-persisted-atom-state']['electron:onboarding-welcome-v2-role-state'] = $neutral
    $g['electron-persisted-atom-state']['electron:onboarding-welcome-pending'] = $false
    Write-Json $globalPath $g
    $g = Read-Json $globalPath
    $welcome = $g['electron-persisted-atom-state']['electron:onboarding-welcome-v2-role-state']
    Assert-True ($welcome['roles'].Count -eq 0 -and $null -eq $welcome['workMode']) 'Fixture lost its native neutral preference.'
    [void](Invoke-TestAction config-official)
    $g = Read-Json $globalPath
    $welcome = $g['electron-persisted-atom-state']['electron:onboarding-welcome-v2-role-state']
    Assert-True ($welcome['roles'].Count -eq 0 -and $null -eq $welcome['workMode']) 'Official mode changed the existing neutral preference.'
    Assert-True ($welcome['personalizedSuggestionsEnabled'] -eq $false) 'Official mode changed the suggestion preference.'
    $welcome['roles'] = @('product')
    $welcome['workMode'] = 'non_coding'
    $welcome['personalizedSuggestionsEnabled'] = $true
    Write-Json $globalPath $g
    [void](Invoke-TestAction config-api powershell)
    $g = Read-Json $globalPath
    $welcome = $g['electron-persisted-atom-state']['electron:onboarding-welcome-v2-role-state']
    Assert-True ($welcome['roles'].Count -eq 1 -and $welcome['roles'][0] -ceq 'product') 'Switch overwrote a later personal role choice.'
    Assert-True ($welcome['workMode'] -ceq 'non_coding' -and $welcome['personalizedSuggestionsEnabled'] -eq $true) 'Switch enforced a stale one-time personal setting.'
    [void](Invoke-TestAction config-official)
    # Desktop may create a fresh official renderer without this completed atom.
    # The other mode's saved completion must keep it from reopening the wizard.
    $g = Read-Json $globalPath
    [void]$g['electron-persisted-atom-state'].Remove('electron:onboarding-welcome-v2-role-state')
    $g['electron-persisted-atom-state']['electron:onboarding-welcome-pending'] = $true
    Write-Json $globalPath $g
    [void](Invoke-TestAction desktop-repair)
    $g = Read-Json $globalPath
    $welcome = $g['electron-persisted-atom-state']['electron:onboarding-welcome-v2-role-state']
    Assert-True ($welcome['completedConversationalOnboarding'] -eq $true -and $welcome['roles'][0] -ceq 'product' -and $g['electron-persisted-atom-state']['electron:onboarding-welcome-pending'] -eq $false) 'A fresh official renderer lost saved completion from the API snapshot.'
    # This exact on-disk corruption escaped the older in-memory tests.
    $goodGlobal = [IO.File]::ReadAllBytes($globalPath)
    $g['active-workspace-roots'] = @(@{ Length = 9 })
    Write-Json $globalPath $g
    $guardHashes = @{}
    foreach ($path in @($config, $authPath, $globalPath, ($globalPath + '.bak'), $archivePath)) { $guardHashes[$path] = Get-Hash $path }
    [void](Invoke-TestAction desktop-repair powershell -Fail)
    foreach ($path in $guardHashes.Keys) { Assert-True ((Get-Hash $path) -ceq $guardHashes[$path]) ('Corrupt-root refusal changed ' + [IO.Path]::GetFileName($path)) }
    [IO.File]::WriteAllBytes($globalPath, $goodGlobal)
    $archiveBytes = [IO.File]::ReadAllBytes($archivePath)
    $archivePlain = [Security.Cryptography.ProtectedData]::Unprotect($archiveBytes, $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $badArchive = $utf8.GetString($archivePlain) | ConvertFrom-Json -AsHashtable
    [Array]::Clear($archivePlain, 0, $archivePlain.Length)
    $badArchive['api']['globals']['active-workspace-roots'] = @(@{ Length = 9 })
    $badPlain = $utf8.GetBytes((ConvertTo-Json -InputObject $badArchive -Depth 100 -Compress))
    [IO.File]::WriteAllBytes($archivePath, [Security.Cryptography.ProtectedData]::Protect($badPlain, $entropy, [Security.Cryptography.DataProtectionScope]::CurrentUser))
    [Array]::Clear($badPlain, 0, $badPlain.Length)
    foreach ($path in @($config, $authPath, $globalPath, ($globalPath + '.bak'), $archivePath)) { $guardHashes[$path] = Get-Hash $path }
    [void](Invoke-TestAction desktop-repair -Fail)
    foreach ($path in $guardHashes.Keys) { Assert-True ((Get-Hash $path) -ceq $guardHashes[$path]) ('Corrupt-archive refusal changed ' + [IO.Path]::GetFileName($path)) }
    Write-Host 'Desktop state tests passed: account reset, projects, personal settings preserved without enforcement, account isolation, PS 5.1/7, round trips, idempotence, partial-write rollback.'
}
finally {
    if ([IO.Directory]::Exists($testRoot)) {
        $resolved = [IO.Path]::GetFullPath($testRoot)
        $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not $resolved.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'codex-desktop-state-test-*') { throw 'Unsafe test cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
