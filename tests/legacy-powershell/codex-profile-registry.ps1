#requires -Version 5.1
# Dot-sourced by codex-profile-switcher.ps1. This file contains only profile
# metadata and encrypted credential-file orchestration; it never stores a key
# in the registry JSON.

$script:ProfileRegistryVersion = 1
$script:ProfileRegistryPath = Join-Path $DataDir 'profiles.json'
$script:ProfileAuthDirectory = Join-Path $DataDir 'profiles'

function Get-ProfileField {
    param([AllowNull()]$Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return ,$Object[$Name] }
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return ,$property.Value
}

function New-ProfileRegistry {
    $now = [DateTime]::UtcNow.ToString('o')
    return [ordered]@{
        version = $script:ProfileRegistryVersion
        codex_home = $CodexHome
        created_utc = $now
        updated_utc = $now
        active_api_profile_id = ''
        active_official_profile_id = ''
        api_profiles = @()
        official_profiles = @()
    }
}

function Assert-ProfileId {
    param([Parameter(Mandatory = $true)][string]$Id)
    if ($Id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$') {
        throw "配置档案 ID 不合法。"
    }
}

function Assert-ProfileRegistry {
    param([Parameter(Mandatory = $true)]$Registry)
    $version = [int](Get-ProfileField $Registry 'version')
    if ($version -ne $script:ProfileRegistryVersion) { throw "不支持的配置档案版本：$version" }
    $storedHome = [string](Get-ProfileField $Registry 'codex_home')
    if ((Resolve-NormalizedPath $storedHome) -cne $CodexHome) {
        throw "配置档案属于另一个 CODEX_HOME：$storedHome"
    }
    foreach ($name in @('api_profiles', 'official_profiles')) {
        $items = Get-ProfileField $Registry $name
        if ($items -isnot [System.Collections.IList]) { throw "配置档案字段 $name 不是数组。" }
    }
    $apiItems = Get-ProfileField $Registry 'api_profiles'
    foreach ($item in $apiItems) {
        $id = [string](Get-ProfileField $item 'id')
        Assert-ProfileId $id
        if ([string]::IsNullOrWhiteSpace([string](Get-ProfileField $item 'name')) -or
            [string]::IsNullOrWhiteSpace([string](Get-ProfileField $item 'base_url')) -or
            [string]::IsNullOrWhiteSpace([string](Get-ProfileField $item 'auth_file'))) {
            throw "中转配置档案缺少名称、地址或认证文件。"
        }
        Assert-RelayBaseUrl ([string](Get-ProfileField $item 'base_url'))
        $catalogMode = [string](Get-ProfileField $item 'model_catalog_mode')
        if ($catalogMode -and $catalogMode -notin @('manual','official')) { throw 'API 档案的模型目录维护方式无效。' }
        $catalogSource = [string](Get-ProfileField $item 'model_catalog_source_official_id')
        if ($catalogSource -and $catalogSource -notmatch '^official-[a-f0-9]{64}$') { throw 'API 档案的官方模型目录来源无效。' }
        if ($catalogMode -eq 'official' -and -not $catalogSource) { throw '跟随官方目录时必须指定官方账号来源。' }
    }
    $officialItems = Get-ProfileField $Registry 'official_profiles'
    foreach ($item in $officialItems) {
        $id = [string](Get-ProfileField $item 'id')
        Assert-ProfileId $id
        if ([string]::IsNullOrWhiteSpace([string](Get-ProfileField $item 'name')) -or
            [string]::IsNullOrWhiteSpace([string](Get-ProfileField $item 'owner')) -or
            [string](Get-ProfileField $item 'owner') -notmatch '^[a-f0-9]{64}$' -or
            [string]::IsNullOrWhiteSpace([string](Get-ProfileField $item 'auth_file'))) {
            throw "官方账号档案缺少名称、账号标识或认证文件。"
        }
        $snapshotIdentity = [string](Get-ProfileField $item 'model_catalog_snapshot_identity')
        if ($snapshotIdentity -and $snapshotIdentity -notmatch '^[a-f0-9]{64}$') { throw '官方模型目录快照来源标识无效。' }
        $snapshotHash = [string](Get-ProfileField $item 'model_catalog_snapshot_sha256')
        if ($snapshotHash -and $snapshotHash -notmatch '^[a-f0-9]{64}$') { throw '官方模型目录快照校验值无效。' }
    }
}

