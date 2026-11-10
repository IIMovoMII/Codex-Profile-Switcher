#requires -Version 5.1
# Local application services. Dot-sourced by the CLI and the graphical shell.

$script:SettingsPath = Join-Path $DataDir 'settings.json'
$script:ProfileTransactionPath = Join-Path $DataDir 'profile-transaction.dpapi'

function Initialize-WindowsSqlite {
    if($null -ne (Get-Command sqlite3.exe -ErrorAction SilentlyContinue)){return}
    $tool=Join-Path $PSScriptRoot 'tools\sqlite3.ps1'
    if(-not [IO.File]::Exists((Join-Path $env:SystemRoot 'System32\winsqlite3.dll'))){throw '当前 Windows 没有 SQLite 支持，请安装 sqlite3 并加入 PATH。'}
    $ready=@(& $tool ':memory:' 'SELECT json_extract(''{"ready":1}'',''$.ready'');')
    if($LASTEXITCODE -ne 0 -or $ready.Count -ne 1 -or [string]$ready[0] -ne '1'){throw 'Windows 数据库工具不可用，请安装 sqlite3 并加入 PATH。'}
}

function Read-SwitcherSettings {
    $settings = [ordered]@{ version = 1; official_proxy = 'preserve'; api_proxy = 'preserve'; context_window = '' }
    if ([IO.File]::Exists($script:SettingsPath)) {
        $stored = Read-DesktopJson (Read-TextFile $script:SettingsPath)
        if ([int](Get-ProfileField $stored 'version') -ne 1) { throw '不支持的切换器设置版本。' }
        foreach ($key in @('official_proxy','api_proxy','context_window')) {
            if ($stored.Contains($key)) { $settings[$key] = [string]$stored[$key] }
        }
    }
    foreach ($key in @('official_proxy','api_proxy')) {
        if ($settings[$key] -notin @('preserve','system','direct')) { throw '代理策略必须是 preserve、system 或 direct。' }
    }
    Assert-ContextWindow $settings.context_window
    return $settings
}

function Assert-ContextWindow {
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return }
    [long]$number = 0
    if (-not [long]::TryParse($Value, [ref]$number) -or $number -le 0 -or $number -gt [int]::MaxValue) {
        throw '上下文窗口应为正整数，留空则保留现有配置。'
    }
}

function Get-SwitcherModePolicy {
    param([ValidateSet('api','official')][string]$Mode, [AllowNull()]$Entry)
    # Older profiles still inherit their saved defaults. The merged editor
    # displays those effective values, then pins them to the account on save.
    # A blank context in an account-scoped form must mean preserve, rather
    # than silently falling back to an invisible legacy default.
    $scope = [string](Get-ProfileField $Entry 'settings_scope')
    if ($scope -notin @('','account')) { throw '不支持的账号设置范围。' }
    $settings = if ($scope -eq 'account') {
        [ordered]@{official_proxy='preserve';api_proxy='preserve';context_window=''}
    } else { Read-SwitcherSettings }
    $proxy = [string]$settings[$Mode + '_proxy']
    $context = [string]$settings.context_window
    $model = ''
    if ($null -ne $Entry) {
        $entryProxy = [string](Get-ProfileField $Entry 'proxy_policy')
        if (-not [string]::IsNullOrWhiteSpace($entryProxy) -and $entryProxy -ne 'inherit') { $proxy = $entryProxy }
        $entryContext = [string](Get-ProfileField $Entry 'context_window')
        if (-not [string]::IsNullOrWhiteSpace($entryContext)) { $context = $entryContext }
        $model = [string](Get-ProfileField $Entry 'model')
    }
    if ($proxy -notin @('preserve','system','direct')) { throw '账号配置中的代理策略无效。' }
    Assert-ContextWindow $context
    return [pscustomobject]@{ Proxy = $proxy; ContextWindow = $context; Model = $model }
}

