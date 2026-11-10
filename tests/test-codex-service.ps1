#requires -Version 5.1
[CmdletBinding()]
param()
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot

$ErrorActionPreference='Stop'
$serviceTestRoot=Join-Path ([IO.Path]::GetTempPath()) ('codex-service-test-'+[Guid]::NewGuid().ToString('N'))
$serviceTestSource=$script:ProjectRoot
function Assert-Service([bool]$Value,[string]$Message){if(-not $Value){throw $Message}}
function Assert-ServiceThrows([scriptblock]$Operation,[string]$Message){$thrown=$false;try{& $Operation}catch{$thrown=$true;$script:LastExpectedFailure=$_.Exception.Message};Assert-Service $thrown $Message}
try{
    $fixture=& (Join-Path $PSScriptRoot 'test-gui-fixture.ps1') -Root $serviceTestRoot
    . (Join-Path $serviceTestSource 'codex-profile-switcher.ps1') -LibraryOnly -CodexHome $fixture.CodexHome -DataDir $fixture.DataDir -CodexExecutable $fixture.FakeCodex -UnsafeAllowRunningCodex
    $sourceConfig=@'
# keep my config
model = "my-own-model" # chosen model
model_context_window = 123456
cli_auth_credentials_store = "file"
[features]
respect_system_proxy = true # chosen proxy
[desktop]
localeOverride = "zh-CN"
'@
    Assert-SupportedConfig $sourceConfig
    $apiText=New-ModeConfigText -CurrentText $sourceConfig -Mode api -RelayBaseUrl 'https://example.com/v1'
    $officialText=New-ModeConfigText -CurrentText $apiText -Mode official
    Assert-Service ($apiText.Contains('model_context_window = 123456') -and $officialText.Contains('model = "my-own-model" # chosen model') -and $officialText.Contains('respect_system_proxy = true # chosen proxy') -and $officialText.Contains('localeOverride = "zh-CN"')) 'Default switching changed a user model, context, proxy, comments or locale.'
    $empty=New-ModeConfigText -CurrentText '' -Mode official
    Assert-Service ($empty -notmatch 'model_context_window|respect_system_proxy|272000') 'Minimal configuration gained a personal default.'
    Assert-ServiceThrows {Assert-ContextWindow '-3'} 'An invalid context was accepted.'
    Assert-ServiceThrows {Assert-SupportedConfig 'model_provider = "custom"'} 'A custom provider was silently rewritten.'
    # Old defaults remain visible without rewriting any files. Saving the
    # merged editor pins those effective values to just that account.
    $legacyRegistryHash=(Get-FileHash -LiteralPath $script:ProfileRegistryPath).Hash
    Write-AtomicText $script:SettingsPath '{"version":1,"official_proxy":"system","api_proxy":"direct","context_window":"8192"}'
    $legacyView=Get-SwitcherViewState
    $legacyApi=@($legacyView.Profiles|Where-Object Name -eq '备用接口')[0]
    $legacyOfficial=@($legacyView.Profiles|Where-Object Kind -eq 'official')[0]
    Assert-Service ($legacyApi.ProxyPolicy -ceq 'direct' -and $legacyOfficial.ProxyPolicy -ceq 'system' -and $legacyApi.ContextWindow -ceq '8192' -and
        (Get-FileHash -LiteralPath $script:ProfileRegistryPath).Hash -ceq $legacyRegistryHash) 'The merged view lost old defaults or rewrote profiles while reading.'
    Set-ProfileDetails api $legacyApi.Id @{settings_scope='account';proxy_policy=$legacyApi.ProxyPolicy;context_window=$legacyApi.ContextWindow}
    Write-AtomicText $script:SettingsPath '{"version":1,"official_proxy":"system","api_proxy":"system","context_window":"16384"}'
    $pinnedView=Get-SwitcherViewState
    $pinnedApi=@($pinnedView.Profiles|Where-Object Id -eq $legacyApi.Id)[0]
    $otherApi=@($pinnedView.Profiles|Where-Object Name -eq '工作 API')[0]
    Assert-Service ($pinnedApi.ProxyPolicy -ceq 'direct' -and $pinnedApi.ContextWindow -ceq '8192' -and
        $otherApi.ProxyPolicy -ceq 'system' -and $otherApi.ContextWindow -ceq '16384') 'Saving an account changed other profiles or left it bound to old global defaults.'
    Set-ProfileDetails api $legacyApi.Id @{settings_scope='account';proxy_policy='preserve';context_window=''}
    $pinnedEntry=Find-ProfileEntry (Read-ProfileRegistry) api $legacyApi.Id
    $preserved=New-ModeConfigText -CurrentText $sourceConfig -Mode api -RelayBaseUrl 'https://example.com/v1' -ProfileEntry $pinnedEntry
    Assert-Service ($preserved.Contains('model_context_window = 123456') -and $preserved.Contains('respect_system_proxy = true')) 'Blank account settings fell back to invisible legacy defaults.'
    Assert-ServiceThrows {Set-ProfileDetails api $legacyApi.Id @{settings_scope='unknown'}} 'An unknown settings scope was accepted.'
    [IO.File]::Delete($script:SettingsPath)
    $view=Get-SwitcherViewState
    $inactive=@($view.Profiles|Where-Object Name -eq '备用接口')[0]
    $entry=Find-ProfileEntry (Read-ProfileRegistry) api $inactive.Id
    $savedPath=Get-ProfileAuthPath api $entry.auth_file
    $originalAuth=(Get-FileHash -LiteralPath $savedPath).Hash
    $originalRegistry=(Get-FileHash -LiteralPath $script:ProfileRegistryPath).Hash
    [IO.File]::SetAttributes($script:ProfileRegistryPath,[IO.FileAttributes]::ReadOnly)
    try{
        Assert-ServiceThrows {Set-ProfileDetails api $inactive.Id @{name='failed edit';api_key='failed-rotation-key'}} 'A deliberately blocked registry write succeeded.'
    }finally{[IO.File]::SetAttributes($script:ProfileRegistryPath,[IO.FileAttributes]::Normal)}
    Assert-Service ((Get-FileHash -LiteralPath $savedPath).Hash -ceq $originalAuth -and (Get-FileHash -LiteralPath $script:ProfileRegistryPath).Hash -ceq $originalRegistry -and -not [IO.File]::Exists($script:ProfileTransactionPath)) 'A partially failed credential edit did not restore original bytes.'
    # Removing the most recently selected inactive profile updates both pointers
    # and removes the legacy slot, so migration cannot recreate it.
    $registry=Read-ProfileRegistry;$registry.active_api_profile_id=$inactive.Id;Write-ProfileRegistry $registry
    $state=Read-State;$state.active_api_profile_id=$inactive.Id;Write-State $state
    Protect-AuthSnapshot -Text (Unprotect-AuthSnapshot $savedPath api) -Path $RelayAuthPath -ExpectedKind api
    Remove-ProfileEntry api $inactive.Id
    Assert-Service (@((Ensure-ProfileRegistry (Read-State)).api_profiles).Count -eq 1 -and (Read-State).active_api_profile_id -cne $inactive.Id -and -not [IO.File]::Exists($savedPath) -and -not [IO.File]::Exists($RelayAuthPath)) 'A removed profile was resurrected or kept a stale state pointer.'
    Assert-ServiceThrows {Remove-ProfileEntry api (Get-LiveProfileId)} 'The live profile could be removed.'
    # Reauthorization checks identity, and refreshing the currently active
    # official profile must not put its old tokens back into auth.json.
    $official=@((Read-ProfileRegistry).official_profiles)[0]
    $officialFile=Get-ProfileAuthPath official $official.auth_file
    $officialAuth=Read-DesktopJson (Unprotect-AuthSnapshot $officialFile official)
    $loginInput=Join-Path $serviceTestRoot 'login-result.json'
    $loginCli=Join-Path $serviceTestRoot 'login-cli.ps1'
    Write-AtomicText $loginCli @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
$auth=Join-Path $env:CODEX_HOME 'auth.json'
if($Arguments.Count -gt 1 -and $Arguments[1] -eq 'status'){$a=Get-Content -Raw -LiteralPath $auth|ConvertFrom-Json;if($a.PSObject.Properties['tokens']){'Logged in using ChatGPT'}else{'Logged in using an API key'};exit 0}
if($Arguments.Count -eq 1 -and $Arguments[0] -eq 'login'){[IO.File]::WriteAllBytes($auth,[IO.File]::ReadAllBytes($env:CODEX_TEST_LOGIN_FILE));exit 0}
exit 3
'@
    $CodexExecutable=$loginCli
    $previousLoginEnv=$env:CODEX_TEST_LOGIN_FILE;$env:CODEX_TEST_LOGIN_FILE=$loginInput
    try{
        $beforeConfig=(Get-FileHash -LiteralPath $ConfigPath).Hash;$beforeAuth=(Get-FileHash -LiteralPath $AuthPath).Hash
        Write-AtomicText $loginInput '{"auth_mode":"chatgpt","tokens":{"id_token":"other-token","access_token":"other","refresh_token":"other","account_id":"wrong-account"}}'
        Assert-ServiceThrows {Invoke-ReauthorizeProfile $official.id} 'Reauthorization accepted the wrong account.'
        Assert-Service ($script:LastExpectedFailure -match '登录的不是') ('Reauthorization failed for a different reason: '+$script:LastExpectedFailure)
        Assert-Service ((Get-FileHash -LiteralPath $ConfigPath).Hash -ceq $beforeConfig -and (Get-FileHash -LiteralPath $AuthPath).Hash -ceq $beforeAuth) ('A wrong-account login changed live configuration or credentials: '+$script:LastExpectedFailure)
        $officialAuth.tokens.access_token='new-access-one'
        Write-AtomicText $loginInput (ConvertTo-Json -InputObject $officialAuth -Depth 12)
        Invoke-ReauthorizeProfile $official.id
        Assert-Service ((Get-FileHash -LiteralPath $AuthPath).Hash -ceq $beforeAuth) 'Refreshing an inactive official account changed the live API.'
        Invoke-AutoSwitch -TargetModeOverride official -ProfileName $official.id
        $officialAuth.tokens.access_token='new-access-two'
        Write-AtomicText $loginInput (ConvertTo-Json -InputObject $officialAuth -Depth 12)
        Invoke-ReauthorizeProfile $official.id
        Assert-Service ((Read-DesktopJson (Read-AuthText)).tokens.access_token -ceq 'new-access-two') 'Active official reauthorization restored its stale token.'
    }finally{$env:CODEX_TEST_LOGIN_FILE=$previousLoginEnv}
    # Simulate interruption after first-use profile and state writes. Recovery
    # must remove all newly created credential files and restore absent config/auth.
    $freshHome=Join-Path $serviceTestRoot 'fresh';$freshStore=Join-Path $serviceTestRoot 'fresh-store'
    . (Join-Path $serviceTestSource 'codex-profile-switcher.ps1') -LibraryOnly -CodexHome $freshHome -DataDir $freshStore -CodexExecutable $fixture.FakeCodex -UnsafeAllowRunningCodex
    $target=New-ModeConfigText '' api 'https://fresh.example.com/v1'
    $newAuth='{"OPENAI_API_KEY":"interrupted-setup-key"}'
    Write-TransactionJournal -SourceMode uninitialized -TargetMode api -TargetConfigText $target -TargetAuthText $newAuth
    Write-AtomicText $ConfigPath $target;Write-AtomicText $AuthPath $newAuth
    $newProfile=Save-ApiProfile -AuthText $newAuth -BaseUrl 'https://fresh.example.com/v1' -Name 'interrupted setup' -SetActive
    $initialState=[ordered]@{version=1;codex_home=$CodexHome;relay_base_url='https://fresh.example.com/v1';created_utc=[DateTime]::UtcNow.ToString('o');updated_utc=[DateTime]::UtcNow.ToString('o')}
    Save-InitialSetupState $initialState $newAuth api
    Restore-Transaction
    Assert-Service (-not [IO.File]::Exists($ConfigPath) -and -not [IO.File]::Exists($AuthPath) -and -not [IO.File]::Exists($StatePath) -and -not [IO.File]::Exists($script:ProfileRegistryPath) -and -not [IO.File]::Exists($RelayAuthPath) -and @(Get-ChildItem -LiteralPath $script:ProfileAuthDirectory -File).Count -eq 0) 'Interrupted first-use setup was not fully rolled back.'
    Write-Output 'Service tests passed: config preservation/validation, partial credential-edit rollback, removal/migration, wrong-account rejection, inactive/active reauthorization, interrupted first-use recovery.'
}finally{
    $resolved=[IO.Path]::GetFullPath($serviceTestRoot)
    $parent=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'codex-service-test-*'){throw 'Unsafe service test cleanup path.'}
    if([IO.Directory]::Exists($resolved)){Get-ChildItem -LiteralPath $resolved -Recurse -File|ForEach-Object {[IO.File]::SetAttributes($_.FullName,[IO.FileAttributes]::Normal)};Remove-Item -LiteralPath $resolved -Recurse -Force}
}