function Read-ProfileRegistry {
    if (-not [IO.File]::Exists($script:ProfileRegistryPath)) {
        return New-ProfileRegistry
    }
    try {
        $parsed = Read-DesktopJson (Read-TextFile $script:ProfileRegistryPath)
        Assert-ProfileRegistry $parsed
        return $parsed
    }
    catch {
        throw "配置档案注册表损坏，未进行切换：$($_.Exception.Message)"
    }
}

function Write-ProfileRegistry {
    param([Parameter(Mandatory = $true)]$Registry)
    Assert-ProfileRegistry $Registry
    $Registry['updated_utc'] = [DateTime]::UtcNow.ToString('o')
    $json = ConvertTo-Json -InputObject $Registry -Depth 20
    Write-AtomicText -Path $script:ProfileRegistryPath -Text ($json + [Environment]::NewLine)
}

function Get-ProfileAuthPath {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('api', 'official')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$AuthFile
    )
    if ($AuthFile -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,120}\.auth\.dpapi$') {
        throw "配置档案认证文件名不合法。"
    }
    return Join-Path $script:ProfileAuthDirectory $AuthFile
}

function Get-ProfileCollectionName {
    param([Parameter(Mandatory = $true)][ValidateSet('api', 'official')][string]$Kind)
    if ($Kind -eq 'api') { return 'api_profiles' }
    return 'official_profiles'
}

function Find-ProfileEntry {
    param(
        [Parameter(Mandatory = $true)]$Registry,
        [Parameter(Mandatory = $true)][ValidateSet('api', 'official')][string]$Kind,
        [AllowNull()][string]$Selector
    )
    $items = @($Registry[(Get-ProfileCollectionName $Kind)])
    if (-not [string]::IsNullOrWhiteSpace($Selector)) {
        $matches = @($items | Where-Object {
            ([string](Get-ProfileField $_ 'id') -ceq $Selector) -or
            ([string](Get-ProfileField $_ 'name') -ceq $Selector)
        })
        if ($matches.Count -eq 0) { throw "找不到 $Kind 配置档案：$Selector" }
        if ($matches.Count -gt 1) { throw "配置档案名称重复，请改用 ID：$Selector" }
        return $matches[0]
    }
    $activeKey = if ($Kind -eq 'api') { 'active_api_profile_id' } else { 'active_official_profile_id' }
    $activeId = [string](Get-ProfileField $Registry $activeKey)
    if (-not [string]::IsNullOrWhiteSpace($activeId)) {
        $active = @($items | Where-Object { [string](Get-ProfileField $_ 'id') -ceq $activeId })
        if ($active.Count -eq 1) { return $active[0] }
        throw "注册表的活动 $Kind 配置档案不存在：$activeId"
    }
    if ($items.Count -eq 1) { return $items[0] }
    if ($items.Count -eq 0) { throw "尚未登记 $Kind 配置档案。" }
    throw "已登记多个 $Kind 配置档案，请明确指定 -Profile。"
}

