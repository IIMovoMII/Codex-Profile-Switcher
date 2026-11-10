#requires -Version 7.0

[CmdletBinding()]
param()
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot


Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$switcher = Join-Path $script:ProjectRoot "codex-profile-switcher.ps1"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-profile-switcher-test-" + [Guid]::NewGuid().ToString("N"))
$utf8 = New-Object System.Text.UTF8Encoding($false)
$sqliteCommand = Get-Command sqlite3.exe -ErrorAction SilentlyContinue
if ($null -eq $sqliteCommand) {
    $sqliteCommand = Get-Command sqlite3 -ErrorAction SilentlyContinue
}
if ($null -eq $sqliteCommand) {
    throw "Profile switcher tests require sqlite3.exe."
}
$sqliteExecutable = [string]$sqliteCommand.Source

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
}

function Write-TestFile {
    param([string]$Path, [string]$Text)
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}

function New-TestHome {
    param([string]$Name)

    $testCodexHome = Join-Path $tempRoot $Name
    [IO.Directory]::CreateDirectory($testCodexHome) | Out-Null
    $configPath = Join-Path $testCodexHome "config.toml"
    $catalogPath = Join-Path $testCodexHome "models.json"
    $configText = @'
# test configuration
model_provider = "openai"
openai_base_url = "https://relay.example/v1"
model = "test-model"

[features]
js_repl = false
respect_system_proxy = false
'@
    Write-TestFile $configPath $configText
    Write-TestFile $catalogPath '{"models":[{"slug":"test-model","context_window":500000},{"slug":"second-model","context_window":353400}]}'
    Write-TestFile (Join-Path $testCodexHome "models_cache.json") '{"models":[{"slug":"test-model","context_window":475000},{"slug":"gpt-6.1-sol","visibility":"list","supported_in_api":true,"context_window":500000},{"slug":"second-model","context_window":353400}]}'
    Write-TestFile (Join-Path $testCodexHome "auth.json") '{"OPENAI_API_KEY":"relay-secret-value"}'
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
    $output = $Sql | & $sqliteExecutable @arguments $Path 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Test SQLite command failed: $($output -join '; ')"
    }
    return @($output | ForEach-Object { [string]$_ })
}

function Invoke-SwitcherProcess {
    param(
        [string]$Action,
        [string]$TestCodexHome,
        [string]$Store,
        [string]$FakeCodex,
        [bool]$ExpectSuccess = $true,
        [switch]$FullHistoryScan
    )

    # This suite deliberately exercises explicit overrides. Default-preserve
    # behavior is tested separately by the graphical/service suite.
    $settingsPath=Join-Path $Store 'settings.json'
    if(-not [IO.File]::Exists($settingsPath)){Write-TestFile $settingsPath '{"version":1,"official_proxy":"system","api_proxy":"direct","context_window":"272000"}'}
    $arguments = @(
        "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $switcher,
        "-Command", $Action,
        "-CodexHome", $TestCodexHome,
        "-DataDir", $Store,
        "-MonitorDataDir", (Join-Path $Store "monitor"),
        "-CodexExecutable", $FakeCodex,
        "-UnsafeAllowRunningCodex"
    )
    if ($FullHistoryScan) { $arguments += '-FullHistoryScan' }
    $output = @(& pwsh @arguments 2>&1)
    $exitCode = $LASTEXITCODE
    if ($ExpectSuccess -and $exitCode -ne 0) {
        throw "Switcher action '$Action' failed with exit code $exitCode. Output: $($output -join ' | ')"
    }
    if (-not $ExpectSuccess -and $exitCode -eq 0) {
        throw "Switcher action '$Action' unexpectedly succeeded."
    }
    return $output
}

