#requires -Version 5.1
param([string]$Root)
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot

$ErrorActionPreference='Stop'
if(-not $Root){$Root=Join-Path $script:ProjectRoot 'test-results\gui-preview'}
$fixtureCodex=Join-Path $Root 'codex'
$fixtureStore=Join-Path $Root 'store'
[void][IO.Directory]::CreateDirectory($fixtureCodex);[void][IO.Directory]::CreateDirectory($fixtureStore)
. (Join-Path $script:ProjectRoot 'codex-profile-switcher.ps1') -LibraryOnly -CodexHome $fixtureCodex -DataDir $fixtureStore
Write-AtomicText $ConfigPath "model_provider = `"openai`"`nopenai_base_url = `"https://api.example.com/v1`"`ncli_auth_credentials_store = `"file`"`nmodel = `"my-model`"`n"
Write-AtomicText $AuthPath '{"OPENAI_API_KEY":"preview-only-not-a-real-key"}'
$api=Save-ApiProfile -AuthText (Read-AuthText) -BaseUrl 'https://api.example.com/v1' -Name '工作 API' -SetActive
[void](Save-ApiProfile -AuthText '{"OPENAI_API_KEY":"preview-backup-not-a-real-key"}' -BaseUrl 'https://backup.example.com/v1' -Name '备用接口')
$claims=@{'https://api.openai.com/auth'=@{chatgpt_user_id='test-user';chatgpt_account_id='test-account'};email='test@example.invalid'}
$payload=[Convert]::ToBase64String($script:Utf8NoBom.GetBytes((ConvertTo-Json -InputObject $claims -Compress))).TrimEnd('=').Replace('+','-').Replace('/','_')
$official=ConvertTo-Json -InputObject @{auth_mode='chatgpt';tokens=@{id_token="test.$payload.signature";access_token='preview-access';refresh_token='preview-refresh';account_id='preview-account'}} -Depth 10
[void](Save-OfficialProfile -AuthText $official -Name '个人 ChatGPT' -SetActive)
Write-State ([ordered]@{version=1;codex_home=$CodexHome;relay_base_url='https://api.example.com/v1';active_api_profile_id=$api.Entry.id;active_official_profile_id='';created_utc=[DateTime]::UtcNow.ToString('o');updated_utc=[DateTime]::UtcNow.ToString('o')})
Write-AtomicText (Join-Path $CodexHome '.codex-global-state.json') (ConvertTo-Json -InputObject @{'local-projects'=@{one=@{id='one';name='个人项目';rootPaths=@('D:\Example')};two=@{id='two';name='工作项目';rootPaths=@('D:\Work')};three=@{id='three';name='练习';rootPaths=@('D:\Learning')}}} -Depth 10)
$fake=Join-Path $Root 'fake-codex.ps1'
Write-AtomicText $fake @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Arguments)
if($Arguments.Count -ge 2 -and $Arguments[1] -eq 'status'){
 $auth=Get-Content -Raw -LiteralPath (Join-Path $env:CODEX_HOME 'auth.json') | ConvertFrom-Json
 if($null -ne $auth.PSObject.Properties['tokens']){'Logged in using ChatGPT'}else{'Logged in using an API key'}
 exit 0
}
exit 4
'@
[pscustomobject]@{CodexHome=$CodexHome;DataDir=$DataDir;FakeCodex=$fake}