function Set-ActiveProfileEntry {
    param(
        [Parameter(Mandatory = $true)]$Registry,
        [Parameter(Mandatory = $true)][ValidateSet('api', 'official')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$ProfileId
    )
    Assert-ProfileId $ProfileId
    $key = if ($Kind -eq 'api') { 'active_api_profile_id' } else { 'active_official_profile_id' }
    $Registry[$key] = $ProfileId
}

function Get-AuthFingerprint {
    param([Parameter(Mandatory = $true)][string]$Text)
    return Get-Sha256Hex $script:Utf8NoBom.GetBytes($Text)
}

function Get-ApiCredentialFingerprint {
    param([Parameter(Mandatory = $true)][string]$AuthText)
    $auth = Read-DesktopJson $AuthText
    return Get-AuthFingerprint ([string](Get-ProfileField $auth 'OPENAI_API_KEY'))
}

function Get-ApiProfileFingerprint {
    param([string]$AuthText,[string]$BaseUrl)
    return Get-AuthFingerprint (ConvertTo-Json -InputObject @($BaseUrl,(Get-ApiCredentialFingerprint $AuthText)) -Compress)
}

function Get-OfficialProfileIdFromAuth {
    param([Parameter(Mandatory = $true)][string]$AuthText)
    $owner = Get-DesktopAuthOwner $AuthText
    # Older CLI builds can expose opaque tokens. Prefer their stable account
    # ID so refreshing a credential does not create a second profile.
    if ([string]::IsNullOrWhiteSpace($owner)) {
        $auth = Read-DesktopJson $AuthText
        $accountId = [string](Get-ProfileField (Get-ProfileField $auth 'tokens') 'account_id')
        if (-not [string]::IsNullOrWhiteSpace($accountId)) { $owner = Get-AuthFingerprint ('opaque-account:' + $accountId) }
        else { $owner = Get-AuthFingerprint $AuthText }
    }
    return "official-$owner"
}

function Get-OfficialModelCatalogPath {
    param([Parameter(Mandatory = $true)][string]$ProfileId)
    if ($ProfileId -notmatch '^official-[a-f0-9]{64}$') { throw '官方模型目录档案 ID 无效。' }
    return Join-Path (Join-Path $DataDir 'model-catalogs') ($ProfileId + '.json')
}

function Get-ApiModelCatalogPath {
    param($Entry)
    $mode = [string](Get-ProfileField $Entry 'model_catalog_mode')
    if (-not $mode) { $mode = 'manual' }
    if ($mode -eq 'official') {
        $sourceId = [string](Get-ProfileField $Entry 'model_catalog_source_official_id')
        if ($sourceId -match '^official-[a-f0-9]{64}$') { return Get-OfficialModelCatalogPath $sourceId }
        return ''
    }
    $path = [string](Get-ProfileField $Entry 'model_catalog_json')
    if ([string]::IsNullOrWhiteSpace($path)) { return $RelayModelCatalogPath }
    try { return Resolve-NormalizedPath $path } catch { return $path }
}

function ConvertTo-RustDebugString {
    param([Parameter(Mandatory = $true)][string]$Value)
    $escaped = New-Object Text.StringBuilder
    foreach ($character in $Value.ToCharArray()) {
        switch ([int]$character) {
            0 { [void]$escaped.Append('\0'); continue }
            9 { [void]$escaped.Append('\t'); continue }
            10 { [void]$escaped.Append('\n'); continue }
            13 { [void]$escaped.Append('\r'); continue }
            34 { [void]$escaped.Append('\"'); continue }
            92 { [void]$escaped.Append('\\'); continue }
            default {
                if ([char]::IsControl($character)) { [void]$escaped.Append(('\u{{{0:x}}}' -f [int]$character)) }
                else { [void]$escaped.Append($character) }
            }
        }
    }
    return '"' + $escaped.ToString() + '"'
}

function Get-CodexOfficialModelCacheIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$AuthText,
        [Parameter(Mandatory = $true)][string]$ClientVersion,
        [AllowNull()][string]$Organization,
        [AllowNull()][string]$Project
    )
    # Local-only verification of the native models-cache-v1 digest:
    # https://github.com/openai/codex/blob/main/codex-rs/model-provider/src/models_identity.rs
    # An unfamiliar provider/auth layout simply leaves the old snapshot intact.
    $auth = Read-DesktopJson $AuthText
    if ([string](Get-ProfileField $auth 'auth_mode') -cne 'chatgpt') { return @() }
    $tokens = Get-ProfileField $auth 'tokens'
    $idToken = [string](Get-ProfileField $tokens 'id_token')
    $parts = $idToken.Split('.')
    if ($parts.Length -ne 3) { return @() }
    try {
        $payload = $parts[1].Replace('-','+').Replace('_','/')
        $payload = $payload.PadRight([int]([Math]::Ceiling($payload.Length / 4.0) * 4), '=')
        $claims = Read-DesktopJson ($script:Utf8NoBom.GetString([Convert]::FromBase64String($payload)))
    }
    catch { return @() }

    $namespace = Get-ProfileField $claims 'https://api.openai.com/auth'
    if ($null -eq $namespace) { return @() }
    $accountId = [string](Get-ProfileField $tokens 'account_id')
    $userId = [string](Get-ProfileField $namespace 'chatgpt_user_id')
    if (-not $userId) { $userId = [string](Get-ProfileField $namespace 'user_id') }
    $email = [string](Get-ProfileField $claims 'email')
    if (-not $email) { $email = [string](Get-ProfileField (Get-ProfileField $claims 'https://api.openai.com/profile') 'email') }
    # Only stable account metadata is supported. Other native auth modes or
    # provider layouts fail closed rather than guessing a cache owner.
    if (-not $accountId -or (-not $userId -and -not $email) -or -not $ClientVersion) { return @() }

    $planRaw = [string](Get-ProfileField $namespace 'chatgpt_plan_type')
    $planVariants = @{
        free='Free'; go='Go'; plus='Plus'; pro='Pro'; prolite='ProLite'; promax='ProMax'; team='Team'
        self_serve_business_prolite='SelfServeBusinessProLite'; self_serve_business_usage_based='SelfServeBusinessUsageBased'
        business='Business'; ent26='Ent26'; enterprise_cbp_automation='EnterpriseCbpAutomation'
        enterprise_cbp_usage_based='EnterpriseCbpUsageBased'; enterprise='Enterprise'; hc='Enterprise'
        education='Edu'; edu='Edu'; edu_plus='EduPlus'; edu_pro='EduPro'; sci='Sci'; sci_plus='SciPlus'
    }
    $planVariant = if ($planRaw) { [string]$planVariants[$planRaw.ToLowerInvariant()] } else { '' }
    $canonicalPlan = if (-not $planRaw) { '' } elseif ($planVariant) {
        switch ($planRaw.ToLowerInvariant()) {
            {$_ -in @('hc')} { 'enterprise'; break }
            {$_ -in @('education')} { 'edu'; break }
            default { $planRaw.ToLowerInvariant() }
        }
    } else { $planRaw }
    $accountPlan = if ($planVariant) { 'Some(' + $planVariant + ')' } else { 'Some(Unknown)' }
    $rawPlan = if ($planRaw) { 'Some(' + (ConvertTo-RustDebugString $canonicalPlan) + ')' } else { 'None' }
    $fedramp = [bool](Get-ProfileField $namespace 'chatgpt_account_is_fedramp')

    $identities = New-Object Collections.Generic.List[string]
    foreach ($residency in @('', 'us')) {
        $stream = New-Object IO.MemoryStream
        try {
            $fields = New-Object Collections.Generic.List[byte[]]
            $fields.Add($script:Utf8NoBom.GetBytes('models-cache-v1'))
            $fields.Add($script:Utf8NoBom.GetBytes('OpenAI'))
            $fields.Add($script:Utf8NoBom.GetBytes('https://chatgpt.com/backend-api/codex'))
            $fields.Add([BitConverter]::GetBytes([UInt64]0))
            $fields.Add([byte[]]@(1))
            $fields.Add([byte[]]@(0))
            $fields.Add($script:Utf8NoBom.GetBytes('Some(Chatgpt)'))
            $fields.Add($script:Utf8NoBom.GetBytes('Some(' + (ConvertTo-RustDebugString $accountId) + ')'))
            $fields.Add($script:Utf8NoBom.GetBytes($(if($userId){'Some(' + (ConvertTo-RustDebugString $userId) + ')'}else{'None'})))
            $fields.Add($script:Utf8NoBom.GetBytes($(if($email){'Some(' + (ConvertTo-RustDebugString $email) + ')'}else{'None'})))
            $fields.Add($script:Utf8NoBom.GetBytes($accountPlan))
            $fields.Add($script:Utf8NoBom.GetBytes($rawPlan))
            $fields.Add([byte[]]@([byte]$(if($fedramp){1}else{0})))

            $headers = New-Object Collections.Generic.List[object]
            $headers.Add([pscustomobject]@{Name='version';Value=$ClientVersion})
            if ($Organization) { $headers.Add([pscustomobject]@{Name='openai-organization';Value=$Organization}) }
            if ($Project) { $headers.Add([pscustomobject]@{Name='openai-project';Value=$Project}) }
            if ($residency) { $headers.Add([pscustomobject]@{Name='x-openai-internal-codex-residency';Value=$residency}) }
            $orderedHeaders = @($headers | Sort-Object -Property Name)
            $fields.Add([BitConverter]::GetBytes([UInt64]$orderedHeaders.Count))
            foreach ($header in $orderedHeaders) {
                $fields.Add($script:Utf8NoBom.GetBytes([string]$header.Name))
                $fields.Add($script:Utf8NoBom.GetBytes([string]$header.Value))
            }

            foreach ($field in $fields) {
                $length = [BitConverter]::GetBytes([UInt64]$field.Length)
                $stream.Write($length,0,$length.Length)
                $stream.Write($field,0,$field.Length)
            }
            $identities.Add((Get-Sha256Hex $stream.ToArray()))
        }
        finally { $stream.Dispose() }
    }
    return $identities.ToArray()
}