try {
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $fakeCodex = Join-Path $tempRoot "fake-codex.ps1"
    Write-TestFile $fakeCodex @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
$ErrorActionPreference = "Stop"
if (-not [string]::IsNullOrWhiteSpace($env:FAKE_CODEX_LOG)) {
    Add-Content -LiteralPath $env:FAKE_CODEX_LOG -Value ($Arguments -join " ")
}
$authPath = Join-Path $env:CODEX_HOME "auth.json"
if ($Arguments.Count -ge 2 -and $Arguments[0] -eq "debug" -and $Arguments[1] -eq "models") {
    throw "The switcher must not query CLI model catalogs."
}
if ($Arguments.Count -ge 1 -and $Arguments[0] -eq "login") {
    if ($Arguments.Count -ge 2 -and $Arguments[1] -eq "status") {
        $auth = Get-Content -Raw -LiteralPath $authPath | ConvertFrom-Json
        $tokensProperty = $auth.PSObject.Properties["tokens"]
        $apiKeyProperty = $auth.PSObject.Properties["OPENAI_API_KEY"]
        if ($null -ne $tokensProperty -and $null -ne $tokensProperty.Value) { Write-Output "Logged in using ChatGPT" }
        elseif ($null -ne $apiKeyProperty -and $apiKeyProperty.Value) { Write-Output "Logged in using an API key: relay-secret-value" }
        else { exit 2 }
        exit 0
    }
    if ($env:FAKE_CODEX_LOGIN_FAIL -eq "1") { exit 9 }
    if ($env:FAKE_CODEX_LOGIN_HANG -eq "1") { Start-Sleep -Seconds 30 }
    $official = [ordered]@{
        auth_mode = "chatgpt"
        tokens = [ordered]@{
            id_token = "id-token"
            access_token = "access-token"
            refresh_token = "refresh-token"
            account_id = "account-id"
        }
    } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($authPath, $official, (New-Object System.Text.UTF8Encoding($false)))
    exit 0
}
exit 3
'@

    $testCodexHome = New-TestHome "success-home"
    $store = Join-Path $tempRoot "success-store"
    [void](Invoke-SwitcherProcess "init" $testCodexHome $store $fakeCodex)

    Assert-True (Test-Path (Join-Path $store "relay.auth.dpapi")) "Relay snapshot was not created."
    $maintenancePath = Join-Path $store "monitor\maintenance.json"
    Assert-True (Test-Path $maintenancePath) "Profile switch did not publish the monitor maintenance marker."
    $maintenance = Get-Content -Raw -LiteralPath $maintenancePath | ConvertFrom-Json
    Assert-True ($maintenance.reason -eq "codex_profile_switch") "Maintenance marker reason is wrong."
    $encryptedText = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes((Join-Path $store "relay.auth.dpapi")))
    Assert-True (-not $encryptedText.Contains("relay-secret-value")) "Relay secret appears in the encrypted snapshot."

    $compatibilityRollout = Join-Path $testCodexHome "sessions\2026\07\30\rollout-compatibility-test.jsonl"
    Write-TestFile $compatibilityRollout @'
{"timestamp":"2026-07-30T00:00:00Z","type":"response_item","payload":{"type":"reasoning","id":"item_relay_reasoning","summary":[{"type":"summary_text","text":"relay"}],"content":null,"encrypted_content":null}}
{"timestamp":"2026-07-30T00:00:01Z","type":"response_item","payload":{"type":"message","id":"item_relay_message","role":"assistant","content":[{"type":"output_text","text":"kept"}]}}
'@

    $automaticPreparation = @(Invoke-SwitcherProcess "official" $testCodexHome $store $fakeCodex)
    Assert-True (($automaticPreparation -join "`n") -match '正在自动执行停机准备') "Direct official switch did not prepare history automatically."
    Assert-True (-not [IO.File]::ReadAllText($compatibilityRollout).Contains("item_relay_reasoning")) "Direct official switch retained incompatible history."

    [void](Invoke-SwitcherProcess "history-prepare" $testCodexHome $store $fakeCodex)
    $historyReadyPath = Join-Path $store "history-compat-ready.json"
    Assert-True (Test-Path $historyReadyPath) "History preparation stamp was not created."
    $historyReady = [IO.File]::ReadAllText($historyReadyPath) | ConvertFrom-Json
    Assert-True ([int]$historyReady.version -eq 3) "History preparation stamp did not invalidate the format without ID-length validation."
    Assert-True ([string]$historyReady.provider_target -ceq "openai") "History preparation stamp did not record the provider target."
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$historyReady.database_fingerprint)) "History preparation stamp did not record the database fingerprint."
    $preparedStampText = [IO.File]::ReadAllText($historyReadyPath)
    $rulesText = [IO.File]::ReadAllText((Join-Path $script:ProjectRoot 'codex-history-compat.ps1')) + "`n" +
        [IO.File]::ReadAllText((Join-Path $script:ProjectRoot 'CodexPortableHistory.cs')) + "`n" +
        [IO.File]::ReadAllText((Join-Path $script:ProjectRoot 'codex-history-incremental.ps1'))
    $rulesHasher = [Security.Cryptography.SHA256]::Create()
    try { $expectedRulesHash = [BitConverter]::ToString($rulesHasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($rulesText))).Replace('-', '') }
    finally { $rulesHasher.Dispose() }
    Assert-True ([string]$historyReady.rules_fingerprint -ieq $expectedRulesHash) "Repair rules were not fingerprinted."
    $historyReady.rules_fingerprint = 'stale-rule-hash'
    Write-TestFile $historyReadyPath ($historyReady | ConvertTo-Json -Depth 4)
    $staleStatus = @(Invoke-SwitcherProcess "status" $testCodexHome $store $fakeCodex)
    Assert-True (($staleStatus -join "`n") -match '规则已更新') "Changed repair rules did not invalidate readiness."
    $historyReady = $preparedStampText | ConvertFrom-Json
    $historyReady.version = 2
    Write-TestFile $historyReadyPath ($historyReady | ConvertTo-Json -Depth 4)
    $oldStampOutput = @(Invoke-SwitcherProcess "official" $testCodexHome $store $fakeCodex)
    Assert-True (($oldStampOutput -join "`n") -match '准备记录版本不受支持') "A version-2 history stamp bypassed revalidation."
    Assert-True (([IO.File]::ReadAllText($historyReadyPath) | ConvertFrom-Json).version -eq 3) "An old stamp was not replaced after revalidation."
    [void](Invoke-SwitcherProcess "official" $testCodexHome $store $fakeCodex)
    $officialConfig = [IO.File]::ReadAllText((Join-Path $testCodexHome "config.toml"))
    $officialAuth = [IO.File]::ReadAllText((Join-Path $testCodexHome "auth.json")) | ConvertFrom-Json
    $compatibilityText = [IO.File]::ReadAllText($compatibilityRollout)
    Assert-True ($officialConfig -notmatch '(?m)^\s*openai_base_url\s*=') "Official config retained openai_base_url."
    Assert-True ($officialConfig -match '(?m)^model_provider = "openai"\r?$') "Official config changed model_provider."
    Assert-True ($officialConfig -match '(?m)^model_context_window = 272000\r?$') "Official config did not pin the context window."
    Assert-True ($officialConfig -match '(?m)^cli_auth_credentials_store = "file"\r?$') "Official config did not pin file auth storage."
    Assert-True ($officialConfig -match '(?m)^respect_system_proxy = true\r?$') "Official mode did not enable the Windows system proxy."
    Assert-True ($officialConfig -notmatch '(?m)^model_catalog_json\s*=') "Official mode retained the relay-only model catalog override."
    Assert-True ($null -ne $officialAuth.tokens) "Official auth was not installed."
    Assert-True (Test-Path (Join-Path $store "official.auth.dpapi")) "Official snapshot was not created."
    $officialCatalog = Get-Content -Raw -LiteralPath (Join-Path $testCodexHome "models.json") | ConvertFrom-Json
    $officialCache = Get-Content -Raw -LiteralPath (Join-Path $testCodexHome "models_cache.json") | ConvertFrom-Json
    Assert-True ($officialCatalog.models[0].context_window -eq 500000 -and $officialCatalog.models[1].context_window -eq 353400) "Official switch unexpectedly rewrote the configured model catalog."
    Assert-True (($officialCache.models | Where-Object { $_.slug -ceq "test-model" }).context_window -eq 475000 -and ($officialCache.models | Where-Object { $_.slug -ceq "second-model" }).context_window -eq 353400) "Official switch unexpectedly rewrote the model cache."
    Assert-True (-not $compatibilityText.Contains("item_relay_reasoning")) "Official switch retained unusable relay reasoning history."
    Assert-True ($compatibilityText.Contains('"id":"msg_relay_message"')) "Official switch did not normalize relay message history."
    Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $store "history-repair-backups") -Filter manifest.json -Recurse).Count -eq 1) "Official switch did not create a history repair manifest."

    $sharedCatalogPath = [IO.Path]::GetFullPath((Join-Path $store "relay-models.json"))
    $manualCatalogText = '{"models":[{"slug":"manually-maintained-relay-model","visibility":"list","supported_in_api":true}]}'
    Write-TestFile $sharedCatalogPath $manualCatalogText
    $apiSwitchOutput = @(Invoke-SwitcherProcess "api" $testCodexHome $store $fakeCodex)
    Assert-True (-not (($apiSwitchOutput -join "`n") -match 'relay-secret-value')) "Switcher exposed an API key fragment from login status."
    $apiConfig = [IO.File]::ReadAllText((Join-Path $testCodexHome "config.toml"))
    $apiAuth = [IO.File]::ReadAllText((Join-Path $testCodexHome "auth.json")) | ConvertFrom-Json
    Assert-True ($apiConfig -match '(?m)^openai_base_url = "https://relay\.example/v1"\r?$') "Relay URL was not restored."
    $expectedRelayCatalogLine = 'model_catalog_json = ' + (ConvertTo-Json -Compress $sharedCatalogPath)
    Assert-True (([regex]::Split($apiConfig, "\r?\n")) -contains $expectedRelayCatalogLine) "Relay mode did not apply the shared Codex model catalog."
    Assert-True ([IO.File]::ReadAllText($sharedCatalogPath) -ceq $manualCatalogText) "Relay switch modified the manually maintained model catalog."
    Assert-True ($apiConfig -match '(?m)^respect_system_proxy = false\r?$') "Relay mode did not disable the Windows system proxy."
    Assert-True ($apiAuth.OPENAI_API_KEY -eq "relay-secret-value") "Relay API auth was not restored."
    Assert-True ($apiConfig -match '(?m)^model_context_window = 272000\r?$') "API config did not preserve the context window override."
    $apiCatalog = Get-Content -Raw -LiteralPath (Join-Path $testCodexHome "models.json") | ConvertFrom-Json
    $apiCache = Get-Content -Raw -LiteralPath (Join-Path $testCodexHome "models_cache.json") | ConvertFrom-Json
    Assert-True (($apiCatalog.models | Where-Object { $_.slug -ceq "test-model" }).context_window -eq 500000 -and ($apiCatalog.models | Where-Object { $_.slug -ceq "second-model" }).context_window -eq 353400) "API switch unexpectedly rewrote the configured model catalog."
    Assert-True (($apiCache.models | Where-Object { $_.slug -ceq "test-model" }).context_window -eq 475000 -and ($apiCache.models | Where-Object { $_.slug -ceq "second-model" }).context_window -eq 353400) "API switch unexpectedly rewrote the model cache."

    # Official CLI and local cache catalogs are outside switcher control.
    # Even invalid cache JSON must not block an API switch or alter the manual relay file.
    $cacheFile = Join-Path $testCodexHome "models_cache.json"
    Write-TestFile $cacheFile '{not-json'
    [void](Invoke-SwitcherProcess "api" $testCodexHome $store $fakeCodex)
    Assert-True ([IO.File]::ReadAllText($cacheFile) -ceq '{not-json') "Relay switch read or rewrote models_cache.json."
    Assert-True ([IO.File]::ReadAllText($sharedCatalogPath) -ceq $manualCatalogText) "Relay switch modified the manually maintained model catalog."

    # With no manual relay catalog, switching still works without creating one
    # or installing a model_catalog_json override.
    $noCacheHome = New-TestHome "no-official-cache-home"
    $noCacheStore = Join-Path $tempRoot "no-official-cache-store"
    [void](Invoke-SwitcherProcess "init" $noCacheHome $noCacheStore $fakeCodex)
    [IO.File]::Delete((Join-Path $noCacheHome "models_cache.json"))
    [void](Invoke-SwitcherProcess "api" $noCacheHome $noCacheStore $fakeCodex)
    $noCacheConfig = [IO.File]::ReadAllText((Join-Path $noCacheHome "config.toml"))
    Assert-True (-not [IO.File]::Exists((Join-Path $noCacheStore "relay-models.json"))) "API switch created or downloaded a relay catalog."
    Assert-True ($noCacheConfig -notmatch '(?m)^\s*model_catalog_json\s*=') "API switch installed a catalog override when no manual cache exists."
    Assert-True ($noCacheConfig -match '(?m)^openai_base_url = "https://relay\.example/v1"\r?$') "API switch failed without a model catalog."

    # Integration check: the one-command toggle must initialize its snapshots,
    # prepare history only when needed, and work in both directions.
    $toggleHome = New-TestHome "toggle-home"
    $toggleStore = Join-Path $tempRoot "toggle-store"
    $toggleCatalogPath = Join-Path $toggleStore "relay-models.json"
    $toggleCatalogText = '{"models":[{"slug":"manually-maintained-toggle-model"}]}'
    Write-TestFile $toggleCatalogPath $toggleCatalogText
    $toggleRollout = Join-Path $toggleHome "sessions\2026\07\30\rollout-toggle.jsonl"
    Write-TestFile $toggleRollout @'
{"timestamp":"2026-07-30T00:00:00Z","type":"response_item","payload":{"type":"reasoning","id":"item_toggle_reasoning","summary":[{"type":"summary_text","text":"relay"}],"content":null,"encrypted_content":null}}
{"timestamp":"2026-07-30T00:00:01Z","type":"response_item","payload":{"type":"message","id":"item_toggle_message","role":"assistant","content":[{"type":"output_text","text":"kept"}]}}
'@

    $firstToggleOutput = @(Invoke-SwitcherProcess "toggle" $toggleHome $toggleStore $fakeCodex)
    $toggleConfig = [IO.File]::ReadAllText((Join-Path $toggleHome "config.toml"))
    $toggleAuth = [IO.File]::ReadAllText((Join-Path $toggleHome "auth.json")) | ConvertFrom-Json
    $toggleReady = [IO.File]::ReadAllText((Join-Path $toggleStore "history-compat-ready.json")) | ConvertFrom-Json
    $toggleHistory = [IO.File]::ReadAllText($toggleRollout)
    Assert-True (($firstToggleOutput -join "`n") -match "正在自动执行停机准备") "First toggle did not automatically prepare stale history."
    Assert-True ($toggleConfig -notmatch '(?m)^\s*openai_base_url\s*=') "First toggle did not switch to official mode."
    Assert-True ($toggleConfig -match '(?m)^respect_system_proxy = true\r?$') "First toggle did not enable the official proxy setting."
    Assert-True ($null -ne $toggleAuth.tokens) "First toggle did not create official authentication."
    Assert-True ([int]$toggleReady.version -eq 3) "First toggle did not create a version-3 history stamp."
    Assert-True (-not $toggleHistory.Contains('"id":"item_toggle_reasoning"')) "First toggle retained unusable reasoning history."
    Assert-True ($toggleHistory.Contains('"id":"msg_toggle_message"')) "First toggle did not normalize message history."

    $secondToggleOutput = @(Invoke-SwitcherProcess "toggle" $toggleHome $toggleStore $fakeCodex)
    $toggleConfig = [IO.File]::ReadAllText((Join-Path $toggleHome "config.toml"))
    $toggleAuth = [IO.File]::ReadAllText((Join-Path $toggleHome "auth.json")) | ConvertFrom-Json
    Assert-True (($secondToggleOutput -join "`n") -match "官方模式" -and ($secondToggleOutput -join "`n") -match "中转模式") "Second toggle did not detect official mode. Output: $($secondToggleOutput -join ' | ')"
    Assert-True ($toggleConfig -match '(?m)^openai_base_url = "https://relay\.example/v1"\r?$') "Second toggle did not restore the relay URL."
    Assert-True ($toggleConfig -match '(?m)^respect_system_proxy = false\r?$') "Second toggle did not disable the official proxy setting."
    $toggleCatalogPath = [IO.Path]::GetFullPath($toggleCatalogPath)
    $expectedToggleCatalogLine = 'model_catalog_json = ' + (ConvertTo-Json -Compress $toggleCatalogPath)
    Assert-True (([regex]::Split($toggleConfig, "\r?\n")) -contains $expectedToggleCatalogLine) "Second toggle did not restore the manually maintained relay model catalog."
    Assert-True ([IO.File]::ReadAllText($toggleCatalogPath) -ceq $toggleCatalogText) "Toggle modified the manually maintained relay model catalog."
    Assert-True ($toggleAuth.OPENAI_API_KEY -eq "relay-secret-value") "Second toggle did not restore relay authentication."

    [IO.File]::AppendAllText(
        $toggleRollout,
        "`n{`"timestamp`":`"2026-07-30T00:00:02Z`",`"type`":`"response_item`",`"payload`":{`"type`":`"message`",`"id`":`"item_toggle_late_message`",`"role`":`"assistant`",`"content`":[{`"type`":`"output_text`",`"text`":`"late`"}]}}",
        $utf8
    )
    $thirdToggleOutput = @(Invoke-SwitcherProcess "toggle" $toggleHome $toggleStore $fakeCodex)
    $toggleConfig = [IO.File]::ReadAllText((Join-Path $toggleHome "config.toml"))
    $toggleHistory = [IO.File]::ReadAllText($toggleRollout)
    Assert-True (($thirdToggleOutput -join "`n") -match "历史发生了变化") "Toggle did not detect a changed history fingerprint. Output: $($thirdToggleOutput -join ' | ')"
    Assert-True ($toggleConfig -notmatch '(?m)^\s*openai_base_url\s*=') "Third toggle did not return to official mode."
    Assert-True ($toggleConfig -notmatch '(?m)^model_catalog_json\s*=') "Third toggle retained the relay-only model catalog override."
    Assert-True ($toggleHistory.Contains('"id":"msg_toggle_late_message"')) "Third toggle did not automatically repair newly appended history."
    $timing=[IO.File]::ReadAllText((Join-Path $toggleStore 'last-run.json')) | ConvertFrom-Json
    Assert-True ($timing.success -and $null -ne $timing.history -and $timing.history.scan.FullFiles -gt 0) 'Latest run did not record preparation metrics.'
    Assert-True (-not ([IO.File]::ReadAllText((Join-Path $toggleStore 'last-run.json'))).Contains('relay-secret-value')) 'Run statistics included credentials.'
    [void](Invoke-SwitcherProcess 'toggle' $toggleHome $toggleStore $fakeCodex)
    $forcedOutput=@(Invoke-SwitcherProcess 'toggle' $toggleHome $toggleStore $fakeCodex -FullHistoryScan)
    Assert-True (($forcedOutput -join "`n") -match '已指定全量检查') 'Explicit full inspection was skipped by a ready stamp.'
    [void](Invoke-SwitcherProcess 'api' $toggleHome $toggleStore $fakeCodex)
    $cachePath=Join-Path $toggleStore 'history-repair-backups\incremental-cache.json'
    Write-TestFile $cachePath '{}'
    $rebuiltOutput=@(Invoke-SwitcherProcess 'official' $toggleHome $toggleStore $fakeCodex)
    Assert-True (($rebuiltOutput -join "`n") -match '逐文件检查记录变化或缺失' -and
        ([IO.File]::ReadAllText($cachePath) | ConvertFrom-Json).PSObject.Properties['payload']) 'Invalid cache was reused instead of rebuilt by direct official switching.'
    [void](Invoke-SwitcherProcess 'toggle' $toggleHome $toggleStore $fakeCodex)

    # Actual toggle entry: a paginated append must reach the tail-only repair,
    # retain the UI projection and context settings, then enable official auth.
    $tailHome=New-TestHome 'tail-toggle-home'; $tailStore=Join-Path $tempRoot 'tail-toggle-store'
    $tailRollout=Join-Path $tailHome 'sessions\rollout-tail.jsonl'
    Write-TestFile $tailRollout ((@(
        '{"ordinal":0,"type":"session_meta","payload":{"id":"tail-thread","model_provider":"openai","history_mode":"paginated"}}'
        '{"ordinal":1,"type":"event_msg","payload":{"type":"item_completed","thread_id":"tail-thread","turn_id":"tail-turn","item":{"id":"ui-base","type":"AgentMessage","text":"中文旧回复"}}}'
        '{"ordinal":2,"type":"response_item","payload":{"type":"message","id":"msg_base","role":"assistant","content":[{"type":"output_text","text":"中文旧回复"}]}}'
    ) -join "`n") + "`n")
    $tailDb=Join-Path $tailHome 'thread_history_1.sqlite'; $tailLength=(Get-Item -LiteralPath $tailRollout).Length
    [void](Invoke-TestSqlite $tailDb @"
CREATE TABLE thread_history_projection_state(thread_id TEXT PRIMARY KEY,next_rollout_byte_offset INTEGER,next_rollout_ordinal INTEGER);
CREATE TABLE thread_items(thread_id TEXT,turn_id TEXT,item_id TEXT,rollout_ordinal INTEGER,created_at_ms INTEGER,item_json TEXT,item_type TEXT,updated_at_ordinal INTEGER);
CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,rollout_ordinal INTEGER,status TEXT,first_user_item_id TEXT,final_agent_item_id TEXT);
INSERT INTO thread_history_projection_state VALUES('tail-thread',$tailLength,3);
INSERT INTO thread_items VALUES('tail-thread','tail-turn','ui-base',1,1,'{"id":"ui-base","type":"agentMessage","text":"中文旧回复"}','agentMessage',1);
INSERT INTO thread_turns VALUES('tail-thread','tail-turn',1,'completed',NULL,'ui-base');
"@)
    [void](Invoke-SwitcherProcess 'toggle' $tailHome $tailStore $fakeCodex)
    [void](Invoke-SwitcherProcess 'toggle' $tailHome $tailStore $fakeCodex)
    [IO.File]::AppendAllText($tailRollout,'{"ordinal":3,"type":"compacted","payload":{"replacement_history":[{"type":"compaction","id":"cmp_added","encrypted_content":"fixture-kept"}]}}'+"`n",$utf8)
    $tailLength=(Get-Item -LiteralPath $tailRollout).Length
    [void](Invoke-TestSqlite $tailDb "UPDATE thread_history_projection_state SET next_rollout_byte_offset=$tailLength,next_rollout_ordinal=4;")
    $tailDbHash=(Get-FileHash -LiteralPath $tailDb).Hash
    [void](Invoke-SwitcherProcess 'toggle' $tailHome $tailStore $fakeCodex)
    $tailStats=[IO.File]::ReadAllText((Join-Path $tailStore 'last-run.json')) | ConvertFrom-Json
    Assert-True ($tailStats.success -and $tailStats.history.scan.TailFiles -eq 1 -and $tailStats.history.scan.FullFiles -eq 0) 'Toggle did not forward incremental preparation to the history engine.'
    Assert-True ((Get-FileHash -LiteralPath $tailDb).Hash -ceq $tailDbHash -and
        (Get-Item -LiteralPath $tailRollout).Length -eq $tailLength) 'Tail toggle changed UI data or byte positions.'
    $tailRecord=[IO.File]::ReadAllLines($tailRollout)[3] | ConvertFrom-Json
    Assert-True ($null -eq $tailRecord.payload.replacement_history[0].id -and $tailRecord.payload.replacement_history[0].encrypted_content -ceq 'fixture-kept') 'Tail toggle failed to clear only the optional ID.'
    Assert-True ($null -ne ([IO.File]::ReadAllText((Join-Path $tailHome 'auth.json')) | ConvertFrom-Json).tokens) 'Tail toggle did not finish in official mode.'
    $lockedReport=[IO.File]::Open((Join-Path $tailStore 'last-run.json'),[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try { $lockedOutput=@(Invoke-SwitcherProcess 'toggle' $tailHome $tailStore $fakeCodex) }
    finally { $lockedReport.Dispose() }
    Assert-True (($lockedOutput -join "`n") -match '切换已完成，但无法保存本次耗时记录' -and
        ([IO.File]::ReadAllText((Join-Path $tailHome 'auth.json')) | ConvertFrom-Json).OPENAI_API_KEY -ceq 'relay-secret-value') 'Optional timing-report failure broke a completed switch.'

    [IO.File]::AppendAllText(
        $compatibilityRollout,
        "`n{`"timestamp`":`"2026-07-30T00:00:02Z`",`"type`":`"event_msg`",`"payload`":{`"type`":`"user_message`"}}",
        $utf8
    )
    $staleOutput = @(Invoke-SwitcherProcess "official" $testCodexHome $store $fakeCodex)
    Assert-True (($staleOutput -join "`n") -match '历史发生了变化') "Direct official switch did not revalidate changed history."
    Assert-True ($null -ne ([IO.File]::ReadAllText((Join-Path $testCodexHome "auth.json")) | ConvertFrom-Json).tokens) "Direct switch did not install official credentials after revalidation."

    # Integration check: history-prepare must carry the paginated JSONL and
    # thread_items projection through the profile-switcher entry point.
    $paginatedProfileHome = New-TestHome "paginated-profile-home"
    $paginatedProfileStore = Join-Path $tempRoot "paginated-profile-store"
    [void](Invoke-SwitcherProcess "init" $paginatedProfileHome $paginatedProfileStore $fakeCodex)
    $paginatedProfileRollout = Join-Path $paginatedProfileHome "sessions\2026\07\30\rollout-paged.jsonl"
    $profileLongId = "rs_resp_" + ("a" * 36) + "_" + ("b" * 32) + "_0"
    $profileDropJson = '{"type":"reasoning","id":"' + $profileLongId + '","content":null,"encrypted_content":null}'
    Write-TestFile $paginatedProfileRollout ((@(
        '{"ordinal":1,"type":"session_meta","payload":{"id":"paged-profile-thread","model_provider":"legacy-relay","history_mode":"paginated"}}'
        '{"ordinal":2,"type":"response_item","payload":' + $profileDropJson + '}'
    ) -join "`n") + "`n")
    $profileLength = ([IO.File]::ReadAllBytes($paginatedProfileRollout)).Length
    $paginatedProfileDb = Join-Path $paginatedProfileHome "thread_history_1.sqlite"
    [void](Invoke-TestSqlite -Path $paginatedProfileDb -Sql @"
CREATE TABLE thread_history_projection_state (thread_id TEXT PRIMARY KEY, next_rollout_byte_offset INTEGER NOT NULL, next_rollout_ordinal INTEGER NOT NULL);
CREATE TABLE thread_items (thread_id TEXT NOT NULL, turn_id TEXT NOT NULL, item_id TEXT NOT NULL, rollout_ordinal INTEGER NOT NULL, created_at_ms INTEGER NOT NULL, item_json TEXT NOT NULL, item_type TEXT NOT NULL DEFAULT '', updated_at_ordinal INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(thread_id,turn_id,item_id));
INSERT INTO thread_history_projection_state VALUES ('paged-profile-thread',$profileLength,3);
INSERT INTO thread_items VALUES ('paged-profile-thread','turn-1','$profileLongId',2,1000,'$($profileDropJson.Replace("'", "''"))','reasoning',2);
"@)
    [void](Invoke-SwitcherProcess "history-prepare" $paginatedProfileHome $paginatedProfileStore $fakeCodex)
    $profileReady = [IO.File]::ReadAllText((Join-Path $paginatedProfileStore "history-compat-ready.json")) | ConvertFrom-Json
    Assert-True ([int]$profileReady.version -eq 3 -and $profileReady.database_count -ge 1) "Profile history-prepare did not fingerprint the paginated database."
    Assert-True (([IO.File]::ReadAllBytes($paginatedProfileRollout)).Length -eq $profileLength) "Profile history-prepare changed paginated byte length."
    Assert-True (@(Invoke-TestSqlite -Path $paginatedProfileDb -ReadOnly -Sql "SELECT COUNT(*) FROM thread_items;")[0] -eq "0") "Profile history-prepare did not update the paginated projection."
    $noiseDb = Join-Path $paginatedProfileHome 'logs.sqlite'
    [void](Invoke-TestSqlite $noiseDb 'CREATE TABLE log (message TEXT); INSERT INTO log VALUES (''not history'');')
    $noiseStatus = @(Invoke-SwitcherProcess "status" $paginatedProfileHome $paginatedProfileStore $fakeCodex)
    Assert-True (($noiseStatus -join "`n") -match '已准备且历史未变化') "Unrelated logs invalidated history readiness."
    $otherHistoryDb = Join-Path $paginatedProfileHome 'nonstandard-name.sqlite'
    [void](Invoke-TestSqlite $otherHistoryDb 'CREATE TABLE threads (id TEXT, model_provider TEXT);')
    $relatedStatus = @(Invoke-SwitcherProcess "status" $paginatedProfileHome $paginatedProfileStore $fakeCodex)
    Assert-True (($relatedStatus -join "`n") -match '历史发生了变化') "Related database with a nonstandard name was ignored."
    [void](Invoke-SwitcherProcess "history-prepare" $paginatedProfileHome $paginatedProfileStore $fakeCodex)
    [void](Invoke-TestSqlite -Path $paginatedProfileDb -Sql "UPDATE thread_history_projection_state SET next_rollout_ordinal=4 WHERE thread_id='paged-profile-thread';")
    $databaseChangedOutput = @(Invoke-SwitcherProcess "official" $paginatedProfileHome $paginatedProfileStore $fakeCodex)
    Assert-True (($databaseChangedOutput -join "`n") -match '历史发生了变化') "Database change bypassed automatic history revalidation."
    [void](Invoke-SwitcherProcess "official" $paginatedProfileHome $paginatedProfileStore $fakeCodex)

    $env:FAKE_CODEX_LOGIN_FAIL = "1"
    try {
        [void](Invoke-SwitcherProcess "official" $testCodexHome $store $fakeCodex)
    }
    finally {
        Remove-Item Env:FAKE_CODEX_LOGIN_FAIL -ErrorAction SilentlyContinue
    }
    $secondOfficialAuth = [IO.File]::ReadAllText((Join-Path $testCodexHome "auth.json")) | ConvertFrom-Json
    Assert-True ($null -ne $secondOfficialAuth.tokens) "Existing official snapshot was not used for a direct switch."

    # Quick advanced switches must change config/auth only: no history
    # preparation stamp, no model-directory refresh, no model cache writes.
    $quickHome = New-TestHome "quick-home"
    $quickStore = Join-Path $tempRoot "quick-store"
    [void](Invoke-SwitcherProcess "init" $quickHome $quickStore $fakeCodex)
    $quickHistory = Join-Path $quickHome "sessions\2026\07\30\rollout-quick.jsonl"
    Write-TestFile $quickHistory @'
{"timestamp":"2026-07-30T00:00:00Z","type":"response_item","payload":{"type":"reasoning","id":"item_quick_reasoning","summary":[],"content":null,"encrypted_content":null}}
'@
    $quickHistoryBefore = [IO.File]::ReadAllText($quickHistory)
    $quickCacheBefore = (Get-FileHash -LiteralPath (Join-Path $quickHome "models_cache.json")).Hash
    $quickCatalogBefore = (Get-FileHash -LiteralPath (Join-Path $quickHome "models.json")).Hash
    $quickRelayCatalogPath = Join-Path $quickStore "relay-models.json"
    Write-TestFile $quickRelayCatalogPath '{"models":[{"slug":"quick-model","visibility":"list","supported_in_api":true}]}'
    $savedQuickLog = $env:FAKE_CODEX_LOG
    $quickLog = Join-Path $tempRoot "quick-codex.log"
    $env:FAKE_CODEX_LOG = $quickLog
    try {
        [void](Invoke-SwitcherProcess "config-official" $quickHome $quickStore $fakeCodex)
        $quickOfficialConfig = [IO.File]::ReadAllText((Join-Path $quickHome "config.toml"))
        $quickOfficialAuth = [IO.File]::ReadAllText((Join-Path $quickHome "auth.json")) | ConvertFrom-Json
        Assert-True ($quickOfficialConfig -notmatch '(?m)^\s*openai_base_url\s*=') "Quick official switch retained openai_base_url."
        Assert-True ($quickOfficialConfig -match '(?m)^respect_system_proxy = true\r?$') "Quick official switch did not enable the proxy setting."
        Assert-True ($quickOfficialConfig -notmatch '(?m)^\s*model_catalog_json\s*=') "Quick official switch retained the relay catalog."
        Assert-True ($null -ne $quickOfficialAuth.tokens) "Quick official switch did not install official auth."
        Assert-True (-not (Test-Path (Join-Path $quickStore "history-compat-ready.json"))) "Quick official switch prepared history."
        Assert-True ([IO.File]::ReadAllText($quickHistory) -ceq $quickHistoryBefore) "Quick official switch changed history."

        [void](Invoke-SwitcherProcess "config-api" $quickHome $quickStore $fakeCodex)
        $quickApiConfig = [IO.File]::ReadAllText((Join-Path $quickHome "config.toml"))
        $quickApiAuth = [IO.File]::ReadAllText((Join-Path $quickHome "auth.json")) | ConvertFrom-Json
        $quickCatalogLine = 'model_catalog_json = ' + (ConvertTo-Json -Compress ([IO.Path]::GetFullPath($quickRelayCatalogPath)))
        Assert-True ($quickApiConfig -match '(?m)^openai_base_url = "https://relay\.example/v1"\r?$') "Quick API switch did not restore the relay URL."
        Assert-True ($quickApiConfig -match '(?m)^respect_system_proxy = false\r?$') "Quick API switch did not disable the proxy setting."
        Assert-True (([regex]::Split($quickApiConfig, "\r?\n")) -contains $quickCatalogLine) "Quick API switch did not point at the existing relay catalog."
        Assert-True ($quickApiAuth.OPENAI_API_KEY -eq "relay-secret-value") "Quick API switch did not restore relay auth."
        Assert-True (-not (Test-Path (Join-Path $quickStore "history-compat-ready.json"))) "Quick API switch prepared history."
        Assert-True ([IO.File]::ReadAllText($quickHistory) -ceq $quickHistoryBefore) "Quick API switch changed history."

        [void](Invoke-SwitcherProcess "config-official" $quickHome $quickStore $fakeCodex)
        $quickOfficialAgain = [IO.File]::ReadAllText((Join-Path $quickHome "config.toml"))
        Assert-True ($quickOfficialAgain -notmatch '(?m)^\s*model_catalog_json\s*=') "Quick official switch did not remove the relay catalog."

        Assert-True ((Get-FileHash -LiteralPath (Join-Path $quickHome "models_cache.json")).Hash -ceq $quickCacheBefore) "Quick switches changed models_cache.json."
        Assert-True ((Get-FileHash -LiteralPath (Join-Path $quickHome "models.json")).Hash -ceq $quickCatalogBefore) "Quick switches changed models.json."
    }
    finally {
        if ($null -eq $savedQuickLog) { Remove-Item Env:FAKE_CODEX_LOG -ErrorAction SilentlyContinue }
        else { $env:FAKE_CODEX_LOG = $savedQuickLog }
    }
    $quickLogText = if (Test-Path -LiteralPath $quickLog) { [IO.File]::ReadAllText($quickLog) } else { "" }
    Assert-True ($quickLogText -notmatch '(?m)^\s*debug\s+models') "Quick switches refreshed the model directory."

    $rollbackHome = New-TestHome "rollback-home"
    $rollbackStore = Join-Path $tempRoot "rollback-store"
    [void](Invoke-SwitcherProcess "init" $rollbackHome $rollbackStore $fakeCodex)
    $beforeConfig = [IO.File]::ReadAllText((Join-Path $rollbackHome "config.toml"))
    $beforeAuth = [IO.File]::ReadAllText((Join-Path $rollbackHome "auth.json"))

    $env:FAKE_CODEX_LOGIN_FAIL = "1"
    try {
        [void](Invoke-SwitcherProcess "official" $rollbackHome $rollbackStore $fakeCodex $false)
    }
    finally {
        Remove-Item Env:FAKE_CODEX_LOGIN_FAIL -ErrorAction SilentlyContinue
    }

    Assert-True ([IO.File]::ReadAllText((Join-Path $rollbackHome "config.toml")) -ceq $beforeConfig) "Rollback changed config.toml."
    Assert-True ([IO.File]::ReadAllText((Join-Path $rollbackHome "auth.json")) -ceq $beforeAuth) "Rollback changed auth.json."
    Assert-True (-not (Test-Path (Join-Path $rollbackStore "official.auth.dpapi"))) "Failed OAuth created an official snapshot."

    $crashHome = New-TestHome "crash-home"
    $crashStore = Join-Path $tempRoot "crash-store"
    [void](Invoke-SwitcherProcess "init" $crashHome $crashStore $fakeCodex)
    $crashConfigBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $crashHome "config.toml")))
    $crashAuthBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $crashHome "auth.json")))

    $processInfo = New-Object Diagnostics.ProcessStartInfo
    $processInfo.FileName = (Get-Command pwsh).Source
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    foreach ($argument in @(
        "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $switcher,
        "-Command", "official",
        "-CodexHome", $crashHome,
        "-DataDir", $crashStore,
        "-CodexExecutable", $fakeCodex,
        "-UnsafeAllowRunningCodex"
    )) {
        [void]$processInfo.ArgumentList.Add($argument)
    }
    $processInfo.Environment["FAKE_CODEX_LOGIN_HANG"] = "1"
    $crashProcess = [Diagnostics.Process]::Start($processInfo)
    $transactionPath = Join-Path $crashStore "transaction.dpapi"
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path $transactionPath) -and -not $crashProcess.HasExited -and [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 50
    }
    if (-not (Test-Path $transactionPath)) {
        $crashDetail = if ($crashProcess.HasExited) {
            "exit=$($crashProcess.ExitCode); stdout=$($crashProcess.StandardOutput.ReadToEnd()); stderr=$($crashProcess.StandardError.ReadToEnd())"
        }
        else {
            "process still running after timeout"
        }
        if (-not $crashProcess.HasExited) {
            $crashProcess.Kill($true)
            [void]$crashProcess.WaitForExit(5000)
        }
        $crashProcess.Dispose()
        throw "Crash test never reached the durable transaction state: $crashDetail"
    }
    $crashProcess.Kill($true)
    [void]$crashProcess.WaitForExit(5000)
    $crashProcess.Dispose()

    [void](Invoke-SwitcherProcess "status" $crashHome $crashStore $fakeCodex)
    Assert-True (-not (Test-Path $transactionPath)) "Crash recovery did not clear the transaction journal."
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $crashHome "config.toml"))) -ceq $crashConfigBefore) "Crash recovery changed config.toml bytes."
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $crashHome "auth.json"))) -ceq $crashAuthBefore) "Crash recovery changed auth.json bytes."

    $quotedKeyHome = New-TestHome "quoted-key-home"
    $quotedKeyStore = Join-Path $tempRoot "quoted-key-store"
    $quotedConfigPath = Join-Path $quotedKeyHome "config.toml"
    $quotedConfig = [IO.File]::ReadAllText($quotedConfigPath).Replace(
        'openai_base_url = "https://relay.example/v1"',
        '"openai_base_url" = "https://relay.example/v1"'
    )
    Write-TestFile $quotedConfigPath $quotedConfig
    [void](Invoke-SwitcherProcess "init" $quotedKeyHome $quotedKeyStore $fakeCodex $false)
    Assert-True (-not (Test-Path (Join-Path $quotedKeyStore "relay.auth.dpapi"))) "Unsupported quoted TOML key created a relay snapshot."
    $lastErrorPath = Join-Path $quotedKeyStore "last-error.json"
    Assert-True (Test-Path -LiteralPath $lastErrorPath) "Failure did not persist a diagnostic report."
    $lastError = [IO.File]::ReadAllText($lastErrorPath) | ConvertFrom-Json
    Assert-True ($lastError.action -eq 'init' -and $lastError.source_line -gt 0) "Diagnostic lost action or failure location."
    Assert-True (-not ([IO.File]::ReadAllText($lastErrorPath).Contains('relay-secret-value'))) "Diagnostic leaked credentials."
    [void](Invoke-SwitcherProcess "init" $quotedKeyHome $quotedKeyStore $fakeCodex $false)
    Assert-True (@(Get-ChildItem -LiteralPath $quotedKeyStore -Filter '*error*').Count -eq 1) "Diagnostics accumulated instead of keeping one report."

    $providerParentHome = New-TestHome "provider-parent-home"
    $providerParentStore = Join-Path $tempRoot "provider-parent-store"
    $providerParentConfigPath = Join-Path $providerParentHome "config.toml"
    $providerParentConfig = [IO.File]::ReadAllText($providerParentConfigPath) + @'