function Set-TopLevelTomlString {
    param([AllowEmptyString()][string]$Text, [string]$Key, [string]$Value)
    $literal = ConvertTo-Json -InputObject $Value -Compress
    $lines = New-Object Collections.Generic.List[string]
    $top = $true; $seen = $false; $section = -1
    foreach ($line in [regex]::Split($Text, '\r?\n')) {
        if ($top -and $line -match '^\s*\[') { $top = $false; $section = $lines.Count }
        if ($top -and $line -match ('^\s*' + [regex]::Escape($Key) + '\s*=')) {
            if ($seen) { throw "配置中存在重复字段：$Key" }
            $seen = $true
            $lines.Add("$Key = $literal" + (Get-SimpleAssignmentComment $line))
        } else { $lines.Add($line) }
    }
    if (-not $seen) {
        if ($section -lt 0) { $section = $lines.Count }
        $lines.Insert($section, "$Key = $literal")
    }
    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    return [string]::Join($newline, $lines)
}

function Test-ProfileTransactionPath {
    param([string]$Path)
    $normalized = Resolve-NormalizedPath $Path
    if ($normalized -in @($script:ProfileRegistryPath,$StatePath,$RelayAuthPath,$OfficialAuthPath,$script:SettingsPath)) { return $true }
    return (Split-Path -Parent $normalized) -ieq $script:ProfileAuthDirectory -and
        ([IO.Path]::GetFileName($normalized) -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,120}\.auth\.dpapi$')
}

function Restore-ProfileTransaction {
    if (-not [IO.File]::Exists($script:ProfileTransactionPath)) { return }
    $plain = Unprotect-BytesForCurrentUser ([IO.File]::ReadAllBytes($script:ProfileTransactionPath))
    try { $journal = Read-DesktopJson ($script:Utf8NoBom.GetString($plain)) }
    finally { [Array]::Clear($plain,0,$plain.Length) }
    if ($journal.version -ne 1 -or $journal.codex_home -ine $CodexHome -or $journal.files -isnot [Collections.IList]) { throw '账号维护恢复记录无效。' }
    foreach ($entry in $journal.files) {
        if (-not (Test-ProfileTransactionPath $entry.path)) { throw '账号维护恢复记录包含未知路径。' }
        $original = [Convert]::FromBase64String([string]$entry.original)
        if ((Get-Sha256Hex $original) -cne $entry.original_hash) { throw '账号维护恢复记录校验失败。' }
        if ([IO.File]::Exists($entry.path)) {
            $hash = Get-Sha256Hex ([IO.File]::ReadAllBytes($entry.path))
            if ($hash -cne $entry.original_hash -and $hash -cne $entry.target_hash) { throw '账号维护文件出现外部变化，拒绝覆盖。' }
        } elseif ($entry.existed -and -not $entry.delete) { throw '账号维护文件意外缺失，拒绝覆盖。' }
    }
    foreach ($entry in $journal.files) {
        if ($entry.existed) {
            $original = [Convert]::FromBase64String([string]$entry.original)
            if (-not [IO.File]::Exists($entry.path) -or (Get-Sha256Hex ([IO.File]::ReadAllBytes($entry.path))) -cne $entry.original_hash) {
                Write-AtomicBytes -Path $entry.path -Bytes $original
            }
        } elseif ([IO.File]::Exists($entry.path)) { [IO.File]::Delete($entry.path) }
    }
    [IO.File]::Delete($script:ProfileTransactionPath)
}