function Test-CodexOfficialModelCacheSource {
    param([string]$AuthText,$Cache)
    $cachedIdentity = [string](Get-ProfileField $Cache 'identity')
    $version = [string](Get-ProfileField $Cache 'client_version')
    if ($cachedIdentity -notmatch '^[a-f0-9]{64}$' -or -not $version) { return $false }
    $identities = @(Get-CodexOfficialModelCacheIdentity -AuthText $AuthText -ClientVersion $version `
        -Organization ([Environment]::GetEnvironmentVariable('OPENAI_ORGANIZATION','Process')) `
        -Project ([Environment]::GetEnvironmentVariable('OPENAI_PROJECT','Process')))
    return $cachedIdentity -in $identities
}

function Get-NewApiProfileId {
    return 'api-' + ([Guid]::NewGuid().ToString('N'))
}

function Get-DefaultProfileName {
    param([ValidateSet('api', 'official')][string]$Kind, [int]$Index)
    if ($Kind -eq 'api') {
        if ($Index -eq 1) { return '默认中转 API' }
        return "中转 API $Index"
    }
    if ($Index -eq 1) { return '默认 ChatGPT 账号' }
    return "ChatGPT 账号 $Index"
}

function Save-ApiProfile {
    param(
        [Parameter(Mandatory = $true)][string]$AuthText,
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [AllowNull()][string]$ModelCatalogPath,
        [AllowNull()][string]$Name,
        [switch]$SetActive
    )
    if ((Get-AuthInfoFromText $AuthText).Kind -ne 'api') { throw '要保存的认证不是 API key。' }
    Assert-RelayBaseUrl $BaseUrl
    $registry = Read-ProfileRegistry
    $items = @($registry.api_profiles)
    $existing = @($items | Where-Object {
        [string](Get-ProfileField $_ 'base_url') -ceq $BaseUrl -and
        (Test-Path -LiteralPath (Get-ProfileAuthPath api ([string](Get-ProfileField $_ 'auth_file')))) -and
        (Get-ApiCredentialFingerprint (Unprotect-AuthSnapshot -Path (Get-ProfileAuthPath api ([string](Get-ProfileField $_ 'auth_file'))) -ExpectedKind api)) -ceq (Get-ApiCredentialFingerprint $AuthText)
    })
    $entry = if ($existing.Count -eq 1) { $existing[0] } else { $null }
    if ($null -eq $entry) {
        $index = $items.Count + 1
        $id = Get-NewApiProfileId
        $entry = [ordered]@{
            id = $id
            name = if ([string]::IsNullOrWhiteSpace($Name)) { Get-DefaultProfileName api $index } else { $Name.Trim() }
            base_url = $BaseUrl
            model_catalog_json = if ($null -eq $ModelCatalogPath) { '' } else { $ModelCatalogPath }
            model_catalog_mode = 'manual'
            model_catalog_source_official_id = ''
            auth_file = "$id.auth.dpapi"
            created_utc = [DateTime]::UtcNow.ToString('o')
            updated_utc = [DateTime]::UtcNow.ToString('o')
        }
        $registry.api_profiles = @($items + $entry)
    }
    else {
        if (-not [string]::IsNullOrWhiteSpace($Name)) { $entry['name'] = $Name.Trim() }
        $entry['base_url'] = $BaseUrl
        # A credential refresh must not replace the selected manual path or
        # official snapshot source with the config path currently in use.
        if (-not [string](Get-ProfileField $entry 'model_catalog_mode')) {
            # Legacy profiles have no catalog policy yet. Capture their live
            # manual reference once before subsequent account switches.
            if (-not [string]::IsNullOrWhiteSpace($ModelCatalogPath)) { $entry['model_catalog_json'] = $ModelCatalogPath }
            $entry['model_catalog_mode'] = 'manual'
        }
    }
    [IO.Directory]::CreateDirectory($script:ProfileAuthDirectory) | Out-Null
    $authPath = Get-ProfileAuthPath api ([string](Get-ProfileField $entry 'auth_file'))
    if ($SetActive) { Set-ActiveProfileEntry $registry api ([string](Get-ProfileField $entry 'id')) }
    Commit-ProfileFiles @((New-EncryptedAuthFile $authPath $AuthText api),(New-ProfileRegistryFile $registry))
    return [pscustomobject]@{ Registry = $registry; Entry = $entry }
}