[model_providers]
openai = { base_url = "https://unexpected-relay.example/v1" }
'@
    Write-TestFile $providerParentConfigPath $providerParentConfig
    [void](Invoke-SwitcherProcess "init" $providerParentHome $providerParentStore $fakeCodex $false)
    Assert-True (-not (Test-Path (Join-Path $providerParentStore "relay.auth.dpapi"))) "Unsupported [model_providers] parent table created a relay snapshot."

    $multilineRootHome = New-TestHome "multiline-root-home"
    $multilineRootStore = Join-Path $tempRoot "multiline-root-store"
    $multilineRootConfigPath = Join-Path $multilineRootHome "config.toml"
    $multilineRootConfig = [IO.File]::ReadAllText($multilineRootConfigPath).Replace(
        'openai_base_url = "https://relay.example/v1"',
        "root_array = [`n  `"[not-a-table]`"`n]`nopenai_base_url = `"https://relay.example/v1`""
    )
    Write-TestFile $multilineRootConfigPath $multilineRootConfig
    [void](Invoke-SwitcherProcess "init" $multilineRootHome $multilineRootStore $fakeCodex $false)
    Assert-True (-not (Test-Path (Join-Path $multilineRootStore "relay.auth.dpapi"))) "Unsupported root multiline TOML created a relay snapshot."

    $emptyTokensHome = New-TestHome "empty-tokens-home"
    $emptyTokensStore = Join-Path $tempRoot "empty-tokens-store"
    $emptyTokensConfigPath = Join-Path $emptyTokensHome "config.toml"
    $emptyTokensConfig = [regex]::Replace(
        [IO.File]::ReadAllText($emptyTokensConfigPath),
        '(?m)^openai_base_url = .+\r?\n',
        ''
    )
    Write-TestFile $emptyTokensConfigPath $emptyTokensConfig
    Write-TestFile (Join-Path $emptyTokensHome "auth.json") '{"auth_mode":"chatgpt","tokens":{}}'
    [void](Invoke-SwitcherProcess "init" $emptyTokensHome $emptyTokensStore $fakeCodex $false)
    Assert-True (-not (Test-Path (Join-Path $emptyTokensStore "official.auth.dpapi"))) "Incomplete OAuth tokens created an official snapshot."

    $updatedUrlHome = New-TestHome "updated-url-home"
    $updatedUrlStore = Join-Path $tempRoot "updated-url-store"
    [void](Invoke-SwitcherProcess "init" $updatedUrlHome $updatedUrlStore $fakeCodex)
    $changedConfigPath = Join-Path $updatedUrlHome "config.toml"
    $changedConfig = [IO.File]::ReadAllText($changedConfigPath).Replace(
        'https://relay.example/v1',
        'https://other-relay.example/v1'
    )
    Write-TestFile $changedConfigPath $changedConfig
    [void](Invoke-SwitcherProcess "official" $updatedUrlHome $updatedUrlStore $fakeCodex)
    [void](Invoke-SwitcherProcess "api" $updatedUrlHome $updatedUrlStore $fakeCodex)
    $updatedConfig = [IO.File]::ReadAllText($changedConfigPath)
    $updatedConfigLines = [regex]::Split($updatedConfig, "\r?\n")
    Assert-True ($updatedConfigLines -contains 'openai_base_url = "https://other-relay.example/v1"') "Updated relay URL was not automatically adopted."
    Assert-True (-not ($updatedConfigLines -contains 'openai_base_url = "https://relay.example/v1"')) "The previous relay URL was restored after automatic update."

    $tamperedStateHome = New-TestHome "tampered-state-home"
    $tamperedStateStore = Join-Path $tempRoot "tampered-state-store"
    [void](Invoke-SwitcherProcess "init" $tamperedStateHome $tamperedStateStore $fakeCodex)
    $tamperedStatePath = Join-Path $tamperedStateStore "state.dpapi"
    $tamperedState = [IO.File]::ReadAllBytes($tamperedStatePath)
    $tamperedState[$tamperedState.Length - 1] = $tamperedState[$tamperedState.Length - 1] -bxor 0x01
    [IO.File]::WriteAllBytes($tamperedStatePath, $tamperedState)
    $tamperedConfigHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $tamperedStateHome "config.toml")).Hash
    $tamperedAuthHash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $tamperedStateHome "auth.json")).Hash
    [void](Invoke-SwitcherProcess "api" $tamperedStateHome $tamperedStateStore $fakeCodex $false)
    Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $tamperedStateHome "config.toml")).Hash -eq $tamperedConfigHash) "Tampered state changed config.toml."
    Assert-True ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $tamperedStateHome "auth.json")).Hash -eq $tamperedAuthHash) "Tampered state changed auth.json."

    Write-Host "All Codex profile switcher tests passed."
}
finally {
    if ([IO.Directory]::Exists($tempRoot)) {
        $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolvedTemp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove non-temporary test path: $resolvedTemp"
        }
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