function Commit-ProfileFiles {
    param([Parameter(Mandatory = $true)][object[]]$Files)
    if ([IO.File]::Exists($script:ProfileTransactionPath)) { throw '存在未恢复的账号维护事务。' }
    Add-InitialSetupRollbackFiles $Files
    $records = @()
    foreach ($file in $Files) {
        if (-not (Test-ProfileTransactionPath $file.Path)) { throw '账号维护写入路径不在允许范围。' }
        [byte[]]$original = [byte[]]::new(0)
        $existed = [IO.File]::Exists($file.Path)
        if ($existed) { $original = [IO.File]::ReadAllBytes($file.Path) }
        $delete = $null -ne $file.PSObject.Properties['Delete'] -and [bool]$file.Delete
        $records += [ordered]@{path=$file.Path;existed=$existed;original=[Convert]::ToBase64String($original);original_hash=(Get-Sha256Hex $original);delete=$delete;target_hash=$(if($delete){''}else{Get-Sha256Hex $file.TargetBytes})}
    }
    $bytes = $script:Utf8NoBom.GetBytes((ConvertTo-Json -InputObject ([ordered]@{version=1;codex_home=$CodexHome;files=$records}) -Depth 10 -Compress))
    try { $encrypted = Protect-BytesForCurrentUser $bytes }
    finally { [Array]::Clear($bytes,0,$bytes.Length) }
    Write-AtomicBytes -Path $script:ProfileTransactionPath -Bytes $encrypted
    try {
        foreach ($file in $Files) {
            if ($null -ne $file.PSObject.Properties['Delete'] -and $file.Delete) {
                if ([IO.File]::Exists($file.Path)) { [IO.File]::Delete($file.Path) }
            } else {
                Write-AtomicBytes -Path $file.Path -Bytes $file.TargetBytes
                if ((Get-Sha256Hex ([IO.File]::ReadAllBytes($file.Path))) -cne (Get-Sha256Hex $file.TargetBytes)) { throw '账号维护写后校验失败。' }
            }
        }
        [IO.File]::Delete($script:ProfileTransactionPath)
    } catch {
        $failure = $_
        Restore-ProfileTransaction
        throw "账号维护失败，已恢复原档案。$failure"
    }
}

function Add-InitialSetupRollbackFiles {
    param([object[]]$Files)
    if(-not [IO.File]::Exists($TransactionPath)){return}
    $plain=Unprotect-BytesForCurrentUser ([IO.File]::ReadAllBytes($TransactionPath))
    try{$record=Read-DesktopJson ($script:Utf8NoBom.GetString($plain))}finally{[Array]::Clear($plain,0,$plain.Length)}
    if($record.source_mode -ne 'uninitialized'){return}
    $extras=@($record.extra_files)
    foreach($file in $Files){
        if(-not (Test-ProfileTransactionPath $file.Path) -or $file.PSObject.Properties['Delete']){throw '首次设置出现未知的维护文件。'}
        $existing=@($extras | Where-Object path -eq $file.Path)
        if($existing.Count){$existing[0]['target_sha256']=Get-Sha256Hex $file.TargetBytes;continue}
        $exists=[IO.File]::Exists($file.Path)
        [byte[]]$original=[byte[]]::new(0)
        if($exists){$original=[IO.File]::ReadAllBytes($file.Path)}
        $extras += [ordered]@{path=$file.Path;existed=$exists;base64=[Convert]::ToBase64String($original);sha256=(Get-Sha256Hex $original);target_sha256=(Get-Sha256Hex $file.TargetBytes)}
    }
    $record['extra_files']=$extras
    $bytes=$script:Utf8NoBom.GetBytes((ConvertTo-Json -InputObject $record -Depth 10 -Compress))
    try{$encrypted=Protect-BytesForCurrentUser $bytes}finally{[Array]::Clear($bytes,0,$bytes.Length)}
    Write-AtomicBytes $TransactionPath $encrypted
}

function Save-InitialSetupState {
    param($State,[string]$AuthText,[ValidateSet('api','official')][string]$Kind)
    $legacy=if($Kind -eq 'api'){$RelayAuthPath}else{$OfficialAuthPath}
    $bytes=$script:Utf8NoBom.GetBytes((ConvertTo-Json -InputObject $State -Depth 10))
    try{$encrypted=Protect-BytesForCurrentUser $bytes}finally{[Array]::Clear($bytes,0,$bytes.Length)}
    Commit-ProfileFiles @((New-EncryptedAuthFile $legacy $AuthText $Kind),[pscustomobject]@{Path=$StatePath;TargetBytes=$encrypted})
}