function Sync-OfficialModelCatalogSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$AuthText,
        [Parameter(Mandatory = $true)][string]$ProfileId
    )
    $snapshotPath = ''
    try {
        if ((Get-OfficialProfileIdFromAuth $AuthText) -cne $ProfileId) { throw '当前官方身份与目标档案不一致。' }
        $currentConfig = Read-TextFile $ConfigPath
        if ((Get-LiveMode -ConfigText $currentConfig -AuthText $AuthText) -ne 'official' -or
            -not [string]::IsNullOrWhiteSpace([string](Get-TopLevelTomlValue -Text $currentConfig -Key 'openai_base_url')) -or
            -not [string]::IsNullOrWhiteSpace([string](Get-TopLevelTomlValue -Text $currentConfig -Key 'model_catalog_json'))) {
            throw '当前不是原生官方模型目录配置。'
        }
        $snapshotPath = Get-OfficialModelCatalogPath $ProfileId
        $cachePath = Join-Path $CodexHome 'models_cache.json'
        if (-not [IO.File]::Exists($cachePath)) { throw '未找到本地官方模型缓存。' }
        $cache = Read-DesktopJson (Read-TextFile $cachePath)
        $models = Get-ProfileField $cache 'models'
        if ($models -isnot [System.Collections.IList] -or $models.Count -eq 0) { throw '缓存中的 models 不是非空数组。' }
        foreach ($model in $models) {
            if ($model -isnot [System.Collections.IDictionary] -or
                [string]::IsNullOrWhiteSpace([string](Get-ProfileField $model 'slug'))) { throw '缓存中的模型条目格式无效。' }
        }
        if (-not (Test-CodexOfficialModelCacheSource -AuthText $AuthText -Cache $cache)) {
            throw '缓存来源无法与当前官方账号对应。'
        }

        $registry = Read-ProfileRegistry
        $profile = Find-ProfileEntry $registry official $ProfileId
        $snapshotText = (ConvertTo-Json -InputObject ([ordered]@{models=@($models)}) -Depth 100) + [Environment]::NewLine
        $snapshotBytes = $script:Utf8NoBom.GetBytes($snapshotText)
        $profile['model_catalog_snapshot_updated_utc'] = [DateTime]::UtcNow.ToString('o')
        $profile['model_catalog_snapshot_client_version'] = [string](Get-ProfileField $cache 'client_version')
        $profile['model_catalog_snapshot_identity'] = [string](Get-ProfileField $cache 'identity')
        $profile['model_catalog_snapshot_sha256'] = Get-Sha256Hex $snapshotBytes
        Commit-ProfileFiles @(
            [pscustomobject]@{Path=$snapshotPath;TargetBytes=$snapshotBytes},
            (New-ProfileRegistryFile $registry)
        )
        return [pscustomobject]@{Succeeded=$true;Message=('已同步官方账号模型目录（' + @($models).Count + ' 项）。');Path=$snapshotPath}
    }
    catch {
        $reason = [string]$_.Exception.Message
        if ($reason -match 'models_cache|JSON|输入字符串|分析') { $reason = '本地缓存格式无效' }
        elseif ($reason -match '缓存来源|身份|目标档案') { $reason = '无法确认本地缓存属于当前官方账号' }
        elseif ($reason -match 'models 不是|条目格式') { $reason = '本地缓存中的模型目录格式无效' }
        elseif ($reason -match '当前不是') { $reason = '当前不是原生官方配置' }
        elseif ($reason -match '未找到') { $reason = '本地尚无官方模型缓存' }
        else { $reason = '读取或保存快照失败' }
        if (-not $snapshotPath) { try { $snapshotPath = Get-OfficialModelCatalogPath $ProfileId } catch {} }
        return [pscustomobject]@{Succeeded=$false;Message=('模型目录未更新（' + $reason + '），保留已有快照。');Path=$snapshotPath}
    }
}

