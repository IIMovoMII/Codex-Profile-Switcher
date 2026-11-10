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
            auth_file = "$id.auth.dpapi"
            created_utc = [DateTime]::UtcNow.ToString('o')
            updated_utc = [DateTime]::UtcNow.ToString('o')
        }
        $registry.api_profiles = @($items + $entry)
    }
    else {
        if (-not [string]::IsNullOrWhiteSpace($Name)) { $entry['name'] = $Name.Trim() }
        $entry['base_url'] = $BaseUrl
        if ($null -ne $ModelCatalogPath) { $entry['model_catalog_json'] = $ModelCatalogPath }
    }
    [IO.Directory]::CreateDirectory($script:ProfileAuthDirectory) | Out-Null
    $authPath = Get-ProfileAuthPath api ([string](Get-ProfileField $entry 'auth_file'))
    if ($SetActive) { Set-ActiveProfileEntry $registry api ([string](Get-ProfileField $entry 'id')) }
    Commit-ProfileFiles @((New-EncryptedAuthFile $authPath $AuthText api),(New-ProfileRegistryFile $registry))
    return [pscustomobject]@{ Registry = $registry; Entry = $entry }
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
