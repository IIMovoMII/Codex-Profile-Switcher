#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$catalogTestRoot=Join-Path ([IO.Path]::GetTempPath()) ('codex-catalog-test-'+[Guid]::NewGuid().ToString('N'))
$catalogTestSource=Split-Path -Parent $PSScriptRoot
$savedCatalogEnvironment=@{}
foreach($key in @('OPENAI_ORGANIZATION','OPENAI_PROJECT')){
    $savedCatalogEnvironment[$key]=[Environment]::GetEnvironmentVariable($key,'Process')
    [Environment]::SetEnvironmentVariable($key,$null,'Process')
}
function Assert-Catalog([bool]$Value,[string]$Message){if(-not $Value){throw $Message}}
function New-CatalogAuth([string]$Suffix){
    $claims=[ordered]@{
        email="catalog-$Suffix@example.invalid"
        'https://api.openai.com/auth'=[ordered]@{
            chatgpt_account_id="catalog-account-$Suffix";chatgpt_user_id="catalog-user-$Suffix";chatgpt_plan_type='plus'
        }
    }
    $payload=[Convert]::ToBase64String($script:Utf8NoBom.GetBytes((ConvertTo-Json -InputObject $claims -Compress))).TrimEnd('=').Replace('+','-').Replace('/','_')
    return ConvertTo-Json -InputObject @{auth_mode='chatgpt';tokens=@{id_token="test.$payload.signature";account_id="catalog-account-$Suffix";access_token="fixture-$Suffix";refresh_token="fixture-refresh-$Suffix"}} -Depth 10
}
function Write-CatalogCache([string]$Identity,$Models){
    Write-AtomicText $cachePath (ConvertTo-Json -InputObject ([ordered]@{
        fetched_at='2026-11-10T02:00:00Z';etag='private-cache-metadata';client_version='0.134.0'
        identity=$Identity;models=@($Models);unknown_outer_field='must-not-be-exported'
    }) -Depth 50)
}
function Assert-CatalogPreferences {
    $text=Read-TextFile $ConfigPath
    foreach($line in @('model = "my-model"','model_context_window = 123456','model_reasoning_effort = "high"','respect_system_proxy = true')){
        Assert-Catalog ($text.Contains($line)) ("Catalog processing changed preference: "+$line)
    }
    Assert-Catalog ((Get-FileHash -LiteralPath $chatSentinel).Hash -ceq $chatHash) 'Catalog processing changed a chat file.'
}
try{
    $fixture=& (Join-Path $PSScriptRoot 'test-gui-fixture.ps1') -Root $catalogTestRoot
    . (Join-Path $catalogTestSource 'codex-profile-switcher.ps1') -LibraryOnly -CodexHome $fixture.CodexHome -DataDir $fixture.DataDir -CodexExecutable $fixture.FakeCodex -MonitorDataDir (Join-Path $catalogTestRoot 'monitor') -UnsafeAllowRunningCodex
    # History behavior has its own integration suite. Exercise the real
    # auth/config/profile transactions and catalog I/O in this fixture.
    function Invoke-HistoryCompatibilityPreflight {}
    function Invoke-ProjectProjectionPreflight {}
    function Invoke-WebRequest { throw 'Catalog handling must not request the network.' }
    function Invoke-RestMethod { throw 'Catalog handling must not request the network.' }
    $authA=New-CatalogAuth 'a';$authB=New-CatalogAuth 'b'
    $officialA=(Save-OfficialProfile -AuthText $authA -Name '目录来源 A').Entry.id
    $officialB=(Save-OfficialProfile -AuthText $authB -Name '目录来源 B').Entry.id
    $registry=Read-ProfileRegistry
    $apiA=$registry.api_profiles[0].id;$apiB=$registry.api_profiles[1].id
    $customManual=Join-Path $catalogTestRoot '用户自定义目录.json'
    $manualText='{"models":[{"slug":"manually-edited-model","display_name":"用户维护","custom":{"keep":true}}]}'
    Write-AtomicText $customManual $manualText
    Write-AtomicText $RelayModelCatalogPath '{"models":[{"slug":"default-manual-model","custom":"keep-default"}]}'
    $defaultManualHash=(Get-FileHash -LiteralPath $RelayModelCatalogPath).Hash
    Set-ProfileDetails api $apiA @{model_catalog_json=$customManual}
    $personalConfig=@((Read-TextFile $ConfigPath),'model_context_window = 123456','model_reasoning_effort = "high"','[features]','respect_system_proxy = true') -join [Environment]::NewLine
    Write-AtomicText $ConfigPath $personalConfig
    $chatSentinel=Join-Path $CodexHome 'sessions\unchanged.jsonl'
    Write-AtomicText $chatSentinel '{"type":"catalog-test-sentinel","content":"keep this chat verbatim"}'
    $chatHash=(Get-FileHash -LiteralPath $chatSentinel).Hash
    $cachePath=Join-Path $CodexHome 'models_cache.json'
    Write-AtomicText $cachePath '{"unrelated":"native-cache-must-not-be-written"}'
    $initialCacheHash=(Get-FileHash -LiteralPath $cachePath).Hash
    Switch-ToOfficial -SkipHistoryCheck -ProfileName $officialA
    Assert-Catalog ((Read-TextFile $ConfigPath) -notmatch '(?m)^\s*model_catalog_json\s*=') 'Official mode retained a catalog override.'
    Assert-Catalog ((Get-FileHash -LiteralPath $cachePath).Hash -ceq $initialCacheHash) 'Official switching rewrote the native cache.'

    # Native models-cache-v1 reference vectors, independently calculated from
    # upstream models_identity.rs (OpenAI route, Plus, version 0.134.0).
    # Do not derive cache fixtures by calling the production identity builder.
    $identityA='90d869ea2800bc1437c2ac6697f48f6bd1b32e3d16bd2ae2e93a329a4e3c56ab'
    $identityB='3fbe2b6b3d18ad1d267eec026caeb70b1991ceb0ed354cef9516044d3125a70a'
    Assert-Catalog ($identityA -in @(Get-CodexOfficialModelCacheIdentity $authA '0.134.0')) 'Native cache identity does not match the reference vector.'
    $modelsA=@(
        [ordered]@{slug='future-model-a';display_name='未来模型 A';context_window=999999;supported_reasoning_levels=@(@{effort='low';description='低'},@{effort='high';description='高'});input_modalities=@('text','image');capabilities=@{tools=$true;unknown=@('x','y')};future_field=@{empty=@();nullable=$null;number=1.25}},
        [ordered]@{slug='future-model-b';display_name='未来模型 B';context_window=262144;future_boolean=$false}
    )
    Write-CatalogCache $identityA $modelsA
    $sourceCacheHash=(Get-FileHash -LiteralPath $cachePath).Hash
    Switch-ToApi -ProfileName $apiA
    $snapshotA=Get-OfficialModelCatalogPath $officialA;$snapshotB=Get-OfficialModelCatalogPath $officialB
    $snapshot=Read-DesktopJson (Read-TextFile $snapshotA)
    Assert-Catalog ($snapshot.Count -eq 1 -and $snapshot.Contains('models')) 'A catalog exported outer cache metadata.'
    Assert-Catalog ((ConvertTo-Json -InputObject (ConvertTo-DesktopCanonicalValue $snapshot.models) -Depth 50 -Compress) -ceq
        (ConvertTo-Json -InputObject (ConvertTo-DesktopCanonicalValue $modelsA) -Depth 50 -Compress)) 'Snapshot lost full or unknown model fields.'
    Assert-Catalog ((Get-FileHash -LiteralPath $cachePath).Hash -ceq $sourceCacheHash) 'Synchronization changed the native cache.'
    Assert-Catalog ((Read-TextFile $customManual) -ceq $manualText -and (Get-FileHash -LiteralPath $RelayModelCatalogPath).Hash -ceq $defaultManualHash) 'Automatic synchronization overwrote a manual catalog.'
    Assert-Catalog ((Get-TopLevelTomlValue (Read-TextFile $ConfigPath) 'model_catalog_json') -ceq $customManual) 'A legacy manual path was replaced.'
    Assert-CatalogPreferences

    Set-ProfileDetails api $apiA @{model_catalog_mode='official';model_catalog_source_official_id=$officialA}
    Set-ProfileDetails api $apiB @{model_catalog_mode='official';model_catalog_source_official_id=$officialB}
    Switch-ToApi -ProfileName $apiA
    Assert-Catalog ((Find-ProfileEntry (Read-ProfileRegistry) api $apiA).model_catalog_json -ceq $customManual) 'Follow mode discarded the saved manual path.'
    Assert-Catalog ((Get-TopLevelTomlValue (Read-TextFile $ConfigPath) 'model_catalog_json') -ceq $snapshotA) 'API A did not use its selected official snapshot.'
    $oldAHash=(Get-FileHash -LiteralPath $snapshotA).Hash
    Switch-ToOfficial -SkipHistoryCheck -ProfileName $officialB
    # Cache A deliberately remains while auth B is active.
    Switch-ToApi -ProfileName $apiB
    Assert-Catalog (-not [IO.File]::Exists($snapshotB) -and (Get-FileHash -LiteralPath $snapshotA).Hash -ceq $oldAHash) 'A stale cache was assigned to another official account.'
    Assert-Catalog ((Read-TextFile $ConfigPath) -notmatch '(?m)^\s*model_catalog_json\s*=') 'An unavailable source fell back to another account or manual catalog.'
    Switch-ToOfficial -SkipHistoryCheck -ProfileName $officialB
    Write-CatalogCache $identityB @([ordered]@{slug='only-b';display_name='仅来源 B';context_window=64000;future=@{b=$true}})
    Switch-ToApi -ProfileName $apiB
    Assert-Catalog ((Get-TopLevelTomlValue (Read-TextFile $ConfigPath) 'model_catalog_json') -ceq $snapshotB -and
        (Read-DesktopJson (Read-TextFile $snapshotB)).models[0].slug -ceq 'only-b' -and
        (Get-FileHash -LiteralPath $snapshotA).Hash -ceq $oldAHash) 'API accounts mixed their official catalog sources.'
    $view=Get-SwitcherViewState;$shown=@($view.Profiles|Where-Object Id -eq $apiB)[0]
    Assert-Catalog ($shown.CatalogEffectivePath -ceq $snapshotB -and $shown.CatalogSourceName -ceq '目录来源 B' -and $shown.CatalogUpdatedUtc) 'The view did not expose the real source/path/time.'

    # Fewer models is a valid update; no fixed model-name requirement.
    Switch-ToOfficial -SkipHistoryCheck -ProfileName $officialA
    Write-CatalogCache $identityA @($modelsA[0])
    Switch-ToApi -ProfileName $apiA
    Assert-Catalog ((Read-DesktopJson (Read-TextFile $snapshotA)).models.Count -eq 1) 'A valid smaller catalog was rejected.'
    # Initialization may have prepared history already; it is still a normal
    # switch, and must not accidentally inherit the quick catalog skip.
    Switch-ToOfficial -SkipHistoryCheck -ProfileName $officialA
    Write-CatalogCache $identityA @([ordered]@{slug='first-normal';display_name='首次普通切换也同步'})
    [IO.File]::Delete($StatePath)
    Invoke-AutoSwitch -TargetModeOverride api -ProfileName $apiA
    Assert-Catalog ((Read-DesktopJson (Read-TextFile $snapshotA)).models[0].slug -ceq 'first-normal') 'History preparation during initialization suppressed a normal catalog sync.'
    $oldAHash=(Get-FileHash -LiteralPath $snapshotA).Hash
    foreach($invalid in @('{broken','{"models":[]}','{"models":{}}','{"models":[{}]}',
        '{"client_version":"0.134.0","identity":"unknown","models":[{"slug":"x"}]}')){
        Switch-ToOfficial -SkipHistoryCheck -ProfileName $officialA
        Write-AtomicText $cachePath $invalid
        Switch-ToApi -ProfileName $apiA
        Assert-Catalog ((Get-FileHash -LiteralPath $snapshotA).Hash -ceq $oldAHash -and (Read-TextFile $cachePath) -ceq $invalid) 'Invalid cache cleared the old snapshot or changed the native file.'
        Assert-Catalog ((Get-AuthInfoFromText (Read-AuthText)).Kind -eq 'api') 'Invalid cache broke switching.'
    }
    Switch-ToOfficial -SkipHistoryCheck -ProfileName $officialA
    [IO.File]::Delete($cachePath)
    Switch-ToApi -ProfileName $apiA
    Assert-Catalog ((Get-FileHash -LiteralPath $snapshotA).Hash -ceq $oldAHash -and -not [IO.File]::Exists($cachePath)) 'Missing cache changed the snapshot or created a native cache.'

    Switch-ToOfficial -SkipHistoryCheck -ProfileName $officialA
    Write-CatalogCache $identityA @([ordered]@{slug='quick-must-not-sync';display_name='仅供快速跳过测试'})
    Switch-ToApi -SkipHistoryCheck -ProfileName $apiA
    Assert-Catalog ((Get-FileHash -LiteralPath $snapshotA).Hash -ceq $oldAHash) 'Quick switching processed the cache.'
    Switch-ToOfficial -SkipHistoryCheck -ProfileName $officialA
    Write-CatalogCache $identityA @([ordered]@{slug='outgoing-a';display_name='离开官方 A 时同步'})
    Switch-ToOfficial -ProfileName $officialB
    Assert-Catalog ((Read-DesktopJson (Read-TextFile $snapshotA)).models[0].slug -ceq 'outgoing-a' -and
        (Read-DesktopJson (Read-TextFile $snapshotB)).models[0].slug -ceq 'only-b') 'Official-to-official switching mixed outgoing cache ownership.'

    Switch-ToOfficial -SkipHistoryCheck -ProfileName $officialA
    $oldAHash=(Get-FileHash -LiteralPath $snapshotA).Hash
    Write-CatalogCache $identityA @([ordered]@{slug='failed-write';display_name='失败不得替换旧目录'})
    [IO.File]::SetAttributes($script:ProfileRegistryPath,[IO.FileAttributes]::ReadOnly)
    try{$failed=Sync-OfficialModelCatalogSnapshot -AuthText (Read-AuthText) -ProfileId $officialA}
    finally{[IO.File]::SetAttributes($script:ProfileRegistryPath,[IO.FileAttributes]::Normal)}
    Assert-Catalog (-not $failed.Succeeded -and (Get-FileHash -LiteralPath $snapshotA).Hash -ceq $oldAHash -and
        -not [IO.File]::Exists($script:ProfileTransactionPath)) 'A failed atomic transaction did not preserve the previous catalog.'
    Write-AtomicText $ConfigPath (Set-TopLevelTomlString (Read-TextFile $ConfigPath) 'model_catalog_json' $customManual)
    $blocked=Sync-OfficialModelCatalogSnapshot -AuthText (Read-AuthText) -ProfileId $officialA
    Assert-Catalog (-not $blocked.Succeeded -and (Get-FileHash -LiteralPath $snapshotA).Hash -ceq $oldAHash) 'A non-native official catalog configuration was accepted as a source.'
    Switch-ToOfficial -SkipHistoryCheck -ProfileName $officialA
    Set-ProfileDetails api $apiA @{model_catalog_mode='manual'}
    Switch-ToApi -ProfileName $apiA
    Assert-Catalog ((Read-TextFile $customManual) -ceq $manualText -and
        (Get-TopLevelTomlValue (Read-TextFile $ConfigPath) 'model_catalog_json') -ceq $customManual) 'Returning to manual mode lost user edits or its previous path.'
    Assert-CatalogPreferences

    # Manual-only API use needs neither a registered official account nor login.
    $manualHome=Join-Path $catalogTestRoot 'manual-only-home';$manualStore=Join-Path $catalogTestRoot 'manual-only-store'
    . (Join-Path $catalogTestSource 'codex-profile-switcher.ps1') -LibraryOnly -CodexHome $manualHome -DataDir $manualStore -CodexExecutable $fixture.FakeCodex -MonitorDataDir (Join-Path $catalogTestRoot 'monitor') -UnsafeAllowRunningCodex
    Write-AtomicText $ConfigPath 'openai_base_url = "https://manual.example.com/v1"'
    Write-AtomicText $AuthPath '{"OPENAI_API_KEY":"manual-only-fixture"}'
    $manualApi=(Save-ApiProfile -AuthText (Read-AuthText) -BaseUrl 'https://manual.example.com/v1' -Name '纯手动' -SetActive).Entry.id
    Write-State ([ordered]@{version=1;codex_home=$CodexHome;relay_base_url='https://manual.example.com/v1';created_utc=[DateTime]::UtcNow.ToString('o');updated_utc=[DateTime]::UtcNow.ToString('o')})
    $legacyManual=Join-Path $catalogTestRoot 'legacy-live-manual.json'
    Write-AtomicText $legacyManual $manualText
    $legacyRegistry=Read-ProfileRegistry
    $legacyEntry=Find-ProfileEntry $legacyRegistry api $manualApi
    $legacyEntry.Remove('model_catalog_mode');$legacyEntry.Remove('model_catalog_source_official_id')
    Write-ProfileRegistry $legacyRegistry
    Write-AtomicText $ConfigPath (Set-TopLevelTomlString (Read-TextFile $ConfigPath) 'model_catalog_json' $legacyManual)
    Switch-ToApi -ProfileName $manualApi
    Assert-Catalog ((Find-ProfileEntry (Read-ProfileRegistry) api $manualApi).model_catalog_json -ceq $legacyManual -and
        (Get-TopLevelTomlValue (Read-TextFile $ConfigPath) 'model_catalog_json') -ceq $legacyManual -and
        (Read-TextFile $legacyManual) -ceq $manualText) 'Legacy profile capture lost the live manual path or user edits.'
    Set-ProfileDetails api $manualApi @{model_catalog_json=''}
    Switch-ToApi -ProfileName $manualApi
    Assert-Catalog ((Read-ProfileRegistry).official_profiles.Count -eq 0 -and
        (Read-TextFile $ConfigPath) -notmatch '(?m)^\s*model_catalog_json\s*=') 'Manual-only switching required an official account or inserted a missing catalog.'
    Write-AtomicText $RelayModelCatalogPath $manualText
    Switch-ToApi -ProfileName $manualApi
    Assert-Catalog ((Get-TopLevelTomlValue (Read-TextFile $ConfigPath) 'model_catalog_json') -ceq $RelayModelCatalogPath -and
        (Read-TextFile $RelayModelCatalogPath) -ceq $manualText) 'Manual-only default relay-models.json was not retained.'
    $missingManual=Join-Path $catalogTestRoot '尚未导入的完整目录.json'
    Set-ProfileDetails api $manualApi @{model_catalog_json=$missingManual}
    Switch-ToApi -ProfileName $manualApi
    Assert-Catalog ((Find-ProfileEntry (Read-ProfileRegistry) api $manualApi).model_catalog_json -ceq $missingManual -and
        -not [IO.File]::Exists($missingManual)) 'A missing manual path was rejected or automatically overwritten.'
    Write-Output 'Model catalog tests passed: native official behavior, complete fields, manual preservation, per-account sources, missing/corrupt/empty cache, smaller catalogs, quick skip, atomic rollback, manual-only mode and preference/chat preservation.'
}finally{
    foreach($key in $savedCatalogEnvironment.Keys){[Environment]::SetEnvironmentVariable($key,$savedCatalogEnvironment[$key],'Process')}
    $resolved=[IO.Path]::GetFullPath($catalogTestRoot)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'codex-catalog-test-*'){throw 'Unsafe catalog test cleanup path.'}
    if([IO.Directory]::Exists($resolved)){Get-ChildItem -LiteralPath $resolved -Recurse -File | ForEach-Object {[IO.File]::SetAttributes($_.FullName,[IO.FileAttributes]::Normal)};Remove-Item -LiteralPath $resolved -Recurse -Force}
}
