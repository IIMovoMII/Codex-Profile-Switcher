#requires -Version 7.0
[CmdletBinding()]
param([ValidateSet('pwsh','powershell')][string]$Engine = 'pwsh')
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot


Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('codex-universal-profile-test-' + [Guid]::NewGuid().ToString('N'))
$utf8 = New-Object Text.UTF8Encoding($false)
$switcher = Join-Path $script:ProjectRoot 'codex-profile-switcher.ps1'

function Assert-True([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Write-Json([string]$Path, $Value) {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 20 -Compress), $utf8)
}
function Invoke-ProfileAction {
    param([string]$Action, [string]$CodexHomePath, [string]$Store, [string]$Fake, [string[]]$InputLines = @(), [hashtable]$Environment = @{}, [string]$ProfileSelector, [bool]$ExpectSuccess = $true)
    $inputPath = Join-Path $root 'answers.json'
    Write-Json $inputPath @($InputLines)
    $arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$harness,'-Switcher',$switcher,'-Action',$Action,
        '-CodexHome',$CodexHomePath,'-DataDir',$Store,'-MonitorDataDir',(Join-Path $Store 'monitor'),
        '-CodexExecutable',$Fake,'-InputPath',$inputPath)
    if ($ProfileSelector) { $arguments += @('-ProfileSelector',$ProfileSelector) }
    $old = @{}
    foreach ($key in $Environment.Keys) { $old[$key] = [Environment]::GetEnvironmentVariable([string]$key,'Process'); [Environment]::SetEnvironmentVariable([string]$key,[string]$Environment[$key],'Process') }
    try {
        $output = @(& $Engine @arguments 2>&1)
        $code = $LASTEXITCODE
    }
    finally { foreach ($key in $Environment.Keys) { [Environment]::SetEnvironmentVariable([string]$key,$old[$key],'Process') } }
    if ($ExpectSuccess) { Assert-True ($code -eq 0) ("Action $Action failed: " + ($output -join ' | ')) }
    else { Assert-True ($code -ne 0) ("Action $Action unexpectedly succeeded.") }
    foreach ($line in @('fixture-api-one','fixture-api-two','fixture-api-new')) {
        Assert-True (($output -join ' ') -notlike "*$line*") 'A fixture API key leaked to the console.'
    }
    return @($output)
}

