#requires -Version 7.0
[CmdletBinding()]
param([ValidateSet('pwsh','powershell')][string]$Engine = 'pwsh')
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot


Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$testSource = $script:ProjectRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-history-entry-test-' + [Guid]::NewGuid().ToString('N'))
$utf8 = [Text.UTF8Encoding]::new($false)
$sqlite = Join-Path $testSource 'tools/sqlite3.ps1'

function Assert-Entry([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Write-Fixture([string]$Path, [string]$Text) {
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $Path))
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}
function Write-Json([string]$Path, $Value) { Write-Fixture $Path (ConvertTo-Json -InputObject $Value -Depth 20 -Compress) }
function Invoke-Sql([string]$HomePath, [string]$Sql) {
    $output = @(& $sqlite (Join-Path $HomePath 'provider-state.sqlite') $Sql 2>&1)
    Assert-Entry ($LASTEXITCODE -eq 0) ('Fixture SQL failed: ' + ($output -join ' | '))
    return $output
}
function New-OfficialAuth([string]$Account = 'preview-account') {
    $claims = @{'https://api.openai.com/auth'=@{chatgpt_user_id='preview-user';chatgpt_account_id=$Account}}
    $payload = [Convert]::ToBase64String($utf8.GetBytes((ConvertTo-Json -InputObject $claims -Compress))).TrimEnd('=').Replace('+','-').Replace('/','_')
    return ConvertTo-Json -InputObject @{auth_mode='chatgpt';tokens=@{id_token="test.$payload.signature";access_token='fixture-access';refresh_token='fixture-refresh';account_id=$Account}} -Depth 10
}
function Set-LiveKind($Fixture, [string]$Kind) {
    $config = "model_provider = `"openai`"`ncli_auth_credentials_store = `"file`"`nmodel = `"my-model`"`n"
    if ($Kind -eq 'api') { $config += "openai_base_url = `"https://api.example.com/v1`"`n" }
    Write-Fixture (Join-Path $Fixture.CodexHome 'config.toml') $config
    Write-Fixture (Join-Path $Fixture.CodexHome 'auth.json') $(if ($Kind -eq 'api') { '{"OPENAI_API_KEY":"preview-only-not-a-real-key"}' } else { New-OfficialAuth })
}
function New-EntryFixture([string]$Name, [string]$Kind = 'api', [switch]$Unregistered, [switch]$NoAuth) {
    $fixture = & (Join-Path $PSScriptRoot 'test-gui-fixture.ps1') -Root (Join-Path $testRoot $Name)
    Set-LiveKind $fixture $Kind
    # Every child uses the same fake CLI, including the initial OAuth path.
    $fixture.FakeCodex = $script:FakeCli
    if ($Unregistered -or $NoAuth) { $fixture.DataDir = Join-Path $testRoot ($Name + '-new-store') }
    if ($NoAuth) { [IO.File]::Delete((Join-Path $fixture.CodexHome 'auth.json')) }
    return $fixture
}
function Add-History($Fixture, [string]$Name, [switch]$Archived) {
    $folder = if ($Archived) { 'archived_sessions' } else { 'sessions' }
    $path = Join-Path $Fixture.CodexHome ($folder + '/' + $Name + '.jsonl')
    $lines = @(
        @{type='session_meta';payload=@{id=$Name;cwd='D:\Example';model_provider='legacy-relay'}}
        @{type='event_msg';payload=@{type='thread_settings_applied';thread_settings=@{model_provider_id='legacy-relay'}}}
        @{type='event_msg';payload=@{type='user_message';message='保留原始聊天内容'}}
        @{type='response_item';payload=@{type='message';id=('msg_' + $Name);role='assistant';content=@(@{type='output_text';text='保留原始回答'})}}
    ) | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 12 -Compress }
    Write-Fixture $path (($lines -join "`n") + "`n")
    [void](Invoke-Sql $Fixture.CodexHome ("CREATE TABLE IF NOT EXISTS threads(id TEXT PRIMARY KEY,model_provider TEXT,project_id TEXT);" +
        "INSERT OR IGNORE INTO threads VALUES('cloud-only','cloud-provider','remote-project');" +
        "INSERT INTO threads VALUES('$Name','legacy-relay','keep-project');"))
    return $path
}
function Assert-Normalized($Fixture, [string[]]$Files) {
    foreach ($path in $Files) {
        $records = @([IO.File]::ReadAllLines($path) | ForEach-Object { ConvertFrom-Json $_ })
        Assert-Entry ($records[0].payload.model_provider -ceq 'openai' -and $records[1].payload.thread_settings.model_provider_id -ceq 'openai') "Provider fields were not normalized: $path"
        Assert-Entry ($records[2].payload.message -ceq '保留原始聊天内容' -and $records[3].payload.content[0].text -ceq '保留原始回答') 'Chat content was changed.'
        $id = $records[0].payload.id
        $row = @(Invoke-Sql $Fixture.CodexHome "SELECT model_provider||'|'||project_id FROM threads WHERE id='$id';")
        Assert-Entry ($row.Count -eq 1 -and $row[0] -ceq 'openai|keep-project') 'Local SQLite provider or project assignment is incorrect.'
    }
    Assert-Entry (@(Invoke-Sql $Fixture.CodexHome "SELECT model_provider FROM threads WHERE id='cloud-only';")[0] -ceq 'cloud-provider') 'A cloud-only row was rewritten.'
    Assert-Entry ([IO.File]::Exists((Join-Path $Fixture.DataDir 'history-compat-ready.json'))) 'No history readiness record was created.'
    $backups = @(Get-ChildItem -LiteralPath (Join-Path $Fixture.DataDir 'history-repair-backups') -Filter manifest.json -Recurse)
    Assert-Entry ($backups.Count -gt 0) 'A migration did not create a repair manifest.'
    $manifest = Get-Content -LiteralPath $backups[-1].FullName -Raw | ConvertFrom-Json
    Assert-Entry ($manifest.status -ceq 'complete') 'History migration did not complete its transaction.'
}
function Invoke-Entry {
    param($Fixture, [string]$Action, [hashtable]$Request, [string[]]$Answers = @(), [string]$Selector, [bool]$ExpectSuccess = $true, [switch]$FullScan)
    $answersPath = Join-Path $testRoot 'answers.json'
    Write-Json $answersPath @($Answers)
    $arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$script:Harness,
        '-Switcher',(Join-Path $testSource 'codex-profile-switcher.ps1'),'-Action',$Action,
        '-CodexHome',$Fixture.CodexHome,'-DataDir',$Fixture.DataDir,'-CodexExecutable',$Fixture.FakeCodex,'-InputPath',$answersPath)
    if ($Request) {
        $requestPath = Join-Path $testRoot 'request.json'
        Write-Json $requestPath $Request
        $arguments += @('-RequestPayload',$requestPath)
    }
    if ($Selector) { $arguments += @('-Selector',$Selector) }
    if ($FullScan) { $arguments += '-FullScan' }
    $output = @(& $Engine @arguments 2>&1)
    $code = $LASTEXITCODE
    Assert-Entry (($code -eq 0) -eq $ExpectSuccess) ("$Action returned $code : " + ($output -join ' | '))
    return $output -join "`n"
}