function New-ProfileRegistryFile {
    param($Registry)
    Assert-ProfileRegistry $Registry
    $Registry['updated_utc'] = [DateTime]::UtcNow.ToString('o')
    return [pscustomobject]@{Path=$script:ProfileRegistryPath;TargetBytes=$script:Utf8NoBom.GetBytes((ConvertTo-Json -InputObject $Registry -Depth 20) + [Environment]::NewLine)}
}

function New-EncryptedAuthFile {
    param([string]$Path,[string]$AuthText,[ValidateSet('api','official')][string]$Kind)
    if ((Get-AuthInfoFromText $AuthText).Kind -ne $Kind) { throw '认证类型与档案不匹配。' }
    $bytes = $script:Utf8NoBom.GetBytes($AuthText)
    try { $encrypted = Protect-BytesForCurrentUser $bytes }
    finally { [Array]::Clear($bytes,0,$bytes.Length) }
    return [pscustomobject]@{Path=$Path;TargetBytes=$encrypted}
}

function Get-LiveProfileId {
    if (-not [IO.File]::Exists($ConfigPath) -or -not [IO.File]::Exists($AuthPath)) { return '' }
    $auth = Read-AuthText; $kind = (Get-AuthInfoFromText $auth).Kind
    if ($kind -eq 'official') { return Get-OfficialProfileIdFromAuth $auth }
    if ($kind -eq 'api') {
        $base = [string](Get-TopLevelTomlValue -Text (Read-TextFile $ConfigPath) -Key 'openai_base_url')
        foreach ($entry in @((Read-ProfileRegistry).api_profiles)) {
            $path = Get-ProfileAuthPath api $entry.auth_file
            if ([string](Get-ProfileField $entry 'pending_from') -ceq (Get-ApiProfileFingerprint $auth $base)) { return [string]$entry.id }
            if ($entry.base_url -ceq $base -and [IO.File]::Exists($path) -and
                (Get-ApiCredentialFingerprint (Unprotect-AuthSnapshot -Path $path -ExpectedKind api)) -ceq (Get-ApiCredentialFingerprint $auth)) { return [string]$entry.id }
        }
    }
    return ''
}

function Set-ProfileDetails {
    param([ValidateSet('api','official')][string]$Kind,[string]$Selector,[System.Collections.IDictionary]$Values)
    $registry = Ensure-ProfileRegistry (Read-State)
    $entry = Find-ProfileEntry $registry $Kind $Selector
    if ($Kind -eq 'api' -and (Get-LiveProfileId) -ceq [string]$entry.id -and
        ($Values.Contains('base_url') -or $Values.Contains('api_key') -or $Values.Contains('model_catalog_json'))) {
        $entry['pending_from'] = Get-ApiProfileFingerprint (Read-AuthText) ([string](Get-TopLevelTomlValue (Read-TextFile $ConfigPath) 'openai_base_url'))
    }
    if ($Values.Contains('name')) {
        $name = ([string]$Values['name']).Trim()
        if ([string]::IsNullOrWhiteSpace($name)) { throw '名称不能为空。' }
        $entry['name'] = $name
    }
    foreach ($key in @('model','context_window','proxy_policy')) {
        if ($Values.Contains($key)) { $entry[$key] = ([string]$Values[$key]).Trim() }
    }
    if ($Values.Contains('settings_scope')) {
        if ([string]$Values['settings_scope'] -cne 'account') { throw '不支持的账号设置范围。' }
        $entry['settings_scope'] = 'account'
    }
    Assert-ContextWindow ([string](Get-ProfileField $entry 'context_window'))
    if ([string](Get-ProfileField $entry 'proxy_policy') -notin @('','inherit','preserve','system','direct')) { throw '无效的代理选项。' }
    $files = @()
    if ($Kind -eq 'api') {
        if ($Values.Contains('base_url')) { Assert-RelayBaseUrl ([string]$Values['base_url']); $entry['base_url'] = ([string]$Values['base_url']).Trim() }
        if ($Values.Contains('model_catalog_json')) {
            $catalog = ([string]$Values['model_catalog_json']).Trim()
            if ($catalog -and -not [IO.File]::Exists((Resolve-NormalizedPath $catalog))) { throw '指定的模型目录文件不存在。' }
            $entry['model_catalog_json'] = $catalog
        }
        if ($Values.Contains('api_key') -and -not [string]::IsNullOrWhiteSpace([string]$Values['api_key'])) {
            $text = ConvertTo-Json -InputObject @{OPENAI_API_KEY=[string]$Values['api_key']} -Compress
            $files += New-EncryptedAuthFile (Get-ProfileAuthPath api $entry.auth_file) $text api
        }
    }
    $entry['updated_utc'] = [DateTime]::UtcNow.ToString('o')
    $files += New-ProfileRegistryFile $registry
    Commit-ProfileFiles $files
    Write-Host '账号配置已保存；下次切换到此档案时生效。'
}