function Save-OfficialProfile {
    param(
        [Parameter(Mandatory = $true)][string]$AuthText,
        [AllowNull()][string]$Name,
        [switch]$SetActive
    )
    if ((Get-AuthInfoFromText $AuthText).Kind -ne 'official') { throw '要保存的认证不是官方 OAuth。' }
    $registry = Read-ProfileRegistry
    $id = Get-OfficialProfileIdFromAuth $AuthText
    $items = @($registry.official_profiles)
    $existing = @($items | Where-Object { [string](Get-ProfileField $_ 'id') -ceq $id })
    $entry = if ($existing.Count -eq 1) { $existing[0] } else { $null }
    if ($null -eq $entry) {
        $index = $items.Count + 1
        $owner = $id.Substring(9)
        $authFile = "official-$($owner.Substring(0, 24)).auth.dpapi"
        if (@($items | Where-Object { [string](Get-ProfileField $_ 'auth_file') -ceq $authFile }).Count -gt 0) {
            $authFile = "official-$([Guid]::NewGuid().ToString('N')).auth.dpapi"
        }
        $entry = [ordered]@{
            id = $id
            name = if ([string]::IsNullOrWhiteSpace($Name)) { Get-DefaultProfileName official $index } else { $Name.Trim() }
            owner = $owner
            auth_file = $authFile
            created_utc = [DateTime]::UtcNow.ToString('o')
            updated_utc = [DateTime]::UtcNow.ToString('o')
        }
        $registry.official_profiles = @($items + $entry)
    }
    else {
        if (-not [string]::IsNullOrWhiteSpace($Name)) { $entry['name'] = $Name.Trim() }
    }
    [IO.Directory]::CreateDirectory($script:ProfileAuthDirectory) | Out-Null
    $authPath = Get-ProfileAuthPath official ([string](Get-ProfileField $entry 'auth_file'))
    if ($SetActive) { Set-ActiveProfileEntry $registry official $id }
    Commit-ProfileFiles @((New-EncryptedAuthFile $authPath $AuthText official),(New-ProfileRegistryFile $registry))
    return [pscustomobject]@{ Registry = $registry; Entry = $entry }
}

