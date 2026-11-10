#requires -Version 7.0

[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $env:USERPROFILE ".codex\config.toml")
)
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot


Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$switcher = Join-Path $script:ProjectRoot "codex-profile-switcher.ps1"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-live-config-preservation-" + [Guid]::NewGuid().ToString("N"))
$testHome = Join-Path $tempRoot "codex-home"
$testStore = Join-Path $tempRoot "store"
$utf8 = New-Object Text.UTF8Encoding($false)

function Get-UnmanagedConfig {
    param([Parameter(Mandatory = $true)][string]$Text)

    $result = New-Object Collections.Generic.List[string]
    $isTopLevel = $true
    $currentTable = ""
    foreach ($line in [regex]::Split($Text, "\r?\n")) {
        if ($line -match '^\s*\[(?<name>[A-Za-z0-9_.-]+)\]\s*(?:#.*)?$') {
            $currentTable = $Matches["name"]
            $isTopLevel = $false
        }
        elseif ($line -match '^\s*\[') {
            $currentTable = ""
            $isTopLevel = $false
        }
        if ($isTopLevel -and $line -match '^\s*(model_provider|openai_base_url|model_catalog_json|cli_auth_credentials_store)\s*=') {
            continue
        }
        if ($currentTable -ceq "features" -and $line -match '^\s*respect_system_proxy\s*=') {
            continue
        }
        $result.Add($line)
    }
    return [string]::Join("`n", $result)
}

function Invoke-TestSwitcher {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][string]$FakeCodex
    )

    $output = @(& pwsh -NoLogo -NoProfile -ExecutionPolicy Bypass -File $switcher `
        -Command $Action `
        -CodexHome $testHome `
        -DataDir $testStore `
        -MonitorDataDir (Join-Path $testStore "monitor") `
        -CodexExecutable $FakeCodex `
        -UnsafeAllowRunningCodex 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Temporary switch '$Action' failed: $($output -join ' | ')"
    }
}

try {
    [IO.Directory]::CreateDirectory($testHome) | Out-Null
    [IO.Directory]::CreateDirectory($testStore) | Out-Null

    $testConfigPath = Join-Path $testHome "config.toml"
    [IO.File]::WriteAllBytes($testConfigPath, [IO.File]::ReadAllBytes($ConfigPath))
    $testConfigText = [IO.File]::ReadAllText($testConfigPath)
    # A live relay config points at the production switcher's catalog path.
    # Remap that managed path inside this isolated fixture so the test never
    # treats production state as a caller-owned custom catalog.
    $catalogAssignment = [regex]::Match(
        $testConfigText,
        '(?m)^\s*model_catalog_json\s*=\s*(?<literal>"(?:\\.|[^"])*")\s*$'
    )
    if ($catalogAssignment.Success) {
        $catalogPath = [string]($catalogAssignment.Groups["literal"].Value | ConvertFrom-Json)
        $productionCatalogPath = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "CodexProfileSwitcher\relay-models.json"))
        if ([string]::Equals([IO.Path]::GetFullPath($catalogPath), $productionCatalogPath, [StringComparison]::OrdinalIgnoreCase)) {
            $isolatedCatalogPath = [IO.Path]::GetFullPath((Join-Path $testStore "relay-models.json"))
            $isolatedCatalogLine = 'model_catalog_json = ' + (ConvertTo-Json -Compress $isolatedCatalogPath)
            $testConfigText = [regex]::Replace(
                $testConfigText,
                '(?m)^\s*model_catalog_json\s*=.*$',
                [System.Text.RegularExpressions.MatchEvaluator]{ param($match) $isolatedCatalogLine },
                1
            )
            [IO.File]::WriteAllText($testConfigPath, $testConfigText, $utf8)
        }
    }
    if ($testConfigText -notmatch '(?m)^\s*openai_base_url\s*=') {
        [IO.File]::WriteAllText(
            $testConfigPath,
            "openai_base_url = `"https://relay.example/v1`"`r`n" + $testConfigText,
            $utf8
        )
    }
    $relayMatch = [regex]::Match([IO.File]::ReadAllText($testConfigPath), '(?m)^\s*openai_base_url\s*=\s*"([^"]+)"')
    if (-not $relayMatch.Success) {
        throw "Temporary test config has no relay URL."
    }
    $expectedRelayLine = 'openai_base_url = "' + $relayMatch.Groups[1].Value + '"'
    [IO.File]::WriteAllText(
        (Join-Path $testHome "auth.json"),
        '{"OPENAI_API_KEY":"temporary-test-key"}',
        $utf8
    )
    [IO.File]::WriteAllText(
        (Join-Path $testHome "models_cache.json"),
        '{"models":[{"slug":"gpt-6.1-sol","visibility":"list","supported_in_api":true,"context_window":500000},{"slug":"temporary-model","visibility":"list","supported_in_api":true,"context_window":272000}]}',
        $utf8
    )
    $manualCatalogPath = [IO.Path]::GetFullPath((Join-Path $testStore "relay-models.json"))
    [IO.File]::WriteAllText((Join-Path $testStore 'settings.json'),'{"version":1,"official_proxy":"system","api_proxy":"direct","context_window":""}',$utf8)
    $manualCatalogText = '{"models":[{"slug":"manual-relay-entry"}]}'
    [IO.File]::WriteAllText($manualCatalogPath, $manualCatalogText, $utf8)

    $fakeCodex = Join-Path $tempRoot "fake-codex.ps1"
    $fakeSource = @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