function Remove-ProfileEntry {
    param([ValidateSet('api','official')][string]$Kind,[string]$Selector)
    $registry = Ensure-ProfileRegistry (Read-State)
    $entry = Find-ProfileEntry $registry $Kind $Selector
    if ((Get-LiveProfileId) -ceq [string]$entry.id) { throw '当前正在使用这个账号，请先切换到其他账号再移除。' }
    $collection = Get-ProfileCollectionName $Kind
    $registry[$collection] = @($registry[$collection] | Where-Object { $_.id -cne $entry.id })
    $activeKey = 'active_' + $Kind + '_profile_id'
    if ($registry[$activeKey] -ceq $entry.id) {
        $registry[$activeKey] = if (@($registry[$collection]).Count -gt 0) { [string]$registry[$collection][0].id } else { '' }
    }
    $files = @(New-ProfileRegistryFile $registry)
    $state=Read-State
    if($null -ne $state -and [string](Get-ProfileField $state $activeKey) -ceq [string]$entry.id){
        $state[$activeKey]=[string]$registry[$activeKey]
        $state['updated_utc']=[DateTime]::UtcNow.ToString('o')
        $plain=$script:Utf8NoBom.GetBytes((ConvertTo-Json -InputObject $state -Depth 10))
        try{$encrypted=Protect-BytesForCurrentUser $plain}finally{[Array]::Clear($plain,0,$plain.Length)}
        $files += [pscustomobject]@{Path=$StatePath;TargetBytes=$encrypted}
    }
    $files += [pscustomobject]@{Path=(Get-ProfileAuthPath $Kind $entry.auth_file);Delete=$true}
    # Remove the matching legacy slot as well, so an empty collection cannot
    # resurrect the profile on the next migration.
    $legacy = if ($Kind -eq 'api') { $RelayAuthPath } else { $OfficialAuthPath }
    if ([IO.File]::Exists($legacy)) {
        $legacyText = Unprotect-AuthSnapshot -Path $legacy -ExpectedKind $Kind
        $match = if ($Kind -eq 'official') { (Get-OfficialProfileIdFromAuth $legacyText) -ceq $entry.id } else {
            (Get-ApiCredentialFingerprint $legacyText) -ceq (Get-ApiCredentialFingerprint (Unprotect-AuthSnapshot -Path (Get-ProfileAuthPath api $entry.auth_file) -ExpectedKind api))
        }
        if ($match -or @($registry[$collection]).Count -eq 0) { $files += [pscustomobject]@{Path=$legacy;Delete=$true} }
    }
    Commit-ProfileFiles $files
    Write-Host '已移除本地账号档案。聊天和项目继续保留。'
}