try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    $script:FakeCli = Join-Path $testRoot 'fake-cli.ps1'
    Write-Fixture $script:FakeCli @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
$auth = Join-Path $env:CODEX_HOME 'auth.json'
if ($Arguments.Count -ge 2 -and $Arguments[1] -eq 'status') {
    $a = Get-Content -Raw -LiteralPath $auth | ConvertFrom-Json
    if ($a.PSObject.Properties['tokens']) { 'Logged in using ChatGPT' } else { 'Logged in using an API key' }
    exit 0
}
if ($Arguments.Count -eq 1 -and $Arguments[0] -eq 'login') {
    [IO.File]::WriteAllText($auth,'{"auth_mode":"chatgpt","tokens":{"id_token":"fixture-id","access_token":"fixture-access","refresh_token":"fixture-refresh","account_id":"second-account"}}',(New-Object Text.UTF8Encoding($false)))
    exit 0
}
exit 3
'@
    $script:Harness = Join-Path $testRoot 'entry-harness.ps1'
    Write-Fixture $script:Harness @'
param($Switcher,$Action,$CodexHome,$DataDir,$CodexExecutable,$InputPath,$RequestPayload,$Selector,[switch]$FullScan)
$ErrorActionPreference = 'Stop'
[object[]]$global:EntryAnswers = @()
$parsedAnswers = Get-Content -Encoding UTF8 -Raw -LiteralPath $InputPath | ConvertFrom-Json
if ($null -ne $parsedAnswers) { $global:EntryAnswers = $parsedAnswers }
$global:EntryAnswerIndex = 0
function global:Read-Host {
    param($Prompt,[switch]$AsSecureString)
    if ($global:EntryAnswerIndex -ge $global:EntryAnswers.Count) { throw "Unexpected prompt: $Prompt" }
    $answer = [string]$global:EntryAnswers[$global:EntryAnswerIndex++]
    if ($AsSecureString) { return ConvertTo-SecureString $answer -AsPlainText -Force }
    return $answer
}
$parameters = @{CodexHome=$CodexHome;DataDir=$DataDir;CodexExecutable=$CodexExecutable;MonitorDataDir=(Join-Path $DataDir 'monitor');UnsafeAllowRunningCodex=$true;FullHistoryScan=$FullScan}
if ($RequestPayload) {
    . $Switcher @parameters -LibraryOnly
    $requestPath = Join-Path $DataDir ('requests\' + [Guid]::NewGuid().ToString('N') + '.dpapi')
    Write-AtomicBytes $requestPath (Protect-BytesForCurrentUser ([IO.File]::ReadAllBytes($RequestPayload)))
    & $Switcher @parameters -Command request -RequestPath $requestPath
} else {
    if ($Selector) { $parameters.Profile = $Selector }
    & $Switcher @parameters -Command $Action
}
exit $LASTEXITCODE
'@

    # First import, via both the public CLI and the GUI's encrypted request.
    foreach ($kind in @('api','official')) {
        $fixture = New-EntryFixture ('import-' + $kind) $kind -Unregistered
        $local = Add-History $fixture ('import-' + $kind)
        $archived = Add-History $fixture ('archive-' + $kind) -Archived
        $configHash = (Get-FileHash -LiteralPath (Join-Path $fixture.CodexHome 'config.toml')).Hash
        $authHash = (Get-FileHash -LiteralPath (Join-Path $fixture.CodexHome 'auth.json')).Hash
        if ($kind -eq 'api') { [void](Invoke-Entry $fixture init) }
        else { [void](Invoke-Entry $fixture request @{action='initialize'}) }
        Assert-Normalized $fixture @($local,$archived)
        Assert-Entry ((Get-FileHash -LiteralPath (Join-Path $fixture.CodexHome 'config.toml')).Hash -ceq $configHash -and
            (Get-FileHash -LiteralPath (Join-Path $fixture.CodexHome 'auth.json')).Hash -ceq $authHash) 'Import changed live credentials or config.'
    }

    # A missing auth file must not bypass migration of existing local history.
    foreach ($kind in @('api','official')) {
        $fixture = New-EntryFixture ('setup-' + $kind) $kind -NoAuth
        $history = Add-History $fixture ('setup-' + $kind)
        if ($kind -eq 'api') { [void](Invoke-Entry $fixture setup -Answers @('api','https://first.example/v1','fixture-api','First API')) }
        else { [void](Invoke-Entry $fixture request @{action='add-official';kind='official';name='First official'}) }
        Assert-Normalized $fixture @($history)
    }

    $fixture = New-EntryFixture 'first-toggle' api -Unregistered
    $history = Add-History $fixture 'first-toggle'
    $firstToggle = Invoke-Entry $fixture toggle -FullScan
    Assert-Normalized $fixture @($history)
    Assert-Entry (([regex]::Matches($firstToggle,'正在扫描 Codex 对话历史')).Count -eq 1 -and
        $firstToggle -match '已指定全量检查') 'A first toggle duplicated or skipped its forced full inspection.'

    # Already-registered first-time users may start in either mode, or switch
    # directly within the same kind. Exercise every public normal switch path.
    $cases = @(
        @{Name='api-to-api-gui';Source='api';Action='request';Request=@{action='use';kind='api';selector='备用接口'}}
        @{Name='api-to-official';Source='api';Action='profile-use-official';Selector='个人 ChatGPT'}
        @{Name='official-to-api-toggle';Source='official';Action='toggle'}
        @{Name='official-to-official';Source='official';Action='official';Selector='Second official'}
        @{Name='api-direct';Source='official';Action='api'}
        @{Name='api-profile';Source='official';Action='profile-use-api';Selector='备用接口'}
    )
    foreach ($case in $cases) {
        $fixture = New-EntryFixture $case.Name $case.Source
        if ($case.Name -eq 'official-to-official') { [void](Invoke-Entry $fixture request @{action='add-official';kind='official';name='Second official'}) }
        $history = Add-History $fixture $case.Name
        $argsForEntry = @{Fixture=$fixture;Action=$case.Action}
        if ($case.ContainsKey('Request')) { $argsForEntry.Request=$case.Request }
        if ($case.ContainsKey('Selector')) { $argsForEntry.Selector=$case.Selector }
        [void](Invoke-Entry @argsForEntry)
        Assert-Normalized $fixture @($history)
    }

    # The last fixture is in API mode. New archived history must be picked up
    # without rewriting prepared files, followed by a true no-change fast path.
    $oldHash = (Get-FileHash -LiteralPath $history).Hash
    $oldWrite = [IO.File]::GetLastWriteTimeUtc($history)
    $newHistory = Add-History $fixture 'added-later' -Archived
    $incremental = Invoke-Entry $fixture request @{action='use';kind='api';selector='工作 API'}
    Assert-Normalized $fixture @($history,$newHistory)
    Assert-Entry ($incremental -match '跳过 1 个旧文件' -and (Get-FileHash -LiteralPath $history).Hash -ceq $oldHash -and [IO.File]::GetLastWriteTimeUtc($history) -eq $oldWrite) 'Prepared history was reread or rewritten on incremental migration.'
    $stamp = Join-Path $fixture.DataDir 'history-compat-ready.json'
    $stampHash = (Get-FileHash -LiteralPath $stamp).Hash
    $backupCount = @(Get-ChildItem -LiteralPath (Join-Path $fixture.DataDir 'history-repair-backups') -Filter manifest.json -Recurse).Count
    $quick = Invoke-Entry $fixture request @{action='use';kind='official';selector='个人 ChatGPT'}
    Assert-Entry ($quick -match '跳过完整扫描' -and $quick -notmatch '正在扫描 Codex 对话历史' -and
        (Get-FileHash -LiteralPath $stamp).Hash -ceq $stampHash -and
        @(Get-ChildItem -LiteralPath (Join-Path $fixture.DataDir 'history-repair-backups') -Filter manifest.json -Recurse).Count -eq $backupCount) 'Unchanged switching performed another repair.'
    [void](Invoke-Sql $fixture.CodexHome "UPDATE threads SET model_provider='database-only-change' WHERE id='added-later';")
    [void](Invoke-Entry $fixture api)
    Assert-Normalized $fixture @($history,$newHistory)
    Assert-Entry ((Get-FileHash -LiteralPath $history).Hash -ceq $oldHash) 'Database-only provider repair rewrote old JSONL.'
    $forced = Invoke-Entry $fixture api -FullScan
    Assert-Entry ($forced -match '已指定全量检查') 'Explicit full inspection was ignored on an API switch.'

    # Unsafe histories stop normal switches before config/auth change. Initial
    # setup also restores the original absence of auth and profile state.
    foreach ($fresh in @($false,$true)) {
        $fixture = New-EntryFixture ('invalid-' + $fresh) api -NoAuth:$fresh
        $history = Add-History $fixture ('invalid-' + $fresh)
        Write-Fixture (Join-Path $fixture.CodexHome 'sessions/broken.jsonl') '{"type":"session_meta","payload":{"id":"broken","model_provider":""}}'
        $historyHash = (Get-FileHash -LiteralPath $history).Hash
        $configHash = (Get-FileHash -LiteralPath (Join-Path $fixture.CodexHome 'config.toml')).Hash
        if ($fresh) { [void](Invoke-Entry $fixture request @{action='add-api';kind='api';name='New API';base_url='https://new.example/v1';api_key='fixture-new'} -ExpectSuccess $false) }
        else {
            $authHash = (Get-FileHash -LiteralPath (Join-Path $fixture.CodexHome 'auth.json')).Hash
            [void](Invoke-Entry $fixture request @{action='use';kind='api';selector='备用接口'} -ExpectSuccess $false)
            Assert-Entry ((Get-FileHash -LiteralPath (Join-Path $fixture.CodexHome 'auth.json')).Hash -ceq $authHash) 'A failed history check changed credentials.'
        }
        Assert-Entry ((Get-FileHash -LiteralPath $history).Hash -ceq $historyHash -and
            (Get-FileHash -LiteralPath (Join-Path $fixture.CodexHome 'config.toml')).Hash -ceq $configHash) 'A failed history check left partial changes.'
        Assert-Entry (-not [IO.File]::Exists((Join-Path $fixture.DataDir 'history-compat-ready.json'))) 'Invalid history was certified ready.'
        if ($fresh) { Assert-Entry (-not [IO.File]::Exists((Join-Path $fixture.CodexHome 'auth.json')) -and -not [IO.File]::Exists((Join-Path $fixture.DataDir 'state.dpapi'))) 'Failed first setup left live authentication or initialized state.' }
    }

    $fixture = New-EntryFixture 'advanced'
    $history = Add-History $fixture 'advanced'
    $original = (Get-FileHash -LiteralPath $history).Hash
    [void](Invoke-Entry $fixture config-official)
    [void](Invoke-Entry $fixture config-api)
    Assert-Entry ((Get-FileHash -LiteralPath $history).Hash -ceq $original -and
        -not [IO.File]::Exists((Join-Path $fixture.DataDir 'history-compat-ready.json'))) 'Explicit advanced bypass processed history.'

    Write-Output "Shared history entry tests passed ($Engine): first API/OAuth import/setup, both directions and same-kind accounts, CLI/GUI requests, archived/event/SQLite providers, incremental/no-change paths, database-only changes, full inspection, failure rollback, advanced bypass."
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temporaryParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($temporaryParent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'codex-history-entry-test-*') { throw 'Unsafe test cleanup path.' }
    if ([IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