$authPath = Join-Path $env:CODEX_HOME "auth.json"
if ($Arguments.Count -ge 1 -and $Arguments[0] -eq "login") {
    if ($Arguments.Count -ge 2 -and $Arguments[1] -eq "status") {
        $auth = Get-Content -Raw -LiteralPath $authPath | ConvertFrom-Json
        if ($null -ne $auth.PSObject.Properties["tokens"]) {
            Write-Output "Logged in using ChatGPT"
        }
        else {
            Write-Output "Logged in using an API key"
        }
        exit 0
    }

    $officialAuth = [ordered]@{
        auth_mode = "chatgpt"
        tokens = [ordered]@{
            id_token = "id"
            access_token = "access"
            refresh_token = "refresh"
            account_id = "account"
        }
    } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText(
        $authPath,
        $officialAuth,
        (New-Object Text.UTF8Encoding($false))
    )
    exit 0
}
exit 3
'@
    [IO.File]::WriteAllText($fakeCodex, $fakeSource, $utf8)

    $originalText = [IO.File]::ReadAllText($testConfigPath)
    $originalUnmanaged = Get-UnmanagedConfig $originalText

    Invoke-TestSwitcher -Action "init" -FakeCodex $fakeCodex
    Invoke-TestSwitcher -Action "official" -FakeCodex $fakeCodex
    $officialText = [IO.File]::ReadAllText($testConfigPath)
    $officialPreserved = (Get-UnmanagedConfig $officialText) -ceq $originalUnmanaged
    $officialUsesSystemProxy = $officialText -match '(?m)^\s*respect_system_proxy\s*=\s*true\s*$'

    $futurePlugin = "`r`n[plugins.`"future-config-test`"]`r`nenabled = true`r`n"
    [IO.File]::WriteAllText($testConfigPath, $officialText + $futurePlugin, $utf8)
    Invoke-TestSwitcher -Action "api" -FakeCodex $fakeCodex
    $apiText = [IO.File]::ReadAllText($testConfigPath)
    $apiLines = [regex]::Split($apiText, "\r?\n")
    $pluginSurvivedApiSwitch = $apiLines -contains '[plugins."future-config-test"]'
    $apiRouteRestored = $apiLines -contains $expectedRelayLine
    $relayCatalogPath = [IO.Path]::GetFullPath((Join-Path $testStore "relay-models.json"))
    $expectedRelayCatalogLine = 'model_catalog_json = ' + (ConvertTo-Json -Compress $relayCatalogPath)
    $apiCatalogRestored = $apiLines -contains $expectedRelayCatalogLine
    $relayCatalogUnchanged = [IO.File]::ReadAllText($manualCatalogPath) -ceq $manualCatalogText
    $apiBypassesSystemProxy = $apiText -match '(?m)^\s*respect_system_proxy\s*=\s*false\s*$'

    $updatedApiText = $apiText -replace '(?m)^personality\s*=.*$', 'personality = "config-update-test"'
    [IO.File]::WriteAllText($testConfigPath, $updatedApiText, $utf8)
    $updatedUnmanaged = Get-UnmanagedConfig $updatedApiText
    Invoke-TestSwitcher -Action "official" -FakeCodex $fakeCodex
    $finalOfficialText = [IO.File]::ReadAllText($testConfigPath)
    $apiUpdatesSurvivedOfficialSwitch = (Get-UnmanagedConfig $finalOfficialText) -ceq $updatedUnmanaged
    $officialRouteRemoved = $finalOfficialText -notmatch '(?m)^\s*openai_base_url\s*='
    $officialCatalogRemoved = $finalOfficialText -notmatch '(?m)^\s*model_catalog_json\s*='
    $finalOfficialUsesSystemProxy = $finalOfficialText -match '(?m)^\s*respect_system_proxy\s*=\s*true\s*$'

    [pscustomobject]@{
        CurrentFullConfigPreservedOnOfficial = $officialPreserved
        OfficialUsesSystemProxy = $officialUsesSystemProxy
        PluginAddedInOfficialSurvivedApi = $pluginSurvivedApiSwitch
        ApiRouteRestored = $apiRouteRestored
        ApiCatalogRestored = $apiCatalogRestored
        RelayCatalogUnchanged = $relayCatalogUnchanged
        ApiBypassesSystemProxy = $apiBypassesSystemProxy
        ApiModeConfigUpdateSurvivedOfficial = $apiUpdatesSurvivedOfficialSwitch
        OfficialRouteRemoved = $officialRouteRemoved
        OfficialCatalogRemoved = $officialCatalogRemoved
        FinalOfficialUsesSystemProxy = $finalOfficialUsesSystemProxy
    } | Format-List
    if (-not ($officialPreserved -and $officialUsesSystemProxy -and $pluginSurvivedApiSwitch -and $apiRouteRestored -and $apiCatalogRestored -and $relayCatalogUnchanged -and $apiBypassesSystemProxy -and $apiUpdatesSurvivedOfficialSwitch -and $officialRouteRemoved -and $officialCatalogRemoved -and $finalOfficialUsesSystemProxy)) {
        throw "One or more live-config preservation checks failed."
    }
}
finally {
    if ([IO.Directory]::Exists($tempRoot)) {
        $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolvedTemp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove non-temporary path: $resolvedTemp"
        }
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