try {
    [IO.Directory]::CreateDirectory($root) | Out-Null
    # Mock only console input; the switcher, CLI boundary, encrypted files and
    # mode transactions still run in a separate PowerShell process.
    $harness = Join-Path $root 'input-harness.ps1'
    [IO.File]::WriteAllText($harness, @'
param($Switcher,$Action,$CodexHome,$DataDir,$MonitorDataDir,$CodexExecutable,$InputPath,$ProfileSelector)
$ErrorActionPreference = 'Stop'
[object[]]$global:ProfileTestAnswers = @()
$parsedAnswers = Get-Content -Encoding UTF8 -Raw -LiteralPath $InputPath | ConvertFrom-Json
if ($null -ne $parsedAnswers) { $global:ProfileTestAnswers = $parsedAnswers }
$global:ProfileTestAnswerIndex = 0
function global:Read-Host {
    param($Prompt,[switch]$AsSecureString)
    if ($global:ProfileTestAnswerIndex -ge $global:ProfileTestAnswers.Count) { throw "Unexpected prompt: $Prompt" }
    $answer = [string]$global:ProfileTestAnswers[$global:ProfileTestAnswerIndex++]
    if ($AsSecureString) { return ConvertTo-SecureString -String $answer -AsPlainText -Force }
    return $answer
}
$parameters = @{Command=$Action;CodexHome=$CodexHome;DataDir=$DataDir;MonitorDataDir=$MonitorDataDir;CodexExecutable=$CodexExecutable;UnsafeAllowRunningCodex=$true}
if ($ProfileSelector) { $parameters.Profile = $ProfileSelector }
& $Switcher @parameters
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if ($global:ProfileTestAnswerIndex -ne $global:ProfileTestAnswers.Count) { throw 'Not all fixture answers were consumed.' }
exit 0
'@, $utf8)
    $fixtureHome = Join-Path $root '中文 CODEX HOME'
    $store = Join-Path $root '状态档案'
    [IO.Directory]::CreateDirectory($fixtureHome) | Out-Null
    $config = Join-Path $fixtureHome 'config.toml'
    $auth = Join-Path $fixtureHome 'auth.json'
    [IO.File]::WriteAllText($config, @'
model_provider = "openai"
openai_base_url = "https://relay-one.example/v1"
cli_auth_credentials_store = "file"

[features]
respect_system_proxy = false
'@, $utf8)
    Write-Json $auth @{ OPENAI_API_KEY = 'fixture-api-one' }
    $fake = Join-Path $root 'fake-codex.ps1'
    [IO.File]::WriteAllText($fake, @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
$authPath = Join-Path $env:CODEX_HOME 'auth.json'
if ($Arguments.Count -ge 2 -and $Arguments[0] -eq 'login' -and $Arguments[1] -eq 'status') {
  $a = Get-Content -Raw -LiteralPath $authPath | ConvertFrom-Json
  if ($env:FAKE_CODEX_READONLY_STATE -and $null -ne $a.PSObject.Properties['OPENAI_API_KEY'] -and $a.OPENAI_API_KEY -eq 'fixture-api-two') {
    [IO.File]::SetAttributes($env:FAKE_CODEX_READONLY_STATE,[IO.FileAttributes]::ReadOnly)
  }
  if ($null -ne $a.PSObject.Properties['tokens']) { 'Logged in using ChatGPT' } elseif ($a.OPENAI_API_KEY) { 'Logged in using an API key' } else { exit 2 }
  exit 0
}
if ($Arguments.Count -ge 1 -and $Arguments[0] -eq 'login') {
  if ($env:FAKE_CODEX_LOGIN_FAIL -eq '1') { exit 23 }
  if ($env:FAKE_CODEX_REQUIRE_EMPTY_AUTH -eq '1' -and (Test-Path -LiteralPath $authPath)) { exit 24 }
  $account = if ($env:FAKE_CODEX_ACCOUNT) { $env:FAKE_CODEX_ACCOUNT } else { 'account-one' }
  $claims = @{'https://api.openai.com/auth'=@{chatgpt_user_id="user-$account";chatgpt_account_id=$account}} | ConvertTo-Json -Compress
  $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($claims)).TrimEnd('=').Replace('+','-').Replace('/','_')
  $auth = [ordered]@{auth_mode='chatgpt';tokens=[ordered]@{id_token="test.$payload.signature";access_token="access-$account";refresh_token="refresh-$account";account_id=$account}} | ConvertTo-Json -Depth 8
  [IO.File]::WriteAllText($authPath,$auth,(New-Object Text.UTF8Encoding($false)))
  exit 0
}
exit 3
'@, $utf8)

    $globalPath = Join-Path $fixtureHome '.codex-global-state.json'
    Write-Json $globalPath @{
        'local-projects' = @{'shared-one'=@{id='shared-one';name='共享项目一';rootPaths=@('D:\SharedOne')}}
        'project-order' = @('shared-one')
        'electron-persisted-atom-state' = @{
            'electron:onboarding-welcome-v2-role-state' = @{completedConversationalOnboarding=$true;conversationalOnboardingSkipped=$true;roles=@()}
        }
    }

    [void](Invoke-ProfileAction init $fixtureHome $store $fake)
    $registryPath = Join-Path $store 'profiles.json'
    Assert-True (Test-Path -LiteralPath $registryPath) 'Initial API setup did not create a profile registry.'
    $registry = Get-Content -Raw -LiteralPath $registryPath | ConvertFrom-Json
    Assert-True ($registry.api_profiles.Count -eq 1) 'Initial API profile was not migrated.'
    [void](Invoke-ProfileAction profile-add-api $fixtureHome $store $fake @('默认中转 API','https://relay-one.example/v1','','fixture-api-one'))
    $registry = Get-Content -Raw -LiteralPath $registryPath | ConvertFrom-Json
    Assert-True ($registry.api_profiles.Count -eq 1) 'The same API key was duplicated because its JSON formatting changed.'

    # Register a second API key and switch to it and back.
    $secondCatalog = Join-Path $root '第二 API models.json'
    [IO.File]::WriteAllText($secondCatalog, '{"models":[]}', $utf8)
    [void](Invoke-ProfileAction profile-add-api $fixtureHome $store $fake @('第二中转','https://relay-two.example/v1',$secondCatalog,'fixture-api-two'))
    $registry = Get-Content -Raw -LiteralPath $registryPath | ConvertFrom-Json
    Assert-True ($registry.api_profiles.Count -eq 2) 'Second API profile was not registered.'
    [void](Invoke-ProfileAction profile-use-api $fixtureHome $store $fake -ProfileSelector '第二中转')
    $activeConfig = Get-Content -Raw -LiteralPath $config
    $activeAuth = Get-Content -Raw -LiteralPath $auth | ConvertFrom-Json
    Assert-True ($activeConfig -match 'https://relay-two\.example/v1' -and $activeAuth.OPENAI_API_KEY -ceq 'fixture-api-two') 'Second API profile did not become active.'
    Assert-True ($activeConfig.Contains(($secondCatalog | ConvertTo-Json -Compress))) 'The selected API model catalog was not used.'
    [void](Invoke-ProfileAction profiles $fixtureHome $store $fake)
    $registry = Get-Content -Raw -LiteralPath $registryPath | ConvertFrom-Json
    Assert-True ($registry.api_profiles.Count -eq 2) 'Listing profiles re-imported an old key under the new API URL.'
    $secondApi = @($registry.api_profiles | Where-Object name -eq '第二中转')[0]
    Assert-True ($registry.active_api_profile_id -ceq $secondApi.id) 'Listing profiles changed the selected API profile.'
    [void](Invoke-ProfileAction profile-use-api $fixtureHome $store $fake -ProfileSelector '默认中转 API')
    $activeConfig = Get-Content -Raw -LiteralPath $config
    $activeAuth = Get-Content -Raw -LiteralPath $auth | ConvertFrom-Json
    Assert-True ($activeConfig -match 'https://relay-one\.example/v1' -and $activeAuth.OPENAI_API_KEY -ceq 'fixture-api-one') 'First API profile was not restored.'
    $beforeFailedSwapConfig = [IO.File]::ReadAllBytes($config)
    $beforeFailedSwapAuth = [IO.File]::ReadAllBytes($auth)
    $statePath = Join-Path $store 'state.dpapi'
    try {
        [void](Invoke-ProfileAction profile-use-api $fixtureHome $store $fake -ProfileSelector '第二中转' -Environment @{FAKE_CODEX_READONLY_STATE=$statePath} -ExpectSuccess $false)
    }
    finally { [IO.File]::SetAttributes($statePath,[IO.FileAttributes]::Normal) }
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($config)) -ceq [Convert]::ToBase64String($beforeFailedSwapConfig)) 'Failed profile commit left the target config active.'
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($auth)) -ceq [Convert]::ToBase64String($beforeFailedSwapAuth)) 'Failed profile commit left the target auth active.'
    $registry = Get-Content -Raw -LiteralPath $registryPath | ConvertFrom-Json
    $firstApi = @($registry.api_profiles | Where-Object name -eq '默认中转 API')[0]
    Assert-True ($registry.active_api_profile_id -ceq $firstApi.id) 'Partial metadata commit did not roll the selected profile back.'
    Assert-True (-not (Test-Path (Join-Path $store 'transaction.dpapi'))) 'Failed profile commit left an unrecovered transaction.'

    # Add two official accounts while preserving the current API mode.
    [void](Invoke-ProfileAction profile-add-official $fixtureHome $store $fake @('官方一') @{FAKE_CODEX_ACCOUNT='account-one';FAKE_CODEX_REQUIRE_EMPTY_AUTH='1'})
    [void](Invoke-ProfileAction profile-add-official $fixtureHome $store $fake @('官方二') @{FAKE_CODEX_ACCOUNT='account-two';FAKE_CODEX_REQUIRE_EMPTY_AUTH='1'})
    $registry = Get-Content -Raw -LiteralPath $registryPath | ConvertFrom-Json
    Assert-True ($registry.official_profiles.Count -eq 2) 'Two official profiles were not registered.'
    $restoredApiAuth = Get-Content -Raw -LiteralPath $auth | ConvertFrom-Json
    Assert-True ($restoredApiAuth.OPENAI_API_KEY -ceq 'fixture-api-one') 'Adding official accounts changed the active API account.'
    $beforeFailedLoginConfig = [IO.File]::ReadAllBytes($config)
    $beforeFailedLoginAuth = [IO.File]::ReadAllBytes($auth)
    [void](Invoke-ProfileAction profile-add-official $fixtureHome $store $fake @('失败账号') @{FAKE_CODEX_LOGIN_FAIL='1'} -ExpectSuccess $false)
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($config)) -ceq [Convert]::ToBase64String($beforeFailedLoginConfig)) 'Failed OAuth enrollment did not restore the configuration.'
    Assert-True ([Convert]::ToBase64String([IO.File]::ReadAllBytes($auth)) -ceq [Convert]::ToBase64String($beforeFailedLoginAuth)) 'Failed OAuth enrollment did not restore the authentication.'
    [void](Invoke-ProfileAction profile-use-official $fixtureHome $store $fake -ProfileSelector '官方二')
    $officialAuth = Get-Content -Raw -LiteralPath $auth | ConvertFrom-Json
    Assert-True ($officialAuth.tokens.account_id -ceq 'account-two') 'Second official account did not become active.'
    $desktop = Get-Content -Raw -LiteralPath $globalPath | ConvertFrom-Json -AsHashtable
    $desktop['local-projects']['shared-two'] = @{id='shared-two';name='共享项目二';rootPaths=@('D:\SharedTwo')}
    $desktop['electron-persisted-atom-state']['profile-private'] = 'account-two-only'
    $desktop['selected-project'] = @{projectKind='chatgpt';projectId='cloud-two'}
    Write-Json $globalPath $desktop
    [void](Invoke-ProfileAction profile-use-official $fixtureHome $store $fake -ProfileSelector '官方一')
    $officialAuth = Get-Content -Raw -LiteralPath $auth | ConvertFrom-Json
    Assert-True ($officialAuth.tokens.account_id -ceq 'account-one') 'First official account was not restored.'
    $desktop = Get-Content -Raw -LiteralPath $globalPath | ConvertFrom-Json -AsHashtable
    Assert-True ($desktop['local-projects'].Count -eq 2) 'Projects created under the other official account were not shared.'
    Assert-True (-not $desktop['electron-persisted-atom-state'].ContainsKey('profile-private') -and -not $desktop.ContainsKey('selected-project')) 'Account-two private state leaked into account one.'
    $desktop['local-projects']['shared-three'] = @{id='shared-three';name='共享项目三';rootPaths=@('D:\SharedThree')}
    $desktop['electron-persisted-atom-state']['profile-private'] = 'account-one-only'
    Write-Json $globalPath $desktop
    [void](Invoke-ProfileAction profile-use-official $fixtureHome $store $fake -ProfileSelector '官方二')
    $desktop = Get-Content -Raw -LiteralPath $globalPath | ConvertFrom-Json -AsHashtable
    Assert-True ($desktop['local-projects'].Count -eq 3 -and $desktop['electron-persisted-atom-state']['profile-private'] -ceq 'account-two-only') 'Account-two restoration lost shared projects or restored the wrong private state.'
    [void](Invoke-ProfileAction profile-use-api $fixtureHome $store $fake -ProfileSelector '第二中转')
    $desktop = Get-Content -Raw -LiteralPath $globalPath | ConvertFrom-Json -AsHashtable
    Assert-True ($desktop['local-projects'].Count -eq 3 -and -not $desktop['electron-persisted-atom-state'].ContainsKey('profile-private')) 'API switching lost shared projects or retained private account state.'
    [void](Invoke-ProfileAction profile-use-official $fixtureHome $store $fake -ProfileSelector '官方一')
    $desktop = Get-Content -Raw -LiteralPath $globalPath | ConvertFrom-Json -AsHashtable
    Assert-True ($desktop['local-projects'].Count -eq 3 -and $desktop['electron-persisted-atom-state']['profile-private'] -ceq 'account-one-only') 'Account-one restoration did not preserve shared projects and its own private state.'
    $officialAuth.tokens.access_token = 'refreshed-access-account-one'
    $officialAuth.tokens.refresh_token = 'refreshed-refresh-account-one'
    Write-Json $auth $officialAuth
    [void](Invoke-ProfileAction profile-use-official $fixtureHome $store $fake -ProfileSelector '官方一')
    $officialAuth = Get-Content -Raw -LiteralPath $auth | ConvertFrom-Json
    Assert-True ($officialAuth.tokens.access_token -ceq 'refreshed-access-account-one') 'Selecting the current account restored stale tokens over its refreshed credentials.'
    [void](Invoke-ProfileAction init $fixtureHome $store $fake)
    $registry = Get-Content -Raw -LiteralPath $registryPath | ConvertFrom-Json
    Assert-True ($registry.official_profiles.Count -eq 2) 'Refreshing tokens created a duplicate official account.'

    # Fresh users have neither a CODEX_HOME nor config/auth files.
    $freshApiHome = Join-Path $root '首次 API'
    $freshApiStore = Join-Path $root '首次 API store'
    [void](Invoke-ProfileAction setup $freshApiHome $freshApiStore $fake @('api','https://first.example/v1','fixture-api-new','首次 API'))
    $freshRegistry = Get-Content -Raw -LiteralPath (Join-Path $freshApiStore 'profiles.json') | ConvertFrom-Json
    Assert-True ($freshRegistry.api_profiles.Count -eq 1 -and $freshRegistry.api_profiles[0].name -ceq '首次 API') 'Fresh API setup failed.'
    $freshOfficialHome = Join-Path $root '首次官方'
    $freshOfficialStore = Join-Path $root '首次官方 store'
    [void](Invoke-ProfileAction setup $freshOfficialHome $freshOfficialStore $fake @('official','首次官方'))
    $freshRegistry = Get-Content -Raw -LiteralPath (Join-Path $freshOfficialStore 'profiles.json') | ConvertFrom-Json
    Assert-True ($freshRegistry.official_profiles.Count -eq 1) 'Fresh official setup failed.'
    $failedSetupHome = Join-Path $root '取消首次设置'
    $failedSetupStore = Join-Path $root '取消首次 store'
    [void](Invoke-ProfileAction setup $failedSetupHome $failedSetupStore $fake @('official') @{FAKE_CODEX_LOGIN_FAIL='1'} -ExpectSuccess $false)
    Assert-True (-not (Test-Path (Join-Path $failedSetupHome 'auth.json')) -and -not (Test-Path (Join-Path $failedSetupHome 'config.toml'))) 'Failed first-use login left partial config/auth files.'
    $allRegistryText = Get-Content -Raw -LiteralPath $registryPath
    Assert-True ($allRegistryText -notmatch 'fixture-api-|access-account|refresh-account') 'The profile registry contains plaintext credentials.'

    Write-Host 'Universal profile tests passed: first-use API/OAuth, migration, 2 APIs, 2 accounts, shared projects/private-state isolation, catalog selection, refresh, rollback, no plaintext registry keys.'
}
finally {
    if ([IO.Directory]::Exists($root)) {
        $resolved = [IO.Path]::GetFullPath($root)
        $parent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not $resolved.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'codex-universal-profile-test-*') { throw 'Unsafe test cleanup path.' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