function Ensure-ProfileRegistry {
    param([AllowNull()]$State)
    $registry = Read-ProfileRegistry
    # Legacy slots describe only the last captured credential, not a profile.
    # Import each kind once; later switches must never pair an old key with
    # the new active URL or overwrite a user's selected profile.
    if (@($registry.api_profiles).Count -eq 0 -and [IO.File]::Exists($RelayAuthPath)) {
        try {
            $legacyApi = Unprotect-AuthSnapshot -Path $RelayAuthPath -ExpectedKind api
            if ($null -eq $State) { $State = Read-State }
            $baseUrl = if ($null -ne $State) { [string]$State['relay_base_url'] } else { '' }
            if ([string]::IsNullOrWhiteSpace($baseUrl) -and [IO.File]::Exists($ConfigPath)) {
                $baseUrl = [string](Get-TopLevelTomlValue -Text (Read-TextFile $ConfigPath) -Key 'openai_base_url')
            }
            if (-not [string]::IsNullOrWhiteSpace($baseUrl)) {
                $catalogPath = ''
                if ([IO.File]::Exists($ConfigPath)) {
                    $configText = Read-TextFile $ConfigPath
                    if ([string](Get-TopLevelTomlValue -Text $configText -Key 'openai_base_url') -ceq $baseUrl) {
                        $catalogPath = [string](Get-TopLevelTomlValue -Text $configText -Key 'model_catalog_json')
                    }
                }
                $saved = Save-ApiProfile -AuthText $legacyApi -BaseUrl $baseUrl -ModelCatalogPath $catalogPath -SetActive
                $registry = $saved.Registry
            }
        } catch { throw "迁移旧中转认证快照失败：$($_.Exception.Message)" }
    }
    if (@($registry.official_profiles).Count -eq 0 -and [IO.File]::Exists($OfficialAuthPath)) {
        try {
            $legacyOfficial = Unprotect-AuthSnapshot -Path $OfficialAuthPath -ExpectedKind official
            $saved = Save-OfficialProfile -AuthText $legacyOfficial -SetActive
            $registry = $saved.Registry
        } catch { throw "迁移旧官方认证快照失败：$($_.Exception.ToString())" }
    }
    return $registry
}