function Get-OfficialIdentitySummary {
    param([string]$AuthText)
    $auth = Read-DesktopJson $AuthText
    $tokens = Get-ProfileField $auth 'tokens'
    $account = [string](Get-ProfileField $tokens 'account_id')
    $email = ''; $expires = $null
    foreach ($key in @('access_token','id_token')) {
        try {
            $parts = ([string](Get-ProfileField $tokens $key)).Split('.')
            if ($parts.Length -ne 3) { continue }
            $payload = $parts[1].Replace('-','+').Replace('_','/')
            $payload = $payload.PadRight([int]([Math]::Ceiling($payload.Length/4.0)*4),'=')
            $claims = Read-DesktopJson ($script:Utf8NoBom.GetString([Convert]::FromBase64String($payload)))
            if (Get-ProfileField $claims 'email') { $email = [string](Get-ProfileField $claims 'email') }
            if ($key -eq 'access_token' -and (Get-ProfileField $claims 'exp')) { $expires = [DateTimeOffset]::FromUnixTimeSeconds([long](Get-ProfileField $claims 'exp')).UtcDateTime }
        } catch { continue }
    }
    $state = if ($null -ne $expires -and $expires -lt [DateTime]::UtcNow) { '可能需要刷新或重新登录' } else { '已保存本地凭据' }
    return [pscustomobject]@{Email=$email;Account=$account;Status=$state}
}

function Get-SwitcherDiagnostics {
    $checks = New-Object Collections.Generic.List[object]
    $cli = ''; try { $cli = Resolve-CodexCommand } catch { }
    $checks.Add([pscustomobject]@{Name='Codex 命令行';Status=$(if($cli){'ok'}else{'error'});Detail=$(if($cli){$cli}else{'未找到 Codex。安装 Codex Desktop，或把 codex 加入 PATH。'})})
    $sqlite = Get-Command sqlite3.exe -ErrorAction SilentlyContinue
    if ($null -eq $sqlite) { $sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue }
    $databases = @()
    foreach ($folder in @($CodexHome,(Join-Path $CodexHome 'sqlite'))) {
        if ([IO.Directory]::Exists($folder)) { $databases += @([IO.Directory]::EnumerateFiles($folder,'*.sqlite',[IO.SearchOption]::TopDirectoryOnly)) }
    }
    $databaseStatus='ok';$databaseDetail=''
    if($null -ne $sqlite -and $sqlite.CommandType -eq 'Application'){$databaseDetail=$sqlite.Source}
    else{
        try{Initialize-WindowsSqlite;$databaseDetail='Windows 内置 SQLite 可用，无需另行安装。'}
        catch{$databaseStatus=if($databases.Count){'error'}else{'info'};$databaseDetail=$_.Exception.Message}
    }
    $checks.Add([pscustomobject]@{Name='历史数据库工具';Status=$databaseStatus;Detail=$databaseDetail})
    $configStatus = 'info'; $configDetail = '尚未设置，添加第一个账号即可开始。'
    if ([IO.File]::Exists($ConfigPath)) {
        try { Assert-SupportedConfig (Read-TextFile $ConfigPath); $configStatus='ok';$configDetail='当前配置可用；模型、上下文和代理默认保留。' }
        catch { $configStatus='error';$configDetail=$_.Exception.Message }
    }
    $checks.Add([pscustomobject]@{Name='Codex 配置';Status=$configStatus;Detail=$configDetail})
    foreach ($path in @($CodexHome,$DataDir)) {
        $parent = $path
        while (-not [IO.Directory]::Exists($parent) -and (Split-Path -Parent $parent)) { $parent=Split-Path -Parent $parent }
        $status='ok';$detail=$path
        try {
            if ([IO.File]::Exists($path)) { throw '目标路径是文件，不能作为目录。' }
            # Test effective access, including inherited deny rules. The empty
            # probe is automatically deleted when its handle closes.
            $probe=Join-Path $parent ('.codex-switcher-probe-'+[Guid]::NewGuid().ToString('N'))
            $handle=New-Object IO.FileStream($probe,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,1,[IO.FileOptions]::DeleteOnClose)
            $handle.Dispose()
            if(-not [IO.Directory]::Exists($path)){$detail+='（首次操作时创建）'}
        } catch { $status='error';$detail=$_.Exception.Message }
        $checks.Add([pscustomobject]@{Name=$(if($path -eq $CodexHome){'聊天与项目目录'}else{'切换器数据目录'});Status=$status;Detail=$detail})
    }
    try { Assert-NoExternalAuthOverrides; $checks.Add([pscustomobject]@{Name='认证环境变量';Status='ok';Detail='没有检测到覆盖本地账号的环境变量。'}) }
    catch { $checks.Add([pscustomobject]@{Name='认证环境变量';Status='error';Detail=$_.Exception.Message}) }
    try { Assert-CodexProcessesStopped 3>$null; $checks.Add([pscustomobject]@{Name='Codex 运行状态';Status='ok';Detail='可以执行账号切换。'}) }
    catch { $checks.Add([pscustomobject]@{Name='Codex 运行状态';Status='info';Detail='Codex 正在运行。管理账号可用，切换前请完全退出应用和 CLI。'}) }
    if([IO.File]::Exists($TransactionPath) -or [IO.File]::Exists($script:ProfileTransactionPath)){
        $checks.Add([pscustomobject]@{Name='上次操作恢复';Status='info';Detail='检测到未完成的事务。退出 Codex 后执行下一次操作，会先恢复原状态。'})
    }
    return $checks.ToArray()
}

function Get-SwitcherViewState {
    $registry = Read-ProfileRegistry
    $liveId = ''; $mode = '未设置'; $issue=''
    try {
        $liveId = Get-LiveProfileId
        if ([IO.File]::Exists($AuthPath) -and [IO.File]::Exists($ConfigPath)) { $mode = Get-LiveMode (Read-TextFile $ConfigPath) (Read-AuthText) }
    } catch { $issue=$_.Exception.Message }
    $profiles = @()
    foreach ($kind in @('official','api')) {
        foreach ($entry in @($registry[(Get-ProfileCollectionName $kind)])) {
            $status='已保存本地凭据';$identity='';$path=Get-ProfileAuthPath $kind $entry.auth_file
            try {
                $text=Unprotect-AuthSnapshot -Path $path -ExpectedKind $kind
                if ($kind -eq 'official') { $who=Get-OfficialIdentitySummary $text; $status=$who.Status;$identity=$who.Email; if(-not $identity){$identity=$who.Account} }
            } catch { $status='凭据不可用，请更新或重新登录' }
            $policy = Get-SwitcherModePolicy -Mode $kind -Entry $entry
            $profiles += [pscustomobject]@{Id=[string]$entry.id;Kind=$kind;Name=[string]$entry.name;BaseUrl=[string](Get-ProfileField $entry 'base_url');Model=$policy.Model;ContextWindow=$policy.ContextWindow;ProxyPolicy=$policy.Proxy;Catalog=[string](Get-ProfileField $entry 'model_catalog_json');Active=($liveId -ceq [string]$entry.id);Identity=$identity;Status=$status}
        }
    }
    $projectCount=0
    $globalPath=Join-Path $CodexHome '.codex-global-state.json'
    if([IO.File]::Exists($globalPath)) { try { $root=Read-DesktopJson (Read-TextFile $globalPath);$projects=Get-ProfileField $root 'local-projects';if($projects -is [Collections.IDictionary]){$projectCount=$projects.Count} }catch{} }
    return [pscustomobject]@{Profiles=$profiles;Mode=$mode;Issue=$issue;CodexHome=$CodexHome;DataDir=$DataDir;ProjectCount=$projectCount;Initialized=($null -ne (Read-State))}
}