function Sync-CurrentAuthProfile {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('api', 'official')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$AuthText,
        [AllowNull()][string]$BaseUrl,
        [AllowNull()][string]$ModelCatalogPath
    )
    $registry = Ensure-ProfileRegistry $null
    if ($Kind -eq 'api') {
        if ([string]::IsNullOrWhiteSpace($BaseUrl)) { throw '当前 API 模式没有可保存的中转地址。' }
        foreach ($entry in @($registry.api_profiles)) {
            if ([string](Get-ProfileField $entry 'pending_from') -ceq (Get-ApiProfileFingerprint $AuthText $BaseUrl)) {
                Set-ActiveProfileEntry $registry api ([string]$entry.id)
                Write-ProfileRegistry $registry
                return [pscustomobject]@{Registry=$registry;Entry=$entry}
            }
        }
        return Save-ApiProfile -AuthText $AuthText -BaseUrl $BaseUrl -ModelCatalogPath $ModelCatalogPath -SetActive
    }
    return Save-OfficialProfile -AuthText $AuthText -SetActive
}

function Read-SelectedProfileAuth {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('api', 'official')][string]$Kind,
        [AllowNull()][string]$Selector
    )
    $registry = Ensure-ProfileRegistry $null
    $entry = Find-ProfileEntry -Registry $registry -Kind $Kind -Selector $Selector
    $path = Get-ProfileAuthPath $Kind ([string](Get-ProfileField $entry 'auth_file'))
    $text = Unprotect-AuthSnapshot -Path $path -ExpectedKind $Kind
    return [pscustomobject]@{ Registry = $registry; Entry = $entry; AuthText = $text }
}

function New-ProfileSelectionPlan {
    param(
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory = $true)][ValidateSet('api', 'official')][string]$Kind,
        [Parameter(Mandatory = $true)][string]$ProfileId
    )
    $registry = Read-ProfileRegistry
    $entry = Find-ProfileEntry -Registry $registry -Kind $Kind -Selector $ProfileId
    if ($Kind -eq 'api' -and $entry.Contains('pending_from')) { [void]$entry.Remove('pending_from') }
    Set-ActiveProfileEntry -Registry $registry -Kind $Kind -ProfileId $ProfileId
    $registry['updated_utc'] = [DateTime]::UtcNow.ToString('o')
    $targetState = Copy-DesktopValue $State
    $activeKey = if ($Kind -eq 'api') { 'active_api_profile_id' } else { 'active_official_profile_id' }
    $targetState[$activeKey] = $ProfileId
    $targetState['updated_utc'] = $registry['updated_utc']
    if ($Kind -eq 'api') { $targetState['relay_base_url'] = [string](Get-ProfileField $entry 'base_url') }
    $registryBytes = $script:Utf8NoBom.GetBytes((ConvertTo-Json -InputObject $registry -Depth 20) + [Environment]::NewLine)
    $stateBytes = $script:Utf8NoBom.GetBytes((ConvertTo-Json -InputObject $targetState -Depth 5) + "`n")
    try { $protectedState = Protect-BytesForCurrentUser $stateBytes }
    finally { [Array]::Clear($stateBytes, 0, $stateBytes.Length) }
    return [pscustomobject]@{ Files = @(
        [pscustomobject]@{ Path = $script:ProfileRegistryPath; TargetBytes = $registryBytes }
        [pscustomobject]@{ Path = $StatePath; TargetBytes = $protectedState }
    ) }
}

function Show-ProfileRegistry {
    $registry = Ensure-ProfileRegistry $null
    Write-Host '配置档案（认证内容已加密，不显示密钥）：'
    foreach ($entry in @($registry.api_profiles)) {
        $active = if ([string](Get-ProfileField $registry 'active_api_profile_id') -ceq [string](Get-ProfileField $entry 'id')) { '*' } else { ' ' }
        Write-Host ("{0} API  {1}  {2}  {3}" -f $active, (Get-ProfileField $entry 'name'), (Get-ProfileField $entry 'base_url'), (Get-ProfileField $entry 'id'))
    }
    foreach ($entry in @($registry.official_profiles)) {
        $active = if ([string](Get-ProfileField $registry 'active_official_profile_id') -ceq [string](Get-ProfileField $entry 'id')) { '*' } else { ' ' }
        Write-Host ("{0} 官方  {1}  {2}" -f $active, (Get-ProfileField $entry 'name'), (Get-ProfileField $entry 'id'))
    }
}