function Read-SwitcherPrompt {
    param([string]$Name,[string]$Prompt,[switch]$Secret)
    if ($null -ne $script:OperationInput) {
        if (-not $script:OperationInput.Contains($Name)) { throw "图形界面请求缺少字段：$Name" }
        return [string]$script:OperationInput[$Name]
    }
    if ($Secret) { return Convert-SecureStringToPlainText (Read-Host $Prompt -AsSecureString) }
    return Read-Host $Prompt
}

function Invoke-ReauthorizeProfile {
    param([string]$Selector)
    $existing = Find-ProfileEntry (Read-ProfileRegistry) official $Selector
    $script:ReauthorizeExpectedId = [string]$existing.id
    try { Add-OfficialProfileInteractively -ProfileDisplayName ([string]$existing.name) }
    finally { $script:ReauthorizeExpectedId = '' }
}

function Invoke-SwitcherRequest {
    param([string]$Path)
    $requestRoot=Join-Path $DataDir 'requests'
    $resolved=Resolve-NormalizedPath $Path
    if ((Split-Path -Parent $resolved) -ine $requestRoot -or [IO.Path]::GetFileName($resolved) -notmatch '^[a-f0-9]{32}\.dpapi$') { throw '图形界面请求路径无效。' }
    $plain=Unprotect-BytesForCurrentUser ([IO.File]::ReadAllBytes($resolved))
    try { $request=Read-DesktopJson ($script:Utf8NoBom.GetString($plain)) }
    finally { [Array]::Clear($plain,0,$plain.Length);[IO.File]::Delete($resolved) }
    $script:OperationInput=$request
    $script:LastSavedProfileId=''
    $action=[string](Get-ProfileField $request 'action');$kind=[string](Get-ProfileField $request 'kind');$selector=[string](Get-ProfileField $request 'selector')
    try {
        switch ($action) {
            'initialize' { Initialize-Switcher }
            'add-api' {
                if($null -eq (Read-State)){Initialize-Switcher}
                if(-not $script:LastSavedProfileId){Add-ApiProfileInteractively}
            }
            'add-official' {
                if($null -eq (Read-State)){Initialize-Switcher}
                if(-not $script:LastSavedProfileId){Add-OfficialProfileInteractively}
            }
            'use' { if($kind -notin @('api','official')){throw '账号类型无效。'};Initialize-WindowsSqlite;Invoke-AutoSwitch -TargetModeOverride $kind -ProfileName $selector }
            'edit' { Set-ProfileDetails $kind $selector $request }
            'remove' { Remove-ProfileEntry $kind $selector }
            'reauthorize' { Invoke-ReauthorizeProfile $selector }
            'recover' { Write-Host '已恢复取消前的配置和认证。' }
            'settings' {
                $settings=[ordered]@{version=1;official_proxy=[string](Get-ProfileField $request 'official_proxy');api_proxy=[string](Get-ProfileField $request 'api_proxy');context_window=[string](Get-ProfileField $request 'context_window')}
                foreach($key in @('official_proxy','api_proxy')){if($settings[$key] -notin @('preserve','system','direct')){throw '代理策略无效。'}}
                Assert-ContextWindow $settings.context_window
                Commit-ProfileFiles @([pscustomobject]@{Path=$script:SettingsPath;TargetBytes=$script:Utf8NoBom.GetBytes((ConvertTo-Json -InputObject $settings))})
                Write-Host '默认设置已保存，下次切换生效。'
            }
            default { throw '不支持的图形界面操作。' }
        }
        if($action -in @('add-api','add-official') -and ((Get-ProfileField $request 'model') -or (Get-ProfileField $request 'context_window') -or (Get-ProfileField $request 'proxy_policy') -or (Get-ProfileField $request 'settings_scope'))) {
            if($script:LastSavedProfileId){Set-ProfileDetails $(if($action -eq 'add-api'){'api'}else{'official'}) $script:LastSavedProfileId $request}
        }
    } finally { $script:OperationInput=$null }
}

$script:OperationInput = $null
$script:ReauthorizeExpectedId = ''
$script:LastSavedProfileId = ''
