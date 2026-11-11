#requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("menu", "toggle", "setup", "init", "status", "diagnose", "request", "profiles", "profile-list", "profile-add-api", "profile-add-official", "profile-use-api", "profile-use-official", "profile-rename", "profile-remove", "profile-update", "profile-reauth", "official", "api", "config-official", "config-api", "history-scan", "history-prepare", "history-repair", "project-scan", "project-repair", "desktop-scan", "desktop-repair")]
    [string]$Command = "menu",

    [string]$CodexHome,
    [string]$DataDir,
    [string]$MonitorDataDir,
    [string]$CodexExecutable,
    [string]$RelayModelCatalogPath,
    [string]$Profile,
    [ValidateSet('api','official')][string]$Kind = 'api',
    [string]$RequestPath,
    [switch]$LibraryOnly,
    [switch]$UnsafeAllowRunningCodex,
    [switch]$FullHistoryScan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
    $consoleUtf8 = New-Object System.Text.UTF8Encoding($false)
    [Console]::InputEncoding = $consoleUtf8
    [Console]::OutputEncoding = $consoleUtf8
    $global:OutputEncoding = $consoleUtf8
}
catch {
    # Older or redirected hosts may not expose a writable console encoding.
}

if ($env:OS -ne "Windows_NT") {
    throw "Codex 配置切换器目前只支持 Windows。"
}

if ($PSVersionTable.PSEdition -eq "Desktop") {
    Add-Type -AssemblyName System.Security
}

if ($null -eq ("CodexProfileSwitcher.NativeMethods" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CodexProfileSwitcher {
    public static class NativeMethods {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool MoveFileEx(string existingFileName, string newFileName, int flags);
    }
}
'@
}

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:EntropyLabel = "CodexProfileSwitcher/v1"
$bundledTools = Join-Path $PSScriptRoot 'tools'
if ([IO.File]::Exists((Join-Path $bundledTools 'sqlite3.ps1')) -and $bundledTools -notin ($env:PATH -split ';')) { $env:PATH = $bundledTools + ';' + $env:PATH }

function Resolve-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    return [IO.Path]::GetFullPath($expanded).TrimEnd([IO.Path]::DirectorySeparatorChar)
}

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        $CodexHome = $env:CODEX_HOME
    }
    else {
        $CodexHome = Join-Path $env:USERPROFILE ".codex"
    }
}

if ([string]::IsNullOrWhiteSpace($DataDir)) {
    $localDataRoot = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($localDataRoot)) {
        $localDataRoot = Join-Path $env:USERPROFILE "AppData\Local"
    }
    $DataDir = Join-Path $localDataRoot "CodexProfileSwitcher"
}

$monitorDirectorySpecified=-not [string]::IsNullOrWhiteSpace($MonitorDataDir)
if ([string]::IsNullOrWhiteSpace($MonitorDataDir)) {
    $monitorLocalRoot = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($monitorLocalRoot)) {
        $monitorLocalRoot = Join-Path $env:USERPROFILE "AppData\Local"
    }
    $MonitorDataDir = Join-Path $monitorLocalRoot "CodexDesktopWeixin"
}

$CodexHome = Resolve-NormalizedPath $CodexHome
$DataDir = Resolve-NormalizedPath $DataDir
$MonitorDataDir = Resolve-NormalizedPath $MonitorDataDir
$script:MonitorMaintenanceEnabled=$monitorDirectorySpecified -or [IO.File]::Exists((Join-Path $MonitorDataDir 'settings.json'))
$ConfigPath = Join-Path $CodexHome "config.toml"
$AuthPath = Join-Path $CodexHome "auth.json"
$StatePath = Join-Path $DataDir "state.dpapi"
$LegacyStatePath = Join-Path $DataDir "state.json"
$LegacyStateProofPath = Join-Path $DataDir "state.integrity.dpapi"
$RelayAuthPath = Join-Path $DataDir "relay.auth.dpapi"
$OfficialAuthPath = Join-Path $DataDir "official.auth.dpapi"
$TransactionPath = Join-Path $DataDir "transaction.dpapi"
$LockPath = Join-Path $DataDir "switch.lock"
$HistoryCompatibilityScript = Join-Path $PSScriptRoot "codex-history-compat.ps1"
$ProjectProjectionScript = Join-Path $PSScriptRoot "codex-project-projection.ps1"
$HistoryBackupRoot = Join-Path $DataDir "history-repair-backups"
$ProjectProjectionBackupRoot = Join-Path $DataDir "project-projection-repair"
$DesktopStateScript = Join-Path $PSScriptRoot "codex-desktop-state.ps1"
if (-not [IO.File]::Exists($DesktopStateScript)) { throw "缺少桌面状态兼容脚本：$DesktopStateScript" }
. $DesktopStateScript
$ProfileRegistryScript = Join-Path $PSScriptRoot "codex-profile-registry.ps1"
if (-not [IO.File]::Exists($ProfileRegistryScript)) { throw "缺少配置档案注册表脚本：$ProfileRegistryScript" }
. $ProfileRegistryScript
. (Join-Path $PSScriptRoot 'codex-switcher-service.ps1')
$HistoryReadyPath = Join-Path $DataDir "history-compat-ready.json"
$LastErrorPath = Join-Path $DataDir "last-error.json"
$LegacyRelayModelCatalogPath = Resolve-NormalizedPath (Join-Path (Split-Path -Parent $PSScriptRoot) "codex-model-list-repair\models.json")
if ([string]::IsNullOrWhiteSpace($RelayModelCatalogPath)) {
    $RelayModelCatalogPath = Join-Path $DataDir "relay-models.json"
}
$RelayModelCatalogPath = Resolve-NormalizedPath $RelayModelCatalogPath
$LastRunPath = Join-Path $DataDir 'last-run.json'
$script:AutoRunTimer = $null
$script:LatestHistoryMetrics = $null
$script:ProjectProjectionPreflightComplete = $false
$script:ResolvedCodexCommand = $null
$script:OperationAction = $Command
$script:OperationStage = "startup"
$MonitorMaintenancePath = Join-Path $MonitorDataDir "maintenance.json"

function Test-RelayModelCatalogPath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    try {
        return [string]::Equals(
            (Resolve-NormalizedPath $Path),
            $RelayModelCatalogPath,
            [StringComparison]::OrdinalIgnoreCase
        ) -or [string]::Equals(
            (Resolve-NormalizedPath $Path),
            $LegacyRelayModelCatalogPath,
            [StringComparison]::OrdinalIgnoreCase
        )
    }
    catch {
        return $false
    }
}

function Save-LastSwitcherFailure {
    param([Parameter(Mandatory = $true)]$Failure)

    # One bounded report, overwritten on failure. Never serialize the error
    # record, invocation text, credentials, config or conversation contents.
    $message = [string]$Failure.Exception.Message
    $category = "unknown"
    $summary = "操作未完成；请根据失败位置检查脚本。"
    if ($message -match '请先关闭 Codex|Codex.*仍在运行') {
        $category = "codex_running"
        $summary = "Codex 尚未完全退出，已在写入前停止。"
    }
    elseif ($message -match '分页|界面投影') {
        $category = "history_projection"
        $summary = "历史文件与分页索引未通过对应关系检查，未强行跳过。"
    }
    elseif ($message -match '已经恢复本轮|已恢复|已经恢复切换前') {
        $category = "rolled_back"
        $summary = "操作失败，脚本已执行本轮回滚。"
    }
    elseif ($message -match '回滚|恢复失败') {
        $category = "recovery_required"
        $summary = "恢复尚未完成；保留现有文件和事务记录，需检查后继续。"
    }
    elseif ($message -match '认证|OAuth|快照|登录|DPAPI') {
        $category = "authentication"
        $summary = "认证或快照检查未通过。"
    }
    elseif ($message -match '配置|config|TOML') {
        $category = "configuration"
        $summary = "配置检查未通过。"
    }
    elseif ($message -match '兼容|JSONL|SQLite|对话历史') {
        $category = "history_compatibility"
        $summary = "历史兼容检查未通过。"
    }
    $report = [ordered]@{
        version = 1
        script_revision = "2026-11-07-state-preflight-r2"
        time_utc = [DateTime]::UtcNow.ToString("o")
        action = $script:OperationAction
        stage = $script:OperationStage
        category = $category
        summary = $summary
        exception_type = $Failure.Exception.GetType().FullName
        source_script = [IO.Path]::GetFileName([string]$Failure.InvocationInfo.ScriptName)
        source_line = $Failure.InvocationInfo.ScriptLineNumber
        powershell_version = [string]$PSVersionTable.PSVersion
    }
    Write-AtomicText -Path $LastErrorPath -Text ($report | ConvertTo-Json -Depth 3)
}

function Write-MonitorMaintenanceMarker {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [int]$LifetimeSeconds = 180
    )

    if(-not $script:MonitorMaintenanceEnabled){return}
    $now = [DateTime]::UtcNow
    $marker = [ordered]@{
        version = 1
        reason = "codex_profile_switch"
        action = $Action
        created_at = $now.ToString("o")
        expires_at = $now.AddSeconds($LifetimeSeconds).ToString("o")
    }
    $bytes = $script:Utf8NoBom.GetBytes(($marker | ConvertTo-Json -Depth 4))
    Write-AtomicBytes -Path $MonitorMaintenancePath -Bytes $bytes
}

function Invoke-WithMonitorMaintenance {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [Parameter(Mandatory = $true)][scriptblock]$Operation
    )

    $script:OperationAction = $Action
    $script:OperationStage = $Action
    Write-MonitorMaintenanceMarker -Action $Action -LifetimeSeconds 180
    try {
        & $Operation
    }
    finally {
        Write-MonitorMaintenanceMarker -Action $Action -LifetimeSeconds 90
    }
}

function Get-JsonPropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property.Value
}

function Write-AtomicBytes {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporaryPath = Join-Path $directory (".{0}.{1}.tmp" -f [IO.Path]::GetFileName($Path), [Guid]::NewGuid().ToString("N"))

    try {
        $stream = New-Object IO.FileStream(
            $temporaryPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None,
            4096,
            [IO.FileOptions]::WriteThrough
        )
        try {
            $stream.Write($Bytes, 0, $Bytes.Length)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }

        Move-ReplaceFile -Source $temporaryPath -Destination $Path
    }
    finally {
        if ([IO.File]::Exists($temporaryPath)) {
            [IO.File]::Delete($temporaryPath)
        }
    }
}

function Move-ReplaceFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $moveFileReplaceExisting = 0x1
    $moveFileWriteThrough = 0x8
    if (-not [CodexProfileSwitcher.NativeMethods]::MoveFileEx(
        $Source,
        $Destination,
        ($moveFileReplaceExisting -bor $moveFileWriteThrough)
    )) {
        $win32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        # Some Windows builds reject MoveFileEx for a freshly-created nested
        # Unicode path even though both files are valid. Use the managed move
        # only when the destination is absent; the normal atomic replacement
        # path remains the first choice.
        if ([IO.File]::Exists($Source) -and -not [IO.File]::Exists($Destination)) {
            try {
                [IO.File]::Move($Source, $Destination)
                return
            }
            catch { }
        }
        throw (New-Object ComponentModel.Win32Exception($win32Error))
    }
}

function Write-AtomicText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $bytes = $script:Utf8NoBom.GetBytes($Text)
    try {
        Write-AtomicBytes -Path $Path -Bytes $bytes
    }
    finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Read-TextFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not [IO.File]::Exists($Path)) {
        throw "缺少必需文件：$Path"
    }
    return [IO.File]::ReadAllText($Path, $script:Utf8NoBom)
}

function Strip-TomlInlineComment {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $inSingleQuote = $false
    $inDoubleQuote = $false
    $escaped = $false

    for ($index = 0; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]

        if ($inDoubleQuote -and $escaped) {
            $escaped = $false
            continue
        }
        if ($inDoubleQuote -and $character -eq "\") {
            $escaped = $true
            continue
        }
        if (-not $inDoubleQuote -and $character -eq "'") {
            $inSingleQuote = -not $inSingleQuote
            continue
        }
        if (-not $inSingleQuote -and $character -eq '"') {
            $inDoubleQuote = -not $inDoubleQuote
            continue
        }
        if (-not $inSingleQuote -and -not $inDoubleQuote -and $character -eq "#") {
            return $Text.Substring(0, $index).Trim()
        }
    }

    return $Text.Trim()
}

function ConvertFrom-TomlScalar {
    param([Parameter(Mandatory = $true)][string]$Value)

    $trimmed = (Strip-TomlInlineComment $Value).Trim()
    if ($trimmed.Length -ge 2 -and $trimmed.StartsWith('"') -and $trimmed.EndsWith('"')) {
        return ($trimmed | ConvertFrom-Json)
    }
    if ($trimmed.Length -ge 2 -and $trimmed.StartsWith("'") -and $trimmed.EndsWith("'")) {
        return $trimmed.Substring(1, $trimmed.Length - 2)
    }
    return $trimmed
}

function Get-TopLevelTomlValue {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Key
    )

    $values = New-Object System.Collections.Generic.List[string]
    $isTopLevel = $true
    foreach ($line in [regex]::Split($Text, "\r?\n")) {
        if ($isTopLevel -and $line -match '^\s*\[') {
            $isTopLevel = $false
        }
        if (-not $isTopLevel) {
            continue
        }

        $match = [regex]::Match($line, ('^\s*{0}\s*=\s*(?<value>.+)$' -f [regex]::Escape($Key)))
        if ($match.Success) {
            $values.Add((ConvertFrom-TomlScalar $match.Groups["value"].Value))
        }
    }

    if ($values.Count -gt 1) {
        throw "config.toml 顶层存在多个 '$Key' 设置。"
    }
    if ($values.Count -eq 0) {
        return $null
    }
    return $values[0]
}

function Get-SimpleAssignmentComment {
    param([Parameter(Mandatory = $true)][string]$Line)

    $commentIndex = $Line.IndexOf("#")
    if ($commentIndex -lt 0) {
        return ""
    }
    return " " + $Line.Substring($commentIndex).TrimStart()
}

function Set-TopLevelTomlInteger {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][int64]$Value
    )

    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [regex]::Split($Text, "\r?\n")
    $result = New-Object System.Collections.Generic.List[string]
    $isTopLevel = $true
    $seen = $false

    foreach ($line in $lines) {
        if ($isTopLevel -and $line -match '^\s*\[') {
            $isTopLevel = $false
        }

        if ($isTopLevel -and $line -match ('^\s*{0}\s*=' -f [regex]::Escape($Key))) {
            if ($seen) {
                throw "config.toml 顶层存在多个 '$Key' 设置。"
            }
            $seen = $true
            $result.Add(("{0} = {1}" -f $Key, $Value) + (Get-SimpleAssignmentComment $line))
            continue
        }

        $result.Add($line)
    }

    if (-not $seen) {
        $insertIndex = $result.Count
        for ($index = 0; $index -lt $result.Count; $index++) {
            if ($result[$index] -match '^\s*\[') {
                $insertIndex = $index
                break
            }
        }
        $result.Insert($insertIndex, ("{0} = {1}" -f $Key, $Value))
    }

    return [string]::Join($newline, $result)
}

function Get-TomlTableValue {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][string]$Table,
        [Parameter(Mandatory = $true)][string]$Key
    )

    $values = New-Object System.Collections.Generic.List[string]
    $currentTable = ""
    foreach ($line in [regex]::Split($Text, "\r?\n")) {
        $withoutComment = Strip-TomlInlineComment $line
        $header = [regex]::Match($withoutComment, '^\s*\[(?<name>[A-Za-z0-9_.-]+)\]\s*$')
        if ($header.Success) {
            $currentTable = $header.Groups["name"].Value
            continue
        }
        if ($withoutComment -match '^\s*\[') {
            $currentTable = ""
            continue
        }
        if ($currentTable -cne $Table) {
            continue
        }

        $match = [regex]::Match($line, ('^\s*{0}\s*=\s*(?<value>.+)$' -f [regex]::Escape($Key)))
        if ($match.Success) {
            $values.Add((ConvertFrom-TomlScalar $match.Groups["value"].Value))
        }
    }

    if ($values.Count -gt 1) {
        throw "config.toml 的 [$Table] 中存在多个 '$Key' 设置。"
    }
    if ($values.Count -eq 0) {
        return $null
    }
    return $values[0]
}

function Set-TomlTableBoolean {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Table,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][bool]$Value
    )

    $newline = if ($Text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $result = New-Object System.Collections.Generic.List[string]
    foreach ($line in [regex]::Split($Text, "\r?\n")) {
        $result.Add($line)
    }

    $tableStart = -1
    $tableEnd = $result.Count
    $valueIndex = -1
    $insideTarget = $false
    for ($index = 0; $index -lt $result.Count; $index++) {
        $withoutComment = Strip-TomlInlineComment $result[$index]
        $header = [regex]::Match($withoutComment, '^\s*\[(?<name>[A-Za-z0-9_.-]+)\]\s*$')
        if ($header.Success) {
            if ($insideTarget -and $tableEnd -eq $result.Count) {
                $tableEnd = $index
            }
            $insideTarget = $header.Groups["name"].Value -ceq $Table
            if ($insideTarget) {
                if ($tableStart -ge 0) {
                    throw "config.toml 中存在多个 [$Table] 段。"
                }
                $tableStart = $index
            }
            continue
        }
        if ($withoutComment -match '^\s*\[') {
            if ($insideTarget -and $tableEnd -eq $result.Count) {
                $tableEnd = $index
            }
            $insideTarget = $false
            continue
        }
        if ($insideTarget -and $result[$index] -match ('^\s*{0}\s*=' -f [regex]::Escape($Key))) {
            if ($valueIndex -ge 0) {
                throw "config.toml 的 [$Table] 中存在多个 '$Key' 设置。"
            }
            $valueIndex = $index
        }
    }

    $literal = if ($Value) { "true" } else { "false" }
    $assignment = "$Key = $literal"
    if ($valueIndex -ge 0) {
        $result[$valueIndex] = $assignment + (Get-SimpleAssignmentComment $result[$valueIndex])
    }
    elseif ($tableStart -ge 0) {
        $insertIndex = $tableEnd
        while ($insertIndex -gt ($tableStart + 1) -and [string]::IsNullOrWhiteSpace($result[$insertIndex - 1])) {
            $insertIndex--
        }
        $result.Insert($insertIndex, $assignment)
    }
    else {
        $insertIndex = $result.Count
        while ($insertIndex -gt 0 -and [string]::IsNullOrWhiteSpace($result[$insertIndex - 1])) {
            $insertIndex--
        }
        if ($insertIndex -gt 0) {
            $result.Insert($insertIndex, "")
            $insertIndex++
        }
        $result.Insert($insertIndex, "[$Table]")
        $result.Insert($insertIndex + 1, $assignment)
    }

    $updated = [string]::Join($newline, $result)
    $observed = [string](Get-TomlTableValue -Text $updated -Table $Table -Key $Key)
    if ($observed -cne $literal) {
        throw "生成的配置未正确写入 [$Table].$Key = $literal。"
    }
    return $updated
}

function New-ModeConfigText {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$CurrentText,
        [Parameter(Mandatory = $true)][ValidateSet("official", "api")][string]$Mode,
        [string]$RelayBaseUrl,
        [AllowNull()][string]$ModelCatalogPathOverride,
        [AllowNull()]$ProfileEntry
    )

    if ($Mode -eq "api" -and [string]::IsNullOrWhiteSpace($RelayBaseUrl)) {
        throw "缺少中转地址。请在中转配置生效时运行 codex-switcher.cmd init。"
    }

    $overrideCatalog = $PSBoundParameters.ContainsKey('ModelCatalogPathOverride')
    $existingCatalogPath = [string](Get-TopLevelTomlValue -Text $CurrentText -Key "model_catalog_json")
    $ownsRelayCatalog = Test-RelayModelCatalogPath $existingCatalogPath
    $catalogManagedByProfile = $null -ne $ProfileEntry
    $apiCatalogPath = ''
    if ($Mode -eq 'api') {
        if ($catalogManagedByProfile) {
            $apiCatalogPath = Get-ApiModelCatalogPath $ProfileEntry
        }
        elseif ($overrideCatalog) {
            $apiCatalogPath = [string]$ModelCatalogPathOverride
            if ([string]::IsNullOrWhiteSpace($apiCatalogPath)) { $apiCatalogPath = $RelayModelCatalogPath }
        }
        else {
            $apiCatalogPath = if ([string]::IsNullOrWhiteSpace($existingCatalogPath) -or $ownsRelayCatalog) { $RelayModelCatalogPath } else { $existingCatalogPath }
        }
        if ($apiCatalogPath) {
            $apiCatalogPath = Resolve-NormalizedPath $apiCatalogPath
            if (-not [IO.File]::Exists($apiCatalogPath)) { $apiCatalogPath = '' }
        }
    }

    $policy = Get-SwitcherModePolicy -Mode $Mode -Entry $ProfileEntry
    if (-not [string]::IsNullOrWhiteSpace($policy.ContextWindow)) {
        $CurrentText = Set-TopLevelTomlInteger -Text $CurrentText -Key 'model_context_window' -Value ([int]$policy.ContextWindow)
    }
    if (-not [string]::IsNullOrWhiteSpace($policy.Model)) {
        $CurrentText = Set-TopLevelTomlString -Text $CurrentText -Key 'model' -Value $policy.Model
    }

    $newline = if ($CurrentText.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = [regex]::Split($CurrentText, "\r?\n")
    $result = New-Object System.Collections.Generic.List[string]
    $isTopLevel = $true
    $modelSeen = $false
    $baseUrlSeen = $false
    $credentialStoreSeen = $false
    $modelCatalogSeen = $false
    $modelIndex = -1

    foreach ($line in $lines) {
        if ($isTopLevel -and $line -match '^\s*\[') {
            $isTopLevel = $false
        }

        if ($isTopLevel -and $line -match '^\s*model_provider\s*=') {
            if ($modelSeen) {
                throw "config.toml 顶层存在重复的 model_provider。"
            }
            $modelSeen = $true
            $result.Add('model_provider = "openai"' + (Get-SimpleAssignmentComment $line))
            $modelIndex = $result.Count - 1
            continue
        }

        if ($isTopLevel -and $line -match '^\s*openai_base_url\s*=') {
            if ($baseUrlSeen) {
                throw "config.toml 顶层存在重复的 openai_base_url。"
            }
            $baseUrlSeen = $true
            continue
        }

        if ($isTopLevel -and $line -match '^\s*model_catalog_json\s*=') {
            if ($modelCatalogSeen) {
                throw "config.toml 顶层存在重复的 model_catalog_json。"
            }
            $modelCatalogSeen = $true
            continue
        }

        if ($isTopLevel -and $line -match '^\s*cli_auth_credentials_store\s*=') {
            if ($credentialStoreSeen) {
                throw "config.toml 顶层存在重复的 cli_auth_credentials_store。"
            }
            $credentialStoreSeen = $true
            $result.Add('cli_auth_credentials_store = "file"' + (Get-SimpleAssignmentComment $line))
            continue
        }

        $result.Add($line)
    }

    $firstSectionIndex = $result.Count
    for ($index = 0; $index -lt $result.Count; $index++) {
        if ($result[$index] -match '^\s*\[') {
            $firstSectionIndex = $index
            break
        }
    }

    if (-not $modelSeen) {
        $result.Insert($firstSectionIndex, 'model_provider = "openai"')
        $modelIndex = $firstSectionIndex
    }

    $insertIndex = $modelIndex + 1
    if ($Mode -eq "api") {
        $quotedUrl = ConvertTo-Json -Compress ([string]$RelayBaseUrl)
        $result.Insert($insertIndex, "openai_base_url = $quotedUrl")
        $insertIndex++
        if (-not [string]::IsNullOrWhiteSpace($apiCatalogPath)) {
            $quotedCatalogPath = ConvertTo-Json -Compress ([string]$apiCatalogPath)
            $result.Insert($insertIndex, "model_catalog_json = $quotedCatalogPath")
            $insertIndex++
        }
    }

    if (-not $credentialStoreSeen) {
        $result.Insert($insertIndex, 'cli_auth_credentials_store = "file"')
    }

    $newText = [string]::Join($newline, $result)
    if ($policy.Proxy -ne 'preserve') {
        $newText = Set-TomlTableBoolean -Text $newText -Table 'features' -Key 'respect_system_proxy' -Value ($policy.Proxy -eq 'system')
    }
    $provider = Get-TopLevelTomlValue -Text $newText -Key "model_provider"
    $baseUrl = Get-TopLevelTomlValue -Text $newText -Key "openai_base_url"
    $modelCatalogPath = [string](Get-TopLevelTomlValue -Text $newText -Key "model_catalog_json")
    $credentialStore = Get-TopLevelTomlValue -Text $newText -Key "cli_auth_credentials_store"
    $contextWindow = Get-TopLevelTomlValue -Text $newText -Key "model_context_window"
    $respectSystemProxy = [string](Get-TomlTableValue -Text $newText -Table "features" -Key "respect_system_proxy")

    if ($provider -ne "openai") {
        throw "生成的配置未保持 model_provider = 'openai'。"
    }
    if ($credentialStore -ne "file") {
        throw "生成的配置未将认证保存方式设置为 file。"
    }
    Assert-ContextWindow ([string]$contextWindow)
    if ($Mode -eq "official" -and $null -ne $baseUrl) {
        throw "生成的官方配置仍然包含 openai_base_url。"
    }
    if ($Mode -eq "api" -and $baseUrl -ne $RelayBaseUrl) {
        throw "生成的中转配置包含错误的 openai_base_url。"
    }
    if ($Mode -eq "api" -and -not [string]::Equals($modelCatalogPath, $apiCatalogPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "生成的中转配置未保留当前模型目录引用。"
    }
    if ($Mode -eq "official" -and -not [string]::IsNullOrWhiteSpace($modelCatalogPath)) {
        throw "生成的官方配置仍然覆盖着原生模型目录发现。"
    }
    $expectedSystemProxy = if ($policy.Proxy -eq 'preserve') { [string](Get-TomlTableValue -Text $CurrentText -Table 'features' -Key 'respect_system_proxy') } elseif ($policy.Proxy -eq 'system') { 'true' } else { 'false' }
    if ($respectSystemProxy -cne $expectedSystemProxy) {
        throw "生成的配置未正确设置系统代理跟随状态。"
    }

    return $newText
}

function Get-AuthInfoFromText {
    param([Parameter(Mandatory = $true)][string]$Text)

    try {
        $auth = $Text | ConvertFrom-Json
    }
    catch {
        throw "auth.json 不是合法的 JSON：$($_.Exception.Message)"
    }

    $apiKey = [string](Get-JsonPropertyValue -Object $auth -Name "OPENAI_API_KEY")
    $tokens = Get-JsonPropertyValue -Object $auth -Name "tokens"
    $authMode = [string](Get-JsonPropertyValue -Object $auth -Name "auth_mode")
    $hasApiKey = -not [string]::IsNullOrWhiteSpace($apiKey)
    $hasTokenObject = $null -ne $tokens
    $idToken = if ($hasTokenObject) { [string](Get-JsonPropertyValue -Object $tokens -Name "id_token") } else { "" }
    $accessToken = if ($hasTokenObject) { [string](Get-JsonPropertyValue -Object $tokens -Name "access_token") } else { "" }
    $refreshToken = if ($hasTokenObject) { [string](Get-JsonPropertyValue -Object $tokens -Name "refresh_token") } else { "" }
    $hasCompleteOAuthTokens =
        -not [string]::IsNullOrWhiteSpace($idToken) -and
        -not [string]::IsNullOrWhiteSpace($accessToken) -and
        -not [string]::IsNullOrWhiteSpace($refreshToken)

    if ($hasApiKey -and ($hasTokenObject -or $authMode -eq "chatgpt")) {
        return [pscustomobject]@{ Kind = "ambiguous"; AuthMode = $authMode }
    }
    if (-not $hasApiKey -and $authMode -eq "chatgpt" -and $hasCompleteOAuthTokens) {
        return [pscustomobject]@{ Kind = "official"; AuthMode = $authMode }
    }
    if ($hasApiKey -and -not $hasTokenObject -and $authMode -ne "chatgpt") {
        return [pscustomobject]@{ Kind = "api"; AuthMode = $authMode }
    }
    return [pscustomobject]@{ Kind = "unknown"; AuthMode = $authMode }
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][byte[]]$Bytes)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($Bytes))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Read-AuthText {
    if (-not [IO.File]::Exists($AuthPath)) {
        throw "auth.json 不存在：$AuthPath"
    }

    $lastError = $null
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            $text = [IO.File]::ReadAllText($AuthPath, $script:Utf8NoBom)
            [void](Get-AuthInfoFromText $text)
            return $text
        }
        catch {
            $lastError = $_
            if ($attempt -lt 5) {
                Start-Sleep -Milliseconds (50 * $attempt)
            }
        }
    }
    throw $lastError
}

function Get-EntropyBytes {
    return $script:Utf8NoBom.GetBytes("$($script:EntropyLabel)|$CodexHome")
}

function Protect-BytesForCurrentUser {
    param([Parameter(Mandatory = $true)][byte[]]$PlainBytes)

    $entropyBytes = Get-EntropyBytes
    try {
        return [Security.Cryptography.ProtectedData]::Protect(
            $PlainBytes,
            $entropyBytes,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
    }
    finally {
        [Array]::Clear($entropyBytes, 0, $entropyBytes.Length)
    }
}

function Unprotect-BytesForCurrentUser {
    param([Parameter(Mandatory = $true)][byte[]]$ProtectedBytes)

    $entropyBytes = Get-EntropyBytes
    try {
        return [Security.Cryptography.ProtectedData]::Unprotect(
            $ProtectedBytes,
            $entropyBytes,
            [Security.Cryptography.DataProtectionScope]::CurrentUser
        )
    }
    finally {
        [Array]::Clear($entropyBytes, 0, $entropyBytes.Length)
    }
}

function Protect-AuthSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet("official", "api")][string]$ExpectedKind
    )

    $authInfo = Get-AuthInfoFromText $Text
    if ($authInfo.Kind -ne $ExpectedKind) {
        throw "当前认证类型为 '$($authInfo.Kind)'，不能保存为 '$ExpectedKind' 快照。"
    }

    $plainBytes = $script:Utf8NoBom.GetBytes($Text)
    $protectedBytes = $null
    $candidatePath = Join-Path (Split-Path -Parent $Path) (".{0}.{1}.candidate" -f [IO.Path]::GetFileName($Path), [Guid]::NewGuid().ToString("N"))
    try {
        $protectedBytes = Protect-BytesForCurrentUser $plainBytes
        Write-AtomicBytes -Path $candidatePath -Bytes $protectedBytes
        $verifiedText = Unprotect-AuthSnapshot -Path $candidatePath -ExpectedKind $ExpectedKind
        if ($verifiedText -cne $Text) {
            throw "认证快照验证后与原始 auth.json 字节不一致。"
        }
        Move-ReplaceFile -Source $candidatePath -Destination $Path
    }
    finally {
        if ([IO.File]::Exists($candidatePath)) {
            [IO.File]::Delete($candidatePath)
        }
        [Array]::Clear($plainBytes, 0, $plainBytes.Length)
        if ($null -ne $protectedBytes) {
            [Array]::Clear($protectedBytes, 0, $protectedBytes.Length)
        }
    }
}

function Unprotect-AuthSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateSet("official", "api")][string]$ExpectedKind
    )

    if (-not [IO.File]::Exists($Path)) {
        throw "认证快照不存在：$Path"
    }

    $protectedBytes = [IO.File]::ReadAllBytes($Path)
    $plainBytes = $null
    try {
        $plainBytes = Unprotect-BytesForCurrentUser $protectedBytes
        $text = $script:Utf8NoBom.GetString($plainBytes)
        $authInfo = Get-AuthInfoFromText $text
        if ($authInfo.Kind -ne $ExpectedKind) {
            throw "保存的 '$ExpectedKind' 快照实际包含 '$($authInfo.Kind)' 认证。"
        }
        return $text
    }
    finally {
        [Array]::Clear($protectedBytes, 0, $protectedBytes.Length)
        if ($null -ne $plainBytes) {
            [Array]::Clear($plainBytes, 0, $plainBytes.Length)
        }
    }
}

function Write-TransactionJournal {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("official", "api", "uninitialized")][string]$SourceMode,
        [Parameter(Mandatory = $true)][ValidateSet("official", "api")][string]$TargetMode,
        [Parameter(Mandatory = $true)][string]$TargetConfigText,
        [AllowNull()][string]$TargetAuthText = $null,
        [object[]]$ExtraFiles = @()
    )

    if ([IO.File]::Exists($TransactionPath)) {
        throw "已经存在一个未完成的切换事务。"
    }

    if($SourceMode -ne 'uninitialized'){
        $observedSourceMode = Get-LiveMode -ConfigText (Read-TextFile $ConfigPath) -AuthText (Read-AuthText)
        if ($observedSourceMode -ne $SourceMode) {
            throw "写入事务前当前模式发生变化；预期 '$SourceMode'，实际 '$observedSourceMode'。"
        }
    }

    $configExisted=[IO.File]::Exists($ConfigPath)
    [byte[]]$configBytes=[byte[]]::new(0)
    if($configExisted){$configBytes = [IO.File]::ReadAllBytes($ConfigPath)}
    $authExisted = [IO.File]::Exists($AuthPath)
    [byte[]]$authBytes = [byte[]]::new(0)
    if ($authExisted) {
        $authBytes = [IO.File]::ReadAllBytes($AuthPath)
    }
    $targetAuthProvided = $PSBoundParameters.ContainsKey("TargetAuthText")
    $targetConfigBytes = $script:Utf8NoBom.GetBytes($TargetConfigText)
    [byte[]]$targetAuthBytes = [byte[]]::new(0)
    if ($targetAuthProvided) {
        $targetAuthBytes = $script:Utf8NoBom.GetBytes($TargetAuthText)
    }
    $journalBytes = $null
    $protectedBytes = $null
    try {
        $extraRecords = @($ExtraFiles | ForEach-Object {
            $exists = [IO.File]::Exists($_.Path)
            [byte[]]$original = [byte[]]::new(0)
            if ($exists) { $original = [IO.File]::ReadAllBytes($_.Path) }
            [ordered]@{
                path = $_.Path; existed = $exists
                base64 = [Convert]::ToBase64String($original)
                sha256 = Get-Sha256Hex $original
                target_sha256 = Get-Sha256Hex $_.TargetBytes
            }
        })
        $record = [ordered]@{
            version = 4
            created_utc = [DateTime]::UtcNow.ToString("o")
            source_mode = $SourceMode
            target_mode = $TargetMode
            config_existed = $configExisted
            config_base64 = [Convert]::ToBase64String($configBytes)
            config_sha256 = Get-Sha256Hex $configBytes
            auth_existed = $authExisted
            auth_base64 = if ($authExisted) { [Convert]::ToBase64String($authBytes) } else { "" }
            auth_sha256 = if ($authExisted) { Get-Sha256Hex $authBytes } else { "" }
            target_config_sha256 = Get-Sha256Hex $targetConfigBytes
            target_auth_sha256 = if ($targetAuthProvided) { Get-Sha256Hex $targetAuthBytes } else { "" }
            extra_files = $extraRecords
        }
        $journalBytes = $script:Utf8NoBom.GetBytes(($record | ConvertTo-Json -Depth 8 -Compress))
        $protectedBytes = Protect-BytesForCurrentUser $journalBytes
        Write-AtomicBytes -Path $TransactionPath -Bytes $protectedBytes
        $verifiedJournal = Read-TransactionJournal
        try {
            [void]$verifiedJournal.ConfigHash
            [void]$verifiedJournal.AuthHash
        }
        finally {
            [Array]::Clear($verifiedJournal.ConfigBytes, 0, $verifiedJournal.ConfigBytes.Length)
            [Array]::Clear($verifiedJournal.AuthBytes, 0, $verifiedJournal.AuthBytes.Length)
        }
    }
    finally {
        [Array]::Clear($configBytes, 0, $configBytes.Length)
        [Array]::Clear($authBytes, 0, $authBytes.Length)
        [Array]::Clear($targetConfigBytes, 0, $targetConfigBytes.Length)
        [Array]::Clear($targetAuthBytes, 0, $targetAuthBytes.Length)
        if ($null -ne $journalBytes) {
            [Array]::Clear($journalBytes, 0, $journalBytes.Length)
        }
        if ($null -ne $protectedBytes) {
            [Array]::Clear($protectedBytes, 0, $protectedBytes.Length)
        }
    }
}

function Read-TransactionJournal {
    if (-not [IO.File]::Exists($TransactionPath)) {
        throw "切换事务记录不存在。"
    }

    $protectedBytes = [IO.File]::ReadAllBytes($TransactionPath)
    $plainBytes = $null
    try {
        $plainBytes = Unprotect-BytesForCurrentUser $protectedBytes
        $record = ($script:Utf8NoBom.GetString($plainBytes)) | ConvertFrom-Json
        $journalVersion=[int](Get-JsonPropertyValue -Object $record -Name "version")
        if ($journalVersion -notin @(2, 3, 4)) {
            throw "不支持此版本的切换事务记录。"
        }

        $sourceMode = [string](Get-JsonPropertyValue -Object $record -Name "source_mode")
        $targetMode = [string](Get-JsonPropertyValue -Object $record -Name "target_mode")
        if ($sourceMode -notin @("official", "api", "uninitialized") -or $targetMode -notin @("official", "api") -or ($sourceMode -eq 'uninitialized' -and $journalVersion -lt 4)) {
            throw "切换事务记录包含无效模式。"
        }

        $configBytes = [Convert]::FromBase64String([string](Get-JsonPropertyValue -Object $record -Name "config_base64"))
        $configHash = [string](Get-JsonPropertyValue -Object $record -Name "config_sha256")
        if ((Get-Sha256Hex $configBytes) -ne $configHash) {
            throw "切换事务记录中的配置哈希不匹配。"
        }

        $authExisted = [bool](Get-JsonPropertyValue -Object $record -Name "auth_existed")
        [byte[]]$authBytes = [byte[]]::new(0)
        if ($authExisted) {
            $authBytes = [Convert]::FromBase64String([string](Get-JsonPropertyValue -Object $record -Name "auth_base64"))
        }
        $authHash = [string](Get-JsonPropertyValue -Object $record -Name "auth_sha256")
        if ($authExisted -and (Get-Sha256Hex $authBytes) -ne $authHash) {
            throw "切换事务记录中的认证哈希不匹配。"
        }

        $extraFiles = @()
        $allowedExtraPaths = @(
            (Join-Path $CodexHome '.codex-global-state.json'),
            (Join-Path $CodexHome '.codex-global-state.json.bak'),
            (Join-Path $DataDir 'desktop-renderer-state.dpapi'),
            $script:ProfileRegistryPath,
            $StatePath
        )
        foreach ($extra in @(Get-JsonPropertyValue -Object $record -Name 'extra_files')) {
            if ($null -eq $extra) { continue }
            $path = [string]$extra.path
            if ($path -notin $allowedExtraPaths -and -not ($sourceMode -eq 'uninitialized' -and (Test-ProfileTransactionPath $path))) { throw '切换事务记录包含未知的桌面状态路径。' }
            $bytes = [Convert]::FromBase64String([string]$extra.base64)
            if ((Get-Sha256Hex $bytes) -cne [string]$extra.sha256) { throw '桌面状态事务哈希不匹配。' }
            $extraFiles += [pscustomobject]@{ Path = $path; Existed = [bool]$extra.existed; Bytes = $bytes; Hash = [string]$extra.sha256; TargetHash = [string]$extra.target_sha256 }
        }

        return [pscustomobject]@{
            SourceMode = $sourceMode
            TargetMode = $targetMode
            ConfigExisted = $(if($journalVersion -lt 4){$true}else{[bool](Get-JsonPropertyValue $record 'config_existed')})
            ConfigBytes = $configBytes
            ConfigHash = $configHash
            AuthExisted = $authExisted
            AuthBytes = $authBytes
            AuthHash = $authHash
            TargetConfigHash = [string](Get-JsonPropertyValue -Object $record -Name "target_config_sha256")
            TargetAuthHash = [string](Get-JsonPropertyValue -Object $record -Name "target_auth_sha256")
            ExtraFiles = $extraFiles
        }
    }
    finally {
        [Array]::Clear($protectedBytes, 0, $protectedBytes.Length)
        if ($null -ne $plainBytes) {
            [Array]::Clear($plainBytes, 0, $plainBytes.Length)
        }
    }
}

function Complete-Transaction {
    if ([IO.File]::Exists($TransactionPath)) {
        [IO.File]::Delete($TransactionPath)
    }
}

function Restore-Transaction {
    $journal = Read-TransactionJournal
    $currentConfigBytes = $null
    $currentAuthBytes = $null
    try {
        if (-not [IO.File]::Exists($ConfigPath) -and $journal.ConfigExisted) {
            throw "正在使用的 config.toml 已缺失，拒绝自动回滚。"
        }
        $currentConfigBytes = [byte[]]::new(0)
        if([IO.File]::Exists($ConfigPath)){$currentConfigBytes = [IO.File]::ReadAllBytes($ConfigPath)}
        $currentConfigHash = Get-Sha256Hex $currentConfigBytes
        if ($currentConfigHash -ne $journal.ConfigHash -and $currentConfigHash -ne $journal.TargetConfigHash) {
            throw "config.toml 出现事务范围外的变化，拒绝自动回滚。"
        }

        $currentAuthExisted = [IO.File]::Exists($AuthPath)
        $authStateKnown = $false
        if ($currentAuthExisted) {
            $currentAuthBytes = [IO.File]::ReadAllBytes($AuthPath)
            $currentAuthHash = Get-Sha256Hex $currentAuthBytes
            if ($currentAuthHash -eq $journal.AuthHash -or
                (-not [string]::IsNullOrWhiteSpace($journal.TargetAuthHash) -and $currentAuthHash -eq $journal.TargetAuthHash)) {
                $authStateKnown = $true
            }
            elseif ([string]::IsNullOrWhiteSpace($journal.TargetAuthHash) -and $journal.TargetMode -eq "official") {
                try {
                    $candidateAuth = $script:Utf8NoBom.GetString($currentAuthBytes)
                    $authStateKnown = (Get-AuthInfoFromText $candidateAuth).Kind -eq "official"
                }
                catch {
                    $authStateKnown = $false
                }
            }
        }
        elseif (-not $journal.AuthExisted -or [string]::IsNullOrWhiteSpace($journal.TargetAuthHash)) {
            $authStateKnown = $true
        }

        if (-not $authStateKnown) {
            throw "auth.json 出现事务范围外的变化，拒绝自动回滚。"
        }

        foreach ($extra in $journal.ExtraFiles) {
            if ([IO.File]::Exists($extra.Path)) {
                $hash = Get-Sha256Hex ([IO.File]::ReadAllBytes($extra.Path))
                if ($hash -cne $extra.Hash -and $hash -cne $extra.TargetHash) {
                    throw "桌面状态出现事务范围外的变化，拒绝自动回滚：$($extra.Path)"
                }
            }
            elseif ($extra.Existed) { throw "桌面状态文件意外缺失，拒绝自动回滚：$($extra.Path)" }
        }

        foreach ($extra in $journal.ExtraFiles) {
            if ($extra.Existed) {
                if ((Get-Sha256Hex ([IO.File]::ReadAllBytes($extra.Path))) -cne $extra.Hash) {
                    Write-AtomicBytes -Path $extra.Path -Bytes $extra.Bytes
                }
            }
            elseif ([IO.File]::Exists($extra.Path)) { [IO.File]::Delete($extra.Path) }
        }

        $restoreAuth = {
            if ($journal.AuthExisted) {
                Write-AtomicBytes -Path $AuthPath -Bytes $journal.AuthBytes
            }
            elseif ([IO.File]::Exists($AuthPath)) {
                [IO.File]::Delete($AuthPath)
            }
        }

        $restoreConfig={
            if($journal.ConfigExisted){Write-AtomicBytes -Path $ConfigPath -Bytes $journal.ConfigBytes}
            elseif([IO.File]::Exists($ConfigPath)){[IO.File]::Delete($ConfigPath)}
        }
        if ($journal.SourceMode -eq "api") {
            & $restoreAuth
            & $restoreConfig
        }
        else {
            & $restoreConfig
            & $restoreAuth
        }

        $restoredConfig = [byte[]]::new(0)
        if([IO.File]::Exists($ConfigPath)){$restoredConfig = [IO.File]::ReadAllBytes($ConfigPath)}
        try {
            if ((Get-Sha256Hex $restoredConfig) -ne $journal.ConfigHash) {
                throw "恢复后的 config.toml 哈希不匹配。"
            }
        }
        finally {
            [Array]::Clear($restoredConfig, 0, $restoredConfig.Length)
        }

        if ($journal.AuthExisted) {
            $restoredAuth = [IO.File]::ReadAllBytes($AuthPath)
            try {
                if ((Get-Sha256Hex $restoredAuth) -ne $journal.AuthHash) {
                    throw "恢复后的 auth.json 哈希不匹配。"
                }
            }
            finally {
                [Array]::Clear($restoredAuth, 0, $restoredAuth.Length)
            }
        }

        Complete-Transaction
    }
    finally {
        if ($null -ne $currentConfigBytes) {
            [Array]::Clear($currentConfigBytes, 0, $currentConfigBytes.Length)
        }
        if ($null -ne $currentAuthBytes) {
            [Array]::Clear($currentAuthBytes, 0, $currentAuthBytes.Length)
        }
        [Array]::Clear($journal.ConfigBytes, 0, $journal.ConfigBytes.Length)
        [Array]::Clear($journal.AuthBytes, 0, $journal.AuthBytes.Length)
    }
}

function Read-State {
    param([switch]$AllowUnsigned)

    $raw = $null
    $stateProtectedBytes = $null
    $statePlainBytes = $null
    try {
        if ([IO.File]::Exists($StatePath)) {
            $stateProtectedBytes = [IO.File]::ReadAllBytes($StatePath)
            $statePlainBytes = Unprotect-BytesForCurrentUser $stateProtectedBytes
            $raw = $script:Utf8NoBom.GetString($statePlainBytes)
        }
        elseif ([IO.File]::Exists($LegacyStatePath)) {
            $raw = Read-TextFile $LegacyStatePath
            if ([IO.File]::Exists($LegacyStateProofPath)) {
                $legacyRawBytes = $script:Utf8NoBom.GetBytes($raw)
                $legacyProofBytes = [IO.File]::ReadAllBytes($LegacyStateProofPath)
                $legacyProofPlainBytes = $null
                try {
                    $legacyProofPlainBytes = Unprotect-BytesForCurrentUser $legacyProofBytes
                    if ((Get-Sha256Hex $legacyProofPlainBytes) -ne (Get-Sha256Hex $legacyRawBytes)) {
                        throw "旧版切换器状态完整性验证失败。"
                    }
                }
                finally {
                    [Array]::Clear($legacyRawBytes, 0, $legacyRawBytes.Length)
                    [Array]::Clear($legacyProofBytes, 0, $legacyProofBytes.Length)
                    if ($null -ne $legacyProofPlainBytes) {
                        [Array]::Clear($legacyProofPlainBytes, 0, $legacyProofPlainBytes.Length)
                    }
                }
            }
            elseif (-not $AllowUnsigned) {
                throw "旧版切换器状态缺少完整性证明。请运行 init 安全迁移。"
            }
        }
        else {
            return $null
        }
    }
    finally {
        if ($null -ne $stateProtectedBytes) {
            [Array]::Clear($stateProtectedBytes, 0, $stateProtectedBytes.Length)
        }
        if ($null -ne $statePlainBytes) {
            [Array]::Clear($statePlainBytes, 0, $statePlainBytes.Length)
        }
    }

    $parsed = $raw | ConvertFrom-Json
    $version = [int](Get-JsonPropertyValue -Object $parsed -Name "version")
    $storedCodexHome = [string](Get-JsonPropertyValue -Object $parsed -Name "codex_home")
    if ($version -ne 1) {
        throw "不支持此版本的切换器状态：$version"
    }
    if ((Resolve-NormalizedPath $storedCodexHome) -ne $CodexHome) {
        throw "此数据目录属于另一个 CODEX_HOME：$storedCodexHome"
    }

    $relayBaseUrl = [string](Get-JsonPropertyValue -Object $parsed -Name "relay_base_url")
    if (-not [string]::IsNullOrWhiteSpace($relayBaseUrl)) {
        Assert-RelayBaseUrl $relayBaseUrl
    }

    return [ordered]@{
        version = 1
        codex_home = $storedCodexHome
        relay_base_url = $relayBaseUrl
        active_api_profile_id = [string](Get-JsonPropertyValue -Object $parsed -Name "active_api_profile_id")
        active_official_profile_id = [string](Get-JsonPropertyValue -Object $parsed -Name "active_official_profile_id")
        created_utc = [string](Get-JsonPropertyValue -Object $parsed -Name "created_utc")
        updated_utc = [string](Get-JsonPropertyValue -Object $parsed -Name "updated_utc")
    }
}

function Write-State {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$State)

    $State["updated_utc"] = [DateTime]::UtcNow.ToString("o")
    $json = $State | ConvertTo-Json -Depth 5
    $stateText = $json + "`n"
    $stateBytes = $script:Utf8NoBom.GetBytes($stateText)
    $protectedStateBytes = $null
    try {
        $protectedStateBytes = Protect-BytesForCurrentUser $stateBytes
        Write-AtomicBytes -Path $StatePath -Bytes $protectedStateBytes

        $writtenProtectedState = [IO.File]::ReadAllBytes($StatePath)
        $writtenPlain = $null
        try {
            $writtenPlain = Unprotect-BytesForCurrentUser $writtenProtectedState
            if ((Get-Sha256Hex $writtenPlain) -ne (Get-Sha256Hex $stateBytes)) {
                throw "加密的切换器状态验证失败。"
            }
        }
        finally {
            [Array]::Clear($writtenProtectedState, 0, $writtenProtectedState.Length)
            if ($null -ne $writtenPlain) {
                [Array]::Clear($writtenPlain, 0, $writtenPlain.Length)
            }
        }

        if ([IO.File]::Exists($LegacyStatePath)) {
            [IO.File]::Delete($LegacyStatePath)
        }
        if ([IO.File]::Exists($LegacyStateProofPath)) {
            [IO.File]::Delete($LegacyStateProofPath)
        }
    }
    finally {
        [Array]::Clear($stateBytes, 0, $stateBytes.Length)
        if ($null -ne $protectedStateBytes) {
            [Array]::Clear($protectedStateBytes, 0, $protectedStateBytes.Length)
        }
    }
}

function Require-State {
    $state = Read-State
    if ($null -eq $state) {
        throw "切换器尚未初始化。请运行：codex-switcher.cmd init"
    }
    return $state
}

function Resolve-CodexCommand {
    if (-not [string]::IsNullOrWhiteSpace($CodexExecutable)) {
        $candidate = [Environment]::ExpandEnvironmentVariables($CodexExecutable)
        if (-not [IO.File]::Exists($candidate)) {
            throw "Codex 可执行文件不存在：$candidate"
        }
        return [IO.Path]::GetFullPath($candidate)
    }

    if (-not [string]::IsNullOrWhiteSpace($script:ResolvedCodexCommand) -and
        [IO.File]::Exists($script:ResolvedCodexCommand)) {
        return $script:ResolvedCodexCommand
    }

    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_CLI_PATH) -and [IO.File]::Exists($env:CODEX_CLI_PATH)) {
        $script:ResolvedCodexCommand = [IO.Path]::GetFullPath($env:CODEX_CLI_PATH)
        return $script:ResolvedCodexCommand
    }

    # Codex Desktop installs its own CLI under LOCALAPPDATA. Prefer that
    # current build over an older codex.exe that may still be first in PATH.
    $desktopBinRoot = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin"
    if ([IO.Directory]::Exists($desktopBinRoot)) {
        $desktopCandidates = @(
            [IO.Directory]::EnumerateDirectories($desktopBinRoot) |
                ForEach-Object { Join-Path $_ "codex.exe" } |
                Where-Object { [IO.File]::Exists($_) } |
                ForEach-Object { New-Object -TypeName IO.FileInfo -ArgumentList $_ } |
                Sort-Object LastWriteTimeUtc -Descending
        )
        if ($desktopCandidates.Count -gt 0) {
            $script:ResolvedCodexCommand = $desktopCandidates[0].FullName
            return $script:ResolvedCodexCommand
        }
    }

    $commandInfo = Get-Command codex -ErrorAction SilentlyContinue
    if ($null -eq $commandInfo) {
        throw "在 PATH 中找不到 codex 可执行文件。"
    }
    $script:ResolvedCodexCommand = [IO.Path]::GetFullPath($commandInfo.Source)
    return $script:ResolvedCodexCommand
}

function Save-CodexEnvironment {
    $names = @("CODEX_HOME", "OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_ACCESS_TOKEN")
    $saved = @{}
    foreach ($name in $names) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    }
    return $saved
}

function Set-CleanCodexEnvironment {
    [Environment]::SetEnvironmentVariable("CODEX_HOME", $CodexHome, "Process")
    [Environment]::SetEnvironmentVariable("OPENAI_API_KEY", $null, "Process")
    [Environment]::SetEnvironmentVariable("OPENAI_BASE_URL", $null, "Process")
    [Environment]::SetEnvironmentVariable("CODEX_ACCESS_TOKEN", $null, "Process")
}

function Restore-CodexEnvironment {
    param([Parameter(Mandatory = $true)][hashtable]$Saved)

    foreach ($entry in $Saved.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable([string]$entry.Key, $entry.Value, "Process")
    }
}

function Invoke-CodexLogin {
    $executable = Resolve-CodexCommand
    $savedEnvironment = Save-CodexEnvironment
    try {
        Set-CleanCodexEnvironment
        & $executable login
        if ($LASTEXITCODE -ne 0) {
            throw "codex login 已退出，退出码为 $LASTEXITCODE。"
        }
    }
    finally {
        Restore-CodexEnvironment $savedEnvironment
    }
}

function Get-DefaultCodexConfigText {
    return @"
model_provider = "openai"
cli_auth_credentials_store = "file"
"@
}

function Convert-SecureStringToPlainText {
    param([Parameter(Mandatory = $true)][Security.SecureString]$SecureString)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    }
}

function Invoke-FirstUseSetup {
    Assert-NoExternalAuthOverrides
    Assert-CodexProcessesStopped
    [IO.Directory]::CreateDirectory($CodexHome) | Out-Null
    $configExisted = [IO.File]::Exists($ConfigPath)
    $baseConfig = if ($configExisted) { Read-TextFile $ConfigPath } else { Get-DefaultCodexConfigText }
    # Selecting initial setup explicitly opts into file-based authentication;
    # no keyring entry is read or deleted, and failure restores the config.
    $baseConfig = Set-TopLevelTomlString -Text $baseConfig -Key 'cli_auth_credentials_store' -Value 'file'
    Assert-SupportedConfig $baseConfig
    $choice = (Read-SwitcherPrompt 'kind' '首次使用请选择认证类型：official=官方 OAuth，api=中转 API').Trim().ToLowerInvariant()
    if ($choice -notin @('official', 'api')) { throw '首次使用请选择 official 或 api。' }
    try {
        if ($choice -eq 'official') {
            $officialConfig = New-ModeConfigText -CurrentText $baseConfig -Mode official -ProfileEntry $script:OperationInput
            Write-TransactionJournal -SourceMode uninitialized -TargetMode official -TargetConfigText $officialConfig
            Write-AtomicText -Path $ConfigPath -Text $officialConfig
            if([IO.File]::Exists($AuthPath)){[IO.File]::Delete($AuthPath)}
            Invoke-CodexLogin
            $officialAuth = Read-AuthText
            if ((Get-AuthInfoFromText $officialAuth).Kind -ne 'official') { throw '首次 OAuth 登录没有返回官方认证。' }
            [void](Test-CodexLoginStatus -ExpectedKind official)
            Invoke-HistoryCompatibilityPreflight
            $state = [ordered]@{ version = 1; codex_home = $CodexHome; relay_base_url = ''; active_api_profile_id = ''; active_official_profile_id = ''; created_utc = [DateTime]::UtcNow.ToString('o'); updated_utc = [DateTime]::UtcNow.ToString('o') }
            $profileResult = Save-OfficialProfile -AuthText $officialAuth -Name (Read-SwitcherPrompt 'name' '给这个官方账号起个名称（可留空）') -SetActive
            $state.active_official_profile_id = [string](Get-ProfileField $profileResult.Entry 'id')
            $script:LastSavedProfileId = $state.active_official_profile_id
            Save-InitialSetupState $state $officialAuth official
            Complete-Transaction
            Write-Host '首次官方 OAuth 初始化完成。'
        }
        else {
            $baseUrl = (Read-SwitcherPrompt 'base_url' '请输入中转 API 的 HTTPS 地址').Trim()
            Assert-RelayBaseUrl $baseUrl
            $plainKey = Read-SwitcherPrompt 'api_key' '请输入 API Key（输入内容不会回显）' -Secret
            try {
                if ([string]::IsNullOrWhiteSpace($plainKey)) { throw 'API Key 不能为空。' }
                $apiAuth = ([ordered]@{ OPENAI_API_KEY = $plainKey } | ConvertTo-Json -Compress)
            }
            finally { $plainKey = $null }
            $setupArguments=@{CurrentText=$baseConfig;Mode='api';RelayBaseUrl=$baseUrl;ProfileEntry=$script:OperationInput}
            $catalog=[string](Get-ProfileField $script:OperationInput 'model_catalog_json')
            if($catalog){$setupArguments['ModelCatalogPathOverride']=$catalog}
            $apiConfig = New-ModeConfigText @setupArguments
            Write-TransactionJournal -SourceMode uninitialized -TargetMode api -TargetConfigText $apiConfig -TargetAuthText ($apiAuth + [Environment]::NewLine)
            Write-AtomicText -Path $ConfigPath -Text $apiConfig
            Write-AtomicText -Path $AuthPath -Text ($apiAuth + [Environment]::NewLine)
            [void](Test-CodexLoginStatus -ExpectedKind api)
            Invoke-HistoryCompatibilityPreflight
            $state = [ordered]@{ version = 1; codex_home = $CodexHome; relay_base_url = $baseUrl; active_api_profile_id = ''; active_official_profile_id = ''; created_utc = [DateTime]::UtcNow.ToString('o'); updated_utc = [DateTime]::UtcNow.ToString('o') }
            $profileResult = Save-ApiProfile -AuthText ($apiAuth + [Environment]::NewLine) -BaseUrl $baseUrl -ModelCatalogPath $catalog -Name (Read-SwitcherPrompt 'name' '给这个中转 API 起个名称（可留空）') -SetActive
            $state.active_api_profile_id = [string](Get-ProfileField $profileResult.Entry 'id')
            $script:LastSavedProfileId = $state.active_api_profile_id
            Save-InitialSetupState $state ($apiAuth + [Environment]::NewLine) api
            Complete-Transaction
            Write-Host '首次中转 API 初始化完成。'
        }
    }
    catch {
        Restore-ProfileTransaction
        if([IO.File]::Exists($TransactionPath)){Restore-Transaction}
        throw
    }
}

function Test-CodexLoginStatus {
    param([Parameter(Mandatory = $true)][ValidateSet("official", "api")][string]$ExpectedKind)

    $executable = Resolve-CodexCommand
    $savedEnvironment = Save-CodexEnvironment
    try {
        Set-CleanCodexEnvironment
        # Windows PowerShell 5.1 promotes native stderr records to terminating
        # errors under Stop, even when codex login status succeeds. Keep that
        # output captured so the exit code and authentication kind decide.
        $statusOutput = @(& {
            $ErrorActionPreference = 'Continue'
            & $executable login status 2>&1
        })
        $statusExitCode = $LASTEXITCODE
        if ($statusExitCode -ne 0) {
            throw "codex login status 执行失败；为避免泄露认证片段，已隐藏其输出。"
        }

        $statusText = ($statusOutput -join [Environment]::NewLine)
        $matchedKind = if ($statusText -match '(?i)ChatGPT') {
            "official"
        }
        elseif ($statusText -match '(?i)API key') {
            "api"
        }
        else {
            "unknown"
        }
        if ($matchedKind -ne $ExpectedKind) {
            throw "codex login status 未确认预期的 '$ExpectedKind' 认证；为避免泄露认证片段，已隐藏其输出。"
        }
        return $true
    }
    finally {
        Restore-CodexEnvironment $savedEnvironment
    }
}

function Assert-NoExternalAuthOverrides {
    $overrides = New-Object System.Collections.Generic.List[string]
    foreach ($name in @("OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_ACCESS_TOKEN")) {
        if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($name, "Process"))) {
            $overrides.Add($name)
        }
    }
    if ($overrides.Count -gt 0) {
        throw "切换前请清除以下进程环境变量覆盖：$($overrides -join ', ')"
    }
}

function Get-CodexRunningProcesses {
    try {
        return @(
            Get-CimInstance Win32_Process -Filter "Name='codex.exe' OR Name='codex-code-mode-host.exe' OR Name='ChatGPT.exe'" -ErrorAction Stop | Where-Object {
                if ($_.Name -ieq "codex.exe" -or $_.Name -ieq "codex-code-mode-host.exe") {
                    return $true
                }
                if ($_.Name -ieq "ChatGPT.exe") {
                    # The merged Windows app uses ChatGPT.exe, but its command line
                    # no longer contains the package name used by older releases.
                    return (
                        ([string]$_.ExecutablePath -match '\\WindowsApps\\OpenAI\.Codex_[^\\]+\\') -or
                        ([string]$_.CommandLine -match '(?i)\\Codex\\web\\Codex(?:[\\" ]|$)')
                    )
                }
                return $false
            }
        )
    }
    catch {
        return @(
            Get-Process -Name codex, codex-code-mode-host, ChatGPT -ErrorAction SilentlyContinue |
                ForEach-Object {
                    [pscustomobject]@{ ProcessId = $_.Id; Name = $_.ProcessName }
                }
        )
    }
}

function Assert-CodexProcessesStopped {
    if ($UnsafeAllowRunningCodex) {
        Write-Warning "已启用不安全测试开关：运行中的 Codex 进程可能与认证或配置替换发生冲突。"
        return
    }

    $busyProcesses = @(Get-CodexRunningProcesses)

    if ($busyProcesses.Count -gt 0) {
        $summary = ($busyProcesses | ForEach-Object { "$($_.Name):$($_.ProcessId)" }) -join ", "
        throw "请先关闭 Codex Desktop 和全部 Codex CLI 进程。仍在运行：$summary"
    }
}

function Invoke-ProjectProjectionRepair {
    param(
        [switch]$ReadOnly,
        [switch]$SkipProcessGate
    )

    if (-not [IO.File]::Exists($ProjectProjectionScript)) {
        throw "缺少项目归属投影处理脚本：$ProjectProjectionScript"
    }
    if (-not [IO.File]::Exists((Join-Path $CodexHome "state_5.sqlite"))) {
        Write-Host "项目归属投影：当前 CODEX_HOME 没有 state_5.sqlite，跳过。"
        return
    }

    $hostCommand = Get-Command "pwsh" -ErrorAction SilentlyContinue
    if ($null -eq $hostCommand) {
        $hostCommand = Get-Command "powershell" -ErrorAction Stop
    }
    $projectionCommand = if ($ReadOnly) { "scan" } else { "repair" }
    $arguments = @(
        "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $ProjectProjectionScript,
        "-Command", $projectionCommand,
        "-CodexHome", $CodexHome,
        "-BackupRoot", $ProjectProjectionBackupRoot
    )
    # Read the configured account's inactive metadata directly. Do not rewrite
    # all Desktop state merely to make the project preflight see that metadata.
    $authText = if ([IO.File]::Exists($AuthPath)) { Read-AuthText } else { $null }
    $officialAuth = if ($null -ne $authText -and (Get-AuthInfoFromText $authText).Kind -eq 'official') { $authText } elseif ([IO.File]::Exists($OfficialAuthPath)) { Unprotect-AuthSnapshot -Path $OfficialAuthPath -ExpectedKind official } else { $null }
    $owner = Get-DesktopAuthOwner $officialAuth
    if ($null -ne $owner) {
        $arguments += @('-DesktopOwner', $owner, '-RendererArchivePath', (Join-Path $DataDir 'desktop-renderer-state.dpapi'))
    }
    # The switcher already passed its process gate. Direct project-repair use
    # keeps the helper's independent gate unless the caller explicitly says
    # the outer gate has already run.
    if ($SkipProcessGate) { $arguments += "-SkipProcessGate" }
    $output = @(& $hostCommand.Source @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "项目归属投影处理失败：$($output -join ' | ')"
    }
    foreach ($line in $output) {
        Write-Host ([string]$line)
    }
}

function Invoke-DesktopStateCompatibility {
    param([switch]$ReadOnly)
    $currentConfig = Read-TextFile $ConfigPath
    $currentAuth = Read-AuthText
    $mode = Get-LiveMode -ConfigText $currentConfig -AuthText $currentAuth
    if (-not $ReadOnly) {
        Assert-CodexProcessesStopped
        $state = Require-State
        Invoke-ProjectProjectionPreflight
        [void](Capture-CurrentCredentials $state)
        $repairRelayBaseUrl = if ($mode -eq 'api') { [string](Get-TopLevelTomlValue -Text $currentConfig -Key 'openai_base_url') } else { $null }
        $repairCatalogPath = if ($mode -eq 'api') { [string](Get-TopLevelTomlValue -Text $currentConfig -Key 'model_catalog_json') } else { $null }
        Invoke-ModeSwap -Mode $mode -TargetAuthText $currentAuth -State $state -RelayBaseUrl $repairRelayBaseUrl -ModelCatalogPath $repairCatalogPath
        Write-Host '桌面状态修复完成，认证模式保持原样。请重新启动 Codex Desktop。'
        return
    }
    $officialAuth = if ($mode -eq 'official') { $currentAuth } elseif ([IO.File]::Exists($OfficialAuthPath)) { Unprotect-AuthSnapshot -Path $OfficialAuthPath -ExpectedKind official } else { $null }
    $plan = New-DesktopStatePlan -TargetMode $mode -SourceAuthText $currentAuth -TargetAuthText $currentAuth -OfficialAuthText $officialAuth
    Write-Host ("桌面状态只读检查：可恢复/保留 {0} 个本地项目；欢迎流程计划为完成/跳过：{1}；存在旧账号状态封套：{2}；待写入文件 {3} 个。" -f $plan.ProjectCount, $plan.CompletedWelcome, $plan.EnvelopeRemoved, $plan.Files.Count)
}

function Invoke-ProjectProjectionPreflight {
    if ($script:ProjectProjectionPreflightComplete) { return }
    # Run before history readiness is measured: a real metadata repair changes
    # the SQLite fingerprint. Ordinary switching never infers membership from CWD.
    Invoke-ProjectProjectionRepair -SkipProcessGate
    $script:ProjectProjectionPreflightComplete = $true
}

function Invoke-HistoryCompatibilityScan {
    if (-not [IO.File]::Exists($HistoryCompatibilityScript)) {
        throw "缺少对话兼容处理脚本：$HistoryCompatibilityScript"
    }
    & $HistoryCompatibilityScript `
        -Command scan `
        -CodexHome $CodexHome `
        -BackupRoot $HistoryBackupRoot `
        -PortableInputIds
}

function Invoke-HistoryCompatibilityRepair {
    param([switch]$FullScan)
    $script:OperationStage = "history-prepare"
    if (-not [IO.File]::Exists($HistoryCompatibilityScript)) {
        throw "缺少对话兼容处理脚本：$HistoryCompatibilityScript"
    }
    $result = & $HistoryCompatibilityScript `
        -Command repair `
        -CodexHome $CodexHome `
        -BackupRoot $HistoryBackupRoot `
        -PortableInputIds -Incremental:(-not $FullScan)
    return $result
}

function Get-HistoryInventory {
    $entries = New-Object System.Collections.Generic.List[string]
    $databaseEntries = New-Object System.Collections.Generic.List[string]
    $databasePaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [long]$totalBytes = 0
    foreach ($folderName in @("sessions", "archived_sessions")) {
        $folder = Join-Path $CodexHome $folderName
        if (-not [IO.Directory]::Exists($folder)) {
            continue
        }
        foreach ($path in [IO.Directory]::EnumerateFiles($folder, "*.jsonl", [IO.SearchOption]::AllDirectories)) {
            $fullPath = [IO.Path]::GetFullPath($path)
            $relativePath = $fullPath.Substring($CodexHome.Length).TrimStart([char[]]@('\', '/'))
            $info = New-Object IO.FileInfo($fullPath)
            $totalBytes += $info.Length
            $entries.Add(("{0}|{1}|{2}" -f $relativePath, $info.Length, $info.LastWriteTimeUtc.Ticks))
        }
    }

    # The paginated projection and provider state databases are part of the
    # compatibility transaction. Include their metadata in the readiness
    # fingerprint so a database change cannot silently reuse an old stamp.
    foreach ($folder in @($CodexHome, (Join-Path $CodexHome "sqlite"))) {
        if (-not [IO.Directory]::Exists($folder)) {
            continue
        }
        foreach ($database in [IO.Directory]::EnumerateFiles($folder, "*.sqlite", [IO.SearchOption]::TopDirectoryOnly)) {
            # Classify by schema, not a fixed filename/version list. Logs,
            # memories and unrelated caches must not invalidate history readiness.
            $sqlite = Get-Command sqlite3.exe -ErrorAction SilentlyContinue
            if ($null -eq $sqlite) { $sqlite = Get-Command sqlite3 -ErrorAction SilentlyContinue }
            if ($null -eq $sqlite) { throw "检查历史状态库需要 sqlite3。" }
            $databaseArgument = ([Uri][IO.Path]::GetFullPath($database)).AbsoluteUri
            $schema = @(& $sqlite.Source -readonly -batch -noheader -cmd '.timeout 5000' $databaseArgument "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('threads','thread_items','thread_turns','thread_history_projection_state');" 2>&1)
            if ($LASTEXITCODE -ne 0 -or $schema.Count -ne 1 -or [string]$schema[0] -notmatch '^\d+$') {
                throw "无法检查历史数据库结构；不复用准备记录：$database"
            }
            if ([int]$schema[0] -eq 0) { continue }
            foreach ($path in @($database, ($database + '-wal'))) {
                if (-not [IO.File]::Exists($path)) { continue }
                # The WAL is durable database state and must be fingerprinted.
                # The -shm file is an SQLite coordination cache whose timestamp
                # can change merely by opening the database read-only.
                $fullPath = [IO.Path]::GetFullPath($path)
                if (-not $databasePaths.Add($fullPath)) {
                    continue
                }
                $relativePath = $fullPath.Substring($CodexHome.Length).TrimStart([char[]]@('\', '/'))
                $info = New-Object IO.FileInfo($fullPath)
                $databaseEntries.Add(("{0}|{1}|{2}" -f $relativePath, $info.Length, $info.LastWriteTimeUtc.Ticks))
            }
        }
    }

    $sorted = $entries.ToArray()
    [Array]::Sort($sorted, [StringComparer]::OrdinalIgnoreCase)
    $payload = [string]::Join("`n", $sorted)
    $bytes = $script:Utf8NoBom.GetBytes($payload)
    try {
        $fingerprint = Get-Sha256Hex $bytes
    }
    finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
    $sortedDatabaseEntries = $databaseEntries.ToArray()
    [Array]::Sort($sortedDatabaseEntries, [StringComparer]::OrdinalIgnoreCase)
    $databasePayload = [string]::Join("`n", $sortedDatabaseEntries)
    $databaseBytes = $script:Utf8NoBom.GetBytes($databasePayload)
    try {
        $databaseFingerprint = Get-Sha256Hex $databaseBytes
    }
    finally {
        [Array]::Clear($databaseBytes, 0, $databaseBytes.Length)
    }
    [long]$databaseTotalBytes = 0
    foreach ($entry in $sortedDatabaseEntries) {
        $parts = $entry.Split([char[]]@('|'), 3)
        if ($parts.Count -eq 3) {
            $databaseTotalBytes += [long]$parts[1]
        }
    }
    # Avoid module autoload dependencies when PS 5.1 is launched from PS 7.
    $rulesSource = [IO.File]::ReadAllText($HistoryCompatibilityScript) + "`n" +
        [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'CodexPortableHistory.cs')) + "`n" +
        [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'codex-history-incremental.ps1'))
    $rulesBytes = $script:Utf8NoBom.GetBytes($rulesSource)
    try { $rulesFingerprint = Get-Sha256Hex $rulesBytes }
    finally { [Array]::Clear($rulesBytes, 0, $rulesBytes.Length) }
    return [pscustomobject]@{
        Fingerprint = $fingerprint
        FileCount = $sorted.Length
        TotalBytes = $totalBytes
        DatabaseFingerprint = $databaseFingerprint
        DatabaseCount = $sortedDatabaseEntries.Length
        DatabaseTotalBytes = $databaseTotalBytes
        RulesFingerprint = $rulesFingerprint
    }
}

function Save-HistoryCompatibilityStamp {
    $inventory = Get-HistoryInventory
    $stamp = [ordered]@{
        version = 3
        codex_home = $CodexHome
        provider_target = "openai"
        inventory_scope = "history-schema-v1"
        rules_fingerprint = $inventory.RulesFingerprint
        fingerprint = $inventory.Fingerprint
        file_count = $inventory.FileCount
        total_bytes = $inventory.TotalBytes
        database_fingerprint = $inventory.DatabaseFingerprint
        database_count = $inventory.DatabaseCount
        database_total_bytes = $inventory.DatabaseTotalBytes
        prepared_utc = [DateTime]::UtcNow.ToString("o")
        incremental_cache_sha256 = Get-Sha256Hex ([IO.File]::ReadAllBytes((Join-Path $HistoryBackupRoot 'incremental-cache.json')))
    }
    Write-AtomicText -Path $HistoryReadyPath -Text (($stamp | ConvertTo-Json -Depth 4) + [Environment]::NewLine)
    return $inventory
}

function Get-HistoryCompatibilityStatus {
    $inventory = Get-HistoryInventory
    if ([IO.File]::Exists((Join-Path $HistoryBackupRoot 'active-transaction.json'))) {
        return [pscustomobject]@{ Ready=$false;Reason='上次历史事务尚未完成，需要恢复';Inventory=$inventory }
    }
    if ($inventory.FileCount -eq 0) {
        return [pscustomobject]@{ Ready = $true; Reason = "没有本地对话文件"; Inventory = $inventory }
    }
    if (-not [IO.File]::Exists($HistoryReadyPath)) {
        return [pscustomobject]@{ Ready = $false; Reason = "尚未执行兼容准备"; Inventory = $inventory }
    }

    try {
        $stamp = Read-TextFile $HistoryReadyPath | ConvertFrom-Json
    }
    catch {
        return [pscustomobject]@{ Ready = $false; Reason = "兼容准备记录无法读取"; Inventory = $inventory }
    }

    if ([int](Get-JsonPropertyValue -Object $stamp -Name "version") -ne 3 -or
        [string](Get-JsonPropertyValue -Object $stamp -Name "provider_target") -cne "openai") {
        return [pscustomobject]@{ Ready = $false; Reason = "兼容准备记录版本不受支持"; Inventory = $inventory }
    }
    if ([string](Get-JsonPropertyValue -Object $stamp -Name "codex_home") -cne $CodexHome) {
        return [pscustomobject]@{ Ready = $false; Reason = "兼容准备记录属于其他 CODEX_HOME"; Inventory = $inventory }
    }
    if ([string](Get-JsonPropertyValue $stamp "inventory_scope") -cne "history-schema-v1" -or
        [string](Get-JsonPropertyValue $stamp "rules_fingerprint") -cne $inventory.RulesFingerprint) {
        return [pscustomobject]@{ Ready = $false; Reason = "兼容检查规则已更新，需要重新准备"; Inventory = $inventory }
    }
    $stampDatabaseFingerprint = Get-JsonPropertyValue -Object $stamp -Name "database_fingerprint"
    $stampDatabaseCount = Get-JsonPropertyValue -Object $stamp -Name "database_count"
    $stampDatabaseTotalBytes = Get-JsonPropertyValue -Object $stamp -Name "database_total_bytes"
    if ($null -eq $stampDatabaseFingerprint -or $null -eq $stampDatabaseCount -or $null -eq $stampDatabaseTotalBytes) {
        return [pscustomobject]@{ Ready = $false; Reason = "兼容准备记录缺少数据库指纹，请重新执行 history-prepare"; Inventory = $inventory }
    }
    if ([string](Get-JsonPropertyValue -Object $stamp -Name "fingerprint") -cne $inventory.Fingerprint -or
        [int](Get-JsonPropertyValue -Object $stamp -Name "file_count") -ne $inventory.FileCount -or
        [long](Get-JsonPropertyValue -Object $stamp -Name "total_bytes") -ne $inventory.TotalBytes -or
        [string]$stampDatabaseFingerprint -cne [string]$inventory.DatabaseFingerprint -or
        [int](Get-JsonPropertyValue -Object $stamp -Name "database_count") -ne $inventory.DatabaseCount -or
        [long](Get-JsonPropertyValue -Object $stamp -Name "database_total_bytes") -ne $inventory.DatabaseTotalBytes) {
        return [pscustomobject]@{ Ready = $false; Reason = "上次准备后对话历史发生了变化"; Inventory = $inventory }
    }
    $cachePath=Join-Path $HistoryBackupRoot 'incremental-cache.json'
    $cacheHash=[string](Get-JsonPropertyValue $stamp 'incremental_cache_sha256')
    if (-not [IO.File]::Exists($cachePath) -or [string]::IsNullOrWhiteSpace($cacheHash) -or
        (Get-Sha256Hex ([IO.File]::ReadAllBytes($cachePath))) -cne $cacheHash) {
        return [pscustomobject]@{Ready=$false;Reason='逐文件检查记录变化或缺失，需要重新准备';Inventory=$inventory}
    }
    return [pscustomobject]@{ Ready = $true; Reason = "已准备且历史未变化"; Inventory = $inventory }
}

function Invoke-HistoryCompatibilityPreflight {
    # Every normal setup/switch uses the same shared-history contract,
    # including official -> API and switches within the same auth kind.
    $parentStage = $script:OperationStage
    Initialize-WindowsSqlite
    Invoke-ProjectProjectionPreflight
    $status = Get-HistoryCompatibilityStatus
    if ($status.Ready -and -not $FullHistoryScan) {
        Write-Host "对话兼容状态：$($status.Reason)（$($status.Inventory.FileCount) 个文件），跳过完整扫描。"
        return
    }
    if ($FullHistoryScan) { Write-Host '已指定全量检查，正在执行停机准备。' }
    else { Write-Host "对话兼容状态：$($status.Reason)；正在自动执行停机准备（增量核验，仅有不兼容内容时改写）。" }
    Invoke-HistoryCompatibilityPrepare | Out-Null
    # A subsequent login failure belongs to the switch, not the finished repair.
    $script:OperationStage = $parentStage
}

function Invoke-HistoryCompatibilityPrepare {
    param([switch]$FullScan)
    $prepareTimer = [Diagnostics.Stopwatch]::StartNew()
    $result = Invoke-HistoryCompatibilityRepair -FullScan:($FullScan -or $FullHistoryScan)
    $script:LatestHistoryMetrics = [ordered]@{total_seconds=$prepareTimer.Elapsed.TotalSeconds;scan=$result.ScanMetrics;phases=$result.PhaseSeconds}
    $inventory = Save-HistoryCompatibilityStamp
    Write-Host ("本次历史检查：跳过 {0} 个旧文件，增量解析 {1} 个文件，完整解析 {2} 个文件，解析 {3:N2} MiB；旧前缀字节核对 {4:N2} MiB。" -f
        $result.ScanMetrics.SkippedFiles,$result.ScanMetrics.TailFiles,$result.ScanMetrics.FullFiles,($result.ScanMetrics.ParsedBytes/1MB),($result.ScanMetrics.PrefixVerifiedBytes/1MB))
    Write-Host ("对话兼容准备完成：{0} 个文件，耗时 {1:N1} 秒；历史和检查规则未变化时，后续切换只做快速指纹校验。" -f $inventory.FileCount, $prepareTimer.Elapsed.TotalSeconds)
    Write-Host '本地对话 provider 已核对为 openai；包含归档和对应的 SQLite 线程记录。'
    return $result
}

function Assert-SupportedConfig {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$ConfigText)

    $isTopLevel = $true
    foreach ($line in [regex]::Split($ConfigText, "\r?\n")) {
        $withoutComment = Strip-TomlInlineComment $line
        $normalized = ($withoutComment -replace '\s', '' -replace '["'']', '')

        if ($isTopLevel) {
            $equalsIndex = $withoutComment.IndexOf("=")
            if ($equalsIndex -gt 0) {
                $rootValue = $withoutComment.Substring($equalsIndex + 1).Trim()
                if ($rootValue.Contains('"""') -or $rootValue.Contains("'''")) {
                    throw "切换器暂不支持顶层多行 TOML 字符串。"
                }
                if ($rootValue.StartsWith("[") -and -not $rootValue.EndsWith("]")) {
                    throw "切换器暂不支持顶层多行 TOML 数组。"
                }
                if ($rootValue.StartsWith("{") -and -not $rootValue.EndsWith("}")) {
                    throw "切换器暂不支持顶层多行 TOML 内联表。"
                }
            }
        }

        if ($withoutComment -match '^\s*\[') {
            if ($normalized -match '^\[{1,2}model_providers(?:\]|\.openai(?:\.|\]))') {
                throw "切换器不支持 [model_providers] 父表或 model_providers.openai 表。"
            }
            $isTopLevel = $false
            continue
        }

        if (-not $isTopLevel -or [string]::IsNullOrWhiteSpace($withoutComment)) {
            continue
        }

        if ($normalized -match '^(model_provider|openai_base_url|cli_auth_credentials_store)=' -and
            $withoutComment -notmatch '^\s*(model_provider|openai_base_url|cli_auth_credentials_store)\s*=') {
            throw "切换器管理的 TOML 字段必须使用未加引号的普通键：$withoutComment"
        }
        if ($normalized -match '^model_providers(?:=|\.openai)') {
            throw "切换器不支持顶层 model_providers 覆盖。"
        }
    }

    $provider = [string](Get-TopLevelTomlValue -Text $ConfigText -Key "model_provider")
    if (-not [string]::IsNullOrWhiteSpace($provider) -and $provider -ne "openai") {
        throw "顶层 model_provider 必须保持为 'openai'；实际为 '$provider'。"
    }
    $contextWindow = Get-TopLevelTomlValue -Text $ConfigText -Key "model_context_window"
    Assert-ContextWindow ([string]$contextWindow)
    $credentialStore = [string](Get-TopLevelTomlValue -Text $ConfigText -Key "cli_auth_credentials_store")
    if (-not [string]::IsNullOrWhiteSpace($credentialStore) -and $credentialStore -ne "file") {
        throw "认证快照要求 cli_auth_credentials_store = 'file'；实际为 '$credentialStore'。"
    }
}

function Assert-RelayBaseUrl {
    param([Parameter(Mandatory = $true)][string]$BaseUrl)

    $uri = $null
    if (-not [Uri]::TryCreate($BaseUrl, [UriKind]::Absolute, [ref]$uri)) {
        throw "中转 openai_base_url 必须是绝对地址。"
    }
    if ($uri.Scheme -ne "https") {
        throw "中转 openai_base_url 必须使用 HTTPS。"
    }
    if (-not [string]::IsNullOrWhiteSpace($uri.UserInfo)) {
        throw "中转 openai_base_url 不能包含账号或密钥。"
    }
    if (-not [string]::IsNullOrWhiteSpace($uri.Query) -or -not [string]::IsNullOrWhiteSpace($uri.Fragment)) {
        throw "中转 openai_base_url 不能包含查询参数或片段。"
    }
}

function Get-LiveMode {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ConfigText,
        [Parameter(Mandatory = $true)][string]$AuthText
    )

    Assert-SupportedConfig $ConfigText
    $authInfo = Get-AuthInfoFromText $AuthText
    $baseUrl = [string](Get-TopLevelTomlValue -Text $ConfigText -Key "openai_base_url")

    if ($authInfo.Kind -eq "api" -and -not [string]::IsNullOrWhiteSpace($baseUrl)) {
        Assert-RelayBaseUrl $baseUrl
        return "api"
    }
    if ($authInfo.Kind -eq "official" -and [string]::IsNullOrWhiteSpace($baseUrl)) {
        return "official"
    }
    throw "当前配置与认证不一致：认证='$($authInfo.Kind)'，是否存在中转地址='$(-not [string]::IsNullOrWhiteSpace($baseUrl))'。"
}

function Capture-CurrentCredentials {
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$State)

    $authText = Read-AuthText
    $authInfo = Get-AuthInfoFromText $authText
    $configText = Read-TextFile $ConfigPath
    $liveMode = Get-LiveMode -ConfigText $configText -AuthText $authText
    $baseUrl = [string](Get-TopLevelTomlValue -Text $configText -Key "openai_base_url")

    switch ($liveMode) {
        "api" {
            Assert-RelayBaseUrl $baseUrl
            $State["relay_base_url"] = $baseUrl
            [void](Test-CodexLoginStatus -ExpectedKind "api")
            Protect-AuthSnapshot -Text $authText -Path $RelayAuthPath -ExpectedKind "api"
            $catalogPath = [string](Get-TopLevelTomlValue -Text $configText -Key "model_catalog_json")
            $profileResult = Sync-CurrentAuthProfile -Kind api -AuthText $authText -BaseUrl $baseUrl -ModelCatalogPath $catalogPath
            $State["active_api_profile_id"] = [string](Get-ProfileField $profileResult.Entry 'id')
        }
        "official" {
            [void](Test-CodexLoginStatus -ExpectedKind "official")
            Protect-AuthSnapshot -Text $authText -Path $OfficialAuthPath -ExpectedKind "official"
            $profileResult = Sync-CurrentAuthProfile -Kind official -AuthText $authText
            $State["active_official_profile_id"] = [string](Get-ProfileField $profileResult.Entry 'id')
        }
        default {
            throw "当前 auth.json 的认证类型不受支持：$($authInfo.Kind)"
        }
    }

    Write-State $State
    return $authInfo.Kind
}

function Invoke-ModeSwap {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("official", "api")][string]$Mode,
        [Parameter(Mandatory = $true)][string]$TargetAuthText,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$State,
        [AllowNull()][string]$RelayBaseUrl,
        [AllowNull()][string]$ModelCatalogPath,
        [AllowNull()][string]$ProfileId
    )

    Assert-NoExternalAuthOverrides
    $currentConfig = Read-TextFile $ConfigPath
    Assert-SupportedConfig $currentConfig
    $currentAuth = Read-AuthText
    $sourceMode = Get-LiveMode -ConfigText $currentConfig -AuthText $currentAuth
    $swapRelayBaseUrl = if ($Mode -eq 'api' -and -not [string]::IsNullOrWhiteSpace($RelayBaseUrl)) { $RelayBaseUrl } else { [string]$State["relay_base_url"] }
    $configArguments = @{
        CurrentText = $currentConfig
        Mode = $Mode
        RelayBaseUrl = $swapRelayBaseUrl
    }
    if ($Mode -eq 'api' -and $PSBoundParameters.ContainsKey('ModelCatalogPath')) {
        $configArguments['ModelCatalogPathOverride'] = $ModelCatalogPath
    }
    if ($ProfileId) { $configArguments['ProfileEntry'] = Find-ProfileEntry (Read-ProfileRegistry) $Mode $ProfileId }
    $targetConfig = New-ModeConfigText @configArguments

    $officialAuthForState = if ($sourceMode -eq 'official') { $currentAuth } elseif ($Mode -eq 'official') { $TargetAuthText } elseif ([IO.File]::Exists($OfficialAuthPath)) { Unprotect-AuthSnapshot -Path $OfficialAuthPath -ExpectedKind official } else { $null }
    $desktopPlan = New-DesktopStatePlan -TargetMode $Mode -SourceAuthText $currentAuth -TargetAuthText $TargetAuthText -OfficialAuthText $officialAuthForState
    Backup-DesktopStatePlan $desktopPlan
    $profileFiles = @()
    if (-not [string]::IsNullOrWhiteSpace($ProfileId)) {
        $profilePlan = New-ProfileSelectionPlan -State $State -Kind $Mode -ProfileId $ProfileId
        $profileFiles = @($profilePlan.Files)
    }
    Write-TransactionJournal -SourceMode $sourceMode -TargetMode $Mode -TargetConfigText $targetConfig -TargetAuthText $TargetAuthText -ExtraFiles @(@($desktopPlan.Files) + $profileFiles)
    try {
        if ($Mode -eq "official") {
            Write-AtomicText -Path $ConfigPath -Text $targetConfig
            Write-AtomicText -Path $AuthPath -Text $TargetAuthText
        }
        else {
            Write-AtomicText -Path $AuthPath -Text $TargetAuthText
            Write-AtomicText -Path $ConfigPath -Text $targetConfig
        }

        $writtenInfo = Get-AuthInfoFromText (Read-AuthText)
        if ($writtenInfo.Kind -ne $Mode) {
            throw "认证验证预期为 '$Mode'，实际为 '$($writtenInfo.Kind)'。"
        }

        $writtenConfig = Read-TextFile $ConfigPath
        Assert-SupportedConfig $writtenConfig
        $writtenBaseUrl = [string](Get-TopLevelTomlValue -Text $writtenConfig -Key "openai_base_url")
        $writtenSystemProxy = [string](Get-TomlTableValue -Text $writtenConfig -Table "features" -Key "respect_system_proxy")
        if ($Mode -eq "official" -and -not [string]::IsNullOrWhiteSpace($writtenBaseUrl)) {
            throw "官方模式验证时仍发现中转地址。"
        }
        if ($Mode -eq "api" -and $writtenBaseUrl -ne $swapRelayBaseUrl) {
            throw "中转模式验证时发现中转地址不正确。"
        }
        $expectedSystemProxy = [string](Get-TomlTableValue -Text $targetConfig -Table 'features' -Key 'respect_system_proxy')
        if ($writtenSystemProxy -cne $expectedSystemProxy) {
            throw "模式切换后的系统代理设置不正确；预期为 $expectedSystemProxy，实际为 '$writtenSystemProxy'。"
        }

        [void](Test-CodexLoginStatus -ExpectedKind $Mode)
        foreach ($file in $desktopPlan.Files) { Write-AtomicBytes -Path $file.Path -Bytes $file.TargetBytes }
        foreach ($file in $profileFiles) { Write-AtomicBytes -Path $file.Path -Bytes $file.TargetBytes }
        if ($profileFiles.Count -gt 0) {
            $activeKey = if ($Mode -eq 'api') { 'active_api_profile_id' } else { 'active_official_profile_id' }
            if ([string](Get-ProfileField (Read-ProfileRegistry) $activeKey) -cne $ProfileId -or
                [string](Read-State)[$activeKey] -cne $ProfileId) { throw '切换后的活动配置档案校验失败。' }
        }
        Complete-Transaction
        if ($desktopPlan.Files.Count -gt 0) {
            Write-Host ("桌面状态兼容：已保留 {0} 个本地项目；已完成的欢迎流程：{1}。" -f $desktopPlan.ProjectCount, $desktopPlan.CompletedWelcome)
        }
    }
    catch {
        $switchError = $_
        try {
            Restore-Transaction
        }
        catch {
            throw "模式切换失败，并且回滚也失败。切换错误：$switchError；回滚错误：$_"
        }
        throw "模式切换失败，已经恢复配置、认证和桌面状态。$switchError"
    }
}

function Initialize-Switcher {
    Assert-CodexProcessesStopped

    if (-not [IO.File]::Exists($ConfigPath) -or -not [IO.File]::Exists($AuthPath)) {
        Write-Host '检测到首次使用或认证文件尚未创建，启动一次性设置向导。'
        Invoke-FirstUseSetup
        return
    }

    $configText = Read-TextFile $ConfigPath
    $credentialStore=[string](Get-TopLevelTomlValue $configText 'cli_auth_credentials_store')
    if($credentialStore -and $credentialStore -ne 'file' -and $null -eq (Read-State)){
        if($null -ne $script:OperationInput -and -not $script:OperationInput.Contains('kind')){
            throw '当前使用系统凭据库。请点击“添加账号”重新登录或填写 API；首次设置会启用文件认证，原系统凭据继续保留。'
        }
        Invoke-FirstUseSetup
        return
    }
    Assert-SupportedConfig $configText

    # Validate the live pairing before making any shared-history changes.
    [void](Get-LiveMode -ConfigText $configText -AuthText (Read-AuthText))
    Invoke-HistoryCompatibilityPreflight

    $existingState = Read-State -AllowUnsigned
    $now = [DateTime]::UtcNow.ToString("o")
    $state = if ($null -ne $existingState) {
        $existingState
    }
    else {
        [ordered]@{
            version = 1
            codex_home = $CodexHome
            relay_base_url = ""
            created_utc = $now
            updated_utc = $now
        }
    }

    [void](Ensure-ProfileRegistry $state)
    $kind = Capture-CurrentCredentials $state
    $kindLabel = if ($kind -eq "official") { "官方 OAuth" } else { "中转 API" }
    Write-Host "已根据当前的 $kindLabel 认证完成初始化。"
    Write-Host "本次没有修改正在使用的 Codex 配置或认证。"
}

function Add-ApiProfileInteractively {
    Assert-NoExternalAuthOverrides
    [void](Ensure-ProfileRegistry (Read-State))
    $name = (Read-SwitcherPrompt 'name' '中转 API 配置名称（可留空）').Trim()
    $baseUrl = (Read-SwitcherPrompt 'base_url' '中转 API 的 HTTPS 地址').Trim()
    Assert-RelayBaseUrl $baseUrl
    $catalog = (Read-SwitcherPrompt 'model_catalog_json' '模型目录 JSON 路径（可留空）').Trim()
    if (-not [string]::IsNullOrWhiteSpace($catalog)) {
        $catalog = Resolve-NormalizedPath $catalog
    }
    $plainKey = Read-SwitcherPrompt 'api_key' 'API Key（输入内容不会回显）' -Secret
    try {
        if ([string]::IsNullOrWhiteSpace($plainKey)) { throw 'API Key 不能为空。' }
        $authText = ([ordered]@{ OPENAI_API_KEY = $plainKey } | ConvertTo-Json -Compress) + [Environment]::NewLine
    }
    finally { $plainKey = $null }
    $saved = Save-ApiProfile -AuthText $authText -BaseUrl $baseUrl -ModelCatalogPath $catalog -Name $name
    $script:LastSavedProfileId = [string]$saved.Entry.id
    Write-Host "已登记中转 API 配置：$([string](Get-ProfileField $saved.Entry 'name'))。使用 profile-use-api -Profile '$([string](Get-ProfileField $saved.Entry 'name'))' 切换。"
}

function Add-OfficialProfileInteractively {
    param([AllowNull()][string]$ProfileDisplayName)
    Assert-NoExternalAuthOverrides
    Assert-CodexProcessesStopped
    [void](Ensure-ProfileRegistry (Read-State))
    $name = if ($ProfileDisplayName) { $ProfileDisplayName } else { (Read-SwitcherPrompt 'name' '官方账号名称（可留空）').Trim() }
    $configExisted = [IO.File]::Exists($ConfigPath)
    $authExisted = [IO.File]::Exists($AuthPath)
    if (-not $configExisted -or -not $authExisted) { throw '需要先完成首次设置，再添加官方账号。' }
    $currentConfig = Read-TextFile $ConfigPath
    $originalAuth = Read-AuthText
    $sourceMode = Get-LiveMode -ConfigText $currentConfig -AuthText (Read-AuthText)
    $officialConfig = New-ModeConfigText -CurrentText $currentConfig -Mode official
    Write-TransactionJournal -SourceMode $sourceMode -TargetMode official -TargetConfigText $officialConfig
    try {
        Write-AtomicText -Path $ConfigPath -Text $officialConfig
        # A fresh login must not silently reuse the active account. The
        # encrypted transaction restores this file even after interruption.
        [IO.File]::Delete($AuthPath)
        Write-Host '正在打开官方 OAuth 登录；登录完成后会恢复当前模式。'
        Invoke-CodexLogin
        $officialAuth = Read-AuthText
        if ((Get-AuthInfoFromText $officialAuth).Kind -ne 'official') { throw '登录没有返回官方 OAuth 认证。' }
        [void](Test-CodexLoginStatus -ExpectedKind official)
        if ($script:ReauthorizeExpectedId -and (Get-OfficialProfileIdFromAuth $officialAuth) -cne $script:ReauthorizeExpectedId) {
            throw '登录的不是要重新授权的账号，已取消更新。请在浏览器选择原账号。'
        }
        $saved = Save-OfficialProfile -AuthText $officialAuth -Name $name
        $script:LastSavedProfileId = [string]$saved.Entry.id
    }
    finally {
        Restore-Transaction
    }
    if ($script:ReauthorizeExpectedId -and $sourceMode -eq 'official' -and (Get-OfficialProfileIdFromAuth $originalAuth) -ceq $script:ReauthorizeExpectedId) {
        Invoke-ModeSwap -Mode official -TargetAuthText $officialAuth -State (Require-State) -ProfileId $script:ReauthorizeExpectedId
    }
    Write-Host "已登记官方账号：$([string](Get-ProfileField $saved.Entry 'name'))。已回到原来的使用模式。"
}

function Show-SwitcherStatus {
    $configText = Read-TextFile $ConfigPath
    $provider = [string](Get-TopLevelTomlValue -Text $configText -Key "model_provider")
    $contextWindow = [string](Get-TopLevelTomlValue -Text $configText -Key "model_context_window")
    $baseUrl = [string](Get-TopLevelTomlValue -Text $configText -Key "openai_base_url")
    $credentialStore = [string](Get-TopLevelTomlValue -Text $configText -Key "cli_auth_credentials_store")
    $respectSystemProxy = [string](Get-TomlTableValue -Text $configText -Table "features" -Key "respect_system_proxy")
    if ([string]::IsNullOrWhiteSpace($credentialStore)) {
        $credentialStore = "file (default)"
    }

    $authKind = "missing"
    if ([IO.File]::Exists($AuthPath)) {
        $authKind = (Get-AuthInfoFromText (Read-AuthText)).Kind
    }

    $state = Read-State
    $profileRegistry = Read-ProfileRegistry
    $relaySnapshot = [IO.File]::Exists($RelayAuthPath)
    $officialSnapshot = [IO.File]::Exists($OfficialAuthPath)
    if ($relaySnapshot) {
        [void](Unprotect-AuthSnapshot -Path $RelayAuthPath -ExpectedKind "api")
    }
    if ($officialSnapshot) {
        [void](Unprotect-AuthSnapshot -Path $OfficialAuthPath -ExpectedKind "official")
    }

    $activeMode = "inconsistent"
    if ($authKind -eq "api" -and -not [string]::IsNullOrWhiteSpace($baseUrl)) {
        $activeMode = "api"
    }
    elseif ($authKind -eq "official" -and [string]::IsNullOrWhiteSpace($baseUrl)) {
        $activeMode = "official"
    }

    $authLabel = switch ($authKind) {
        "official" { "官方 OAuth" }
        "api" { "中转 API" }
        "missing" { "缺失" }
        default { "未知（$authKind）" }
    }
    $modeLabel = switch ($activeMode) {
        "official" { "官方模式" }
        "api" { "中转模式" }
        default { "配置与认证不一致" }
    }
    $proxyLabel = switch ($respectSystemProxy) {
        "true" { "开启" }
        "false" { "关闭" }
        "" { "未设置" }
        default { "异常值（$respectSystemProxy）" }
    }
    $expectedProxy = if ($activeMode -eq "official") { "true" } elseif ($activeMode -eq "api") { "false" } else { "" }
    if (-not [string]::IsNullOrWhiteSpace($expectedProxy)) {
        $proxySuffix = '（按当前配置）'
        $proxyLabel += $proxySuffix
    }
    $historyStatus = Get-HistoryCompatibilityStatus

    Write-Host "CODEX_HOME：        $CodexHome"
    Write-Host "模型供应商：        $provider"
    Write-Host "上下文窗口：        $(if ([string]::IsNullOrWhiteSpace($contextWindow)) { '跟随模型默认值' } else { $contextWindow })"
    Write-Host "认证保存方式：      $credentialStore"
    Write-Host "当前认证：          $authLabel"
    Write-Host "当前模式：          $modeLabel"
    Write-Host "中转地址：          $(if ([string]::IsNullOrWhiteSpace($baseUrl)) { '无' } else { $baseUrl })"
    Write-Host "跟随系统代理：      $proxyLabel"
    Write-Host "中转认证快照：      $(if ($relaySnapshot) { '已就绪' } else { '缺失' })"
    Write-Host "官方认证快照：      $(if ($officialSnapshot) { '已就绪' } else { '尚未初始化' })"
    Write-Host "切换器状态：        $(if ($null -ne $state) { '已初始化' } else { '尚未初始化' })"
    Write-Host "已登记配置档案：    $(@($profileRegistry.api_profiles).Count) 个 API，$(@($profileRegistry.official_profiles).Count) 个官方账号"
    Write-Host "对话兼容准备：      $($historyStatus.Reason)"
}

function Switch-ToOfficial {
    param([switch]$SkipHistoryCheck, [AllowNull()][string]$ProfileName, [switch]$HistoryAlreadyPrepared)

    $state = Require-State
    Assert-NoExternalAuthOverrides
    Assert-CodexProcessesStopped
    Invoke-ProjectProjectionPreflight
    $currentAuth = Read-AuthText
    $currentInfo = Get-AuthInfoFromText $currentAuth
    $startingConfig = Read-TextFile $ConfigPath
    [void](Get-LiveMode -ConfigText $startingConfig -AuthText $currentAuth)
    if (-not $SkipHistoryCheck -and -not $HistoryAlreadyPrepared) {
        Invoke-HistoryCompatibilityPreflight
    }
    $profileRegistry = Ensure-ProfileRegistry $state
    $officialProfiles = @($profileRegistry.official_profiles)
    $selectedOfficial = $null
    if ($officialProfiles.Count -gt 0) {
        $selectedOfficial = Read-SelectedProfileAuth -Kind official -Selector $ProfileName
    }

    if ($null -ne $selectedOfficial) {
        $selectedOfficialId = [string](Get-ProfileField $selectedOfficial.Entry 'id')
        $sourceKind = Capture-CurrentCredentials $state
        $currentOfficialId = [string](Get-ProfileField $state 'active_official_profile_id')
        if (-not $SkipHistoryCheck -and $sourceKind -eq 'official' -and $currentOfficialId -and $currentOfficialId -cne $selectedOfficialId) {
            try {
                $syncResult = Sync-OfficialModelCatalogSnapshot -AuthText (Read-AuthText) -ProfileId $currentOfficialId
                Write-Host $syncResult.Message
            } catch {
                Write-Host '模型目录未更新，保留已有快照。'
            }
        }
        # The live account may have refreshed its tokens since the last
        # snapshot. Re-read after capture before selecting the same account.
        $selectedOfficial = Read-SelectedProfileAuth -Kind official -Selector $selectedOfficialId
        Invoke-ModeSwap -Mode "official" -TargetAuthText ([string]$selectedOfficial.AuthText) -State $state -ProfileId $selectedOfficialId
        Write-Host "已切换到官方 ChatGPT 档案 '$([string](Get-ProfileField $selectedOfficial.Entry 'name'))'。请重新启动 Codex Desktop。"
        return
    }

    if ($currentInfo.Kind -eq "official" -and -not [IO.File]::Exists($OfficialAuthPath)) {
        $configText = $startingConfig
        Assert-SupportedConfig $configText
        $sourceMode = Get-LiveMode -ConfigText $configText -AuthText $currentAuth
        $officialConfig = New-ModeConfigText -CurrentText $configText -Mode "official"
        $desktopPlan = New-DesktopStatePlan -TargetMode official -SourceAuthText $currentAuth -TargetAuthText $currentAuth -OfficialAuthText $currentAuth
        Backup-DesktopStatePlan $desktopPlan
        Write-TransactionJournal -SourceMode $sourceMode -TargetMode "official" -TargetConfigText $officialConfig -TargetAuthText $currentAuth -ExtraFiles $desktopPlan.Files
        try {
            Write-AtomicText -Path $ConfigPath -Text $officialConfig
            [void](Test-CodexLoginStatus -ExpectedKind "official")
            Protect-AuthSnapshot -Text $currentAuth -Path $OfficialAuthPath -ExpectedKind "official"
            $profileResult = Save-OfficialProfile -AuthText $currentAuth -Name $ProfileName -SetActive
            $state["active_official_profile_id"] = [string](Get-ProfileField $profileResult.Entry 'id')
            Write-State $state
            foreach ($file in $desktopPlan.Files) { Write-AtomicBytes -Path $file.Path -Bytes $file.TargetBytes }
            Complete-Transaction
            Write-Host "已保存当前官方 OAuth 认证快照。"
        }
        catch {
            $captureError = $_
            try {
                Restore-Transaction
            }
            catch {
                throw "保存官方认证失败，并且回滚也失败。保存错误：$captureError；回滚错误：$_"
            }
            throw "保存官方认证失败，正在使用的文件已经恢复。$captureError"
        }
        return
    }

    if ([IO.File]::Exists($OfficialAuthPath)) {
        [void](Capture-CurrentCredentials $state)
        $officialAuth = Unprotect-AuthSnapshot -Path $OfficialAuthPath -ExpectedKind "official"
        Invoke-ModeSwap -Mode "official" -TargetAuthText $officialAuth -State $state
        Write-Host "已切换到官方 ChatGPT OAuth 模式。请重新启动 Codex Desktop。"
        return
    }

    if ($currentInfo.Kind -ne "api") {
        throw "首次初始化官方账号时，当前必须是中转 API 认证；实际为 '$($currentInfo.Kind)'。"
    }

    [void](Capture-CurrentCredentials $state)
    $currentConfig = Read-TextFile $ConfigPath
    Assert-SupportedConfig $currentConfig
    $sourceMode = Get-LiveMode -ConfigText $currentConfig -AuthText (Read-AuthText)
    if ($sourceMode -ne "api") {
        throw "首次初始化官方账号必须从配置与认证一致的中转模式开始。"
    }
    $officialConfig = New-ModeConfigText -CurrentText $currentConfig -Mode "official"

    Write-Host "正在启动首次官方 OAuth 登录；中转认证快照已经加密保存。"
    $desktopPlan = New-DesktopStatePlan -TargetMode official -SourceAuthText (Read-AuthText)
    Backup-DesktopStatePlan $desktopPlan
    Write-TransactionJournal -SourceMode "api" -TargetMode "official" -TargetConfigText $officialConfig -ExtraFiles $desktopPlan.Files
    try {
        Write-AtomicText -Path $ConfigPath -Text $officialConfig
        Invoke-CodexLogin

        $officialAuth = Read-AuthText
        $officialInfo = Get-AuthInfoFromText $officialAuth
        if ($officialInfo.Kind -ne "official") {
            throw "OAuth 登录返回了 '$($officialInfo.Kind)' 认证，而不是官方认证。"
        }

        [void](Test-CodexLoginStatus -ExpectedKind "official")
        Protect-AuthSnapshot -Text $officialAuth -Path $OfficialAuthPath -ExpectedKind "official"
        $profileResult = if ([string]::IsNullOrWhiteSpace($ProfileName)) {
            Sync-CurrentAuthProfile -Kind official -AuthText $officialAuth
        } else {
            Save-OfficialProfile -AuthText $officialAuth -Name $ProfileName -SetActive
        }
        $state["active_official_profile_id"] = [string](Get-ProfileField $profileResult.Entry 'id')
        Write-State $state
        foreach ($file in $desktopPlan.Files) { Write-AtomicBytes -Path $file.Path -Bytes $file.TargetBytes }
        Complete-Transaction
        Write-Host "官方 OAuth 初始化完成。请重新启动 Codex Desktop。"
    }
    catch {
        $loginError = $_
        try {
            Restore-Transaction
        }
        catch {
            throw "官方登录失败，并且回滚也失败。登录错误：$loginError；回滚错误：$_"
        }
        throw "官方登录未完成，已经恢复中转配置和 API 认证。$loginError"
    }
}

function Switch-ToApi {
    param([switch]$SkipHistoryCheck, [AllowNull()][string]$ProfileName, [switch]$HistoryAlreadyPrepared)
    $state = Require-State
    Assert-NoExternalAuthOverrides
    Assert-CodexProcessesStopped
    Invoke-ProjectProjectionPreflight
    $sourceKind = Capture-CurrentCredentials $state
    if (-not $SkipHistoryCheck -and $sourceKind -eq 'official') {
        $officialProfileId = [string](Get-ProfileField $state 'active_official_profile_id')
        if ($officialProfileId) {
            try {
                $syncResult = Sync-OfficialModelCatalogSnapshot -AuthText (Read-AuthText) -ProfileId $officialProfileId
                Write-Host $syncResult.Message
            } catch {
                Write-Host '模型目录未更新，保留已有快照。'
            }
        }
    }
    $selected = Read-SelectedProfileAuth -Kind api -Selector $ProfileName
    $relayAuth = [string]$selected.AuthText
    $baseUrl = [string](Get-ProfileField $selected.Entry 'base_url')
    if ([string]::IsNullOrWhiteSpace($baseUrl)) { throw '选中的中转档案没有地址。' }
    if (-not $SkipHistoryCheck -and -not $HistoryAlreadyPrepared) {
        Invoke-HistoryCompatibilityPreflight
    }
    Invoke-ModeSwap -Mode "api" -TargetAuthText $relayAuth -State $state -RelayBaseUrl $baseUrl -ProfileId ([string](Get-ProfileField $selected.Entry 'id'))
    $effectiveCatalogPath = Get-ApiModelCatalogPath $selected.Entry
    if (-not $effectiveCatalogPath -or -not [IO.File]::Exists($effectiveCatalogPath)) {
        Write-Host '此 API 账号尚无可用模型目录，模型列表可能不完整。'
    }
    Write-Host "已切换到中转 API 档案 '$([string](Get-ProfileField $selected.Entry 'name'))'。请重新启动 Codex Desktop。"
}

function Invoke-AutoSwitch {
    param([ValidateSet('official', 'api')][string]$TargetModeOverride, [AllowNull()][string]$ProfileName)
    $switchTimer = [Diagnostics.Stopwatch]::StartNew()
    $script:AutoRunTimer=$switchTimer
    Assert-NoExternalAuthOverrides
    Assert-CodexProcessesStopped

    $state = Read-State
    $historyPreparedDuringInitialization = $false
    if ($null -eq $state) {
        $wasFreshSetup = -not [IO.File]::Exists($ConfigPath) -or -not [IO.File]::Exists($AuthPath)
        Write-Host "首次使用：正在根据当前认证自动初始化切换器快照。"
        Initialize-Switcher
        $historyPreparedDuringInitialization = $true
        if ($wasFreshSetup) { return }
    }
    Invoke-ProjectProjectionPreflight

    $currentConfig = Read-TextFile $ConfigPath
    $currentAuth = Read-AuthText
    $currentMode = Get-LiveMode -ConfigText $currentConfig -AuthText $currentAuth
    $targetMode = if (-not [string]::IsNullOrWhiteSpace($TargetModeOverride)) { $TargetModeOverride } elseif ($currentMode -eq "official") { "api" } else { "official" }
    if (-not [string]::IsNullOrWhiteSpace($ProfileName)) { [void](Read-SelectedProfileAuth -Kind $targetMode -Selector $ProfileName) }
    $currentLabel = if ($currentMode -eq "official") { "官方模式" } else { "中转模式" }
    $targetLabel = if ($targetMode -eq "official") { "官方模式" } else { "中转模式" }
    Write-Host "当前是 $currentLabel，自动切换目标为 $targetLabel。"

    if ($targetMode -eq "official") {
        $script:OperationStage = "switch-official"
        # Initialization already checked history under this operation's lock.
        # Do not repeat a full forced scan before its first actual switch.
        Switch-ToOfficial -HistoryAlreadyPrepared:$historyPreparedDuringInitialization -ProfileName $ProfileName
    }
    else {
        $script:OperationStage = "switch-api"
        Switch-ToApi -HistoryAlreadyPrepared:$historyPreparedDuringInitialization -ProfileName $ProfileName
    }
    Write-Host ("本次一键切换总耗时：{0:N1} 秒（如有首次登录，包含等待登录的时间）。" -f $switchTimer.Elapsed.TotalSeconds)
    # Statistics must not turn a completed auth/config transaction into a
    # reported switching failure merely because its optional report is locked.
    try { Save-LastSwitcherRun -Succeeded $true }
    catch { Write-Warning '切换已完成，但无法保存本次耗时记录。' }
}

function Save-LastSwitcherRun {
    param([bool]$Succeeded)
    if ($null -eq $script:AutoRunTimer) { return }
    $total=$script:AutoRunTimer.Elapsed.TotalSeconds
    $historySeconds=if ($null -eq $script:LatestHistoryMetrics) {0} else {$script:LatestHistoryMetrics.total_seconds}
    $value=[ordered]@{version=1;utc=[DateTime]::UtcNow.ToString('o');success=$Succeeded;stage=$script:OperationStage;
        total_seconds=[Math]::Round($total,3);other_seconds=[Math]::Round([Math]::Max(0,$total-$historySeconds),3);history=$script:LatestHistoryMetrics}
    Write-AtomicText -Path $LastRunPath -Text (($value | ConvertTo-Json -Depth 10) + [Environment]::NewLine)
}

function Show-Menu {
    if (-not [IO.File]::Exists($ConfigPath) -or -not [IO.File]::Exists($AuthPath)) {
        Invoke-WithMonitorMaintenance -Action "setup" -Operation { Initialize-Switcher }
        return
    }
    Show-SwitcherStatus
    Write-Host ""
    Write-Host "1. 一键切换到另一种模式（自动初始化，必要时自动准备历史）"
    Write-Host "2. 高级维护（初始化、指定模式、历史检查与准备）"
    Write-Host "3. 管理多个 API / 官方账号配置"
    Write-Host "4. 退出"
    $choice = Read-Host "请选择"
    switch ($choice) {
        "1" { Invoke-WithMonitorMaintenance -Action "toggle" -Operation { Invoke-AutoSwitch } }
        "2" { Show-AdvancedMenu }
        "3" { Show-ProfileMenu }
        "4" { return }
        default { throw "无法识别的菜单选项：$choice" }
    }
}

function Show-ProfileMenu {
    if ($null -eq (Read-State)) { Initialize-Switcher }
    Show-ProfileRegistry
    Write-Host ""
    Write-Host "1. 登记新的中转 API（密钥加密保存）"
    Write-Host "2. 登记新的官方账号（打开 OAuth 登录后恢复当前模式）"
    Write-Host "3. 切换到 API 配置"
    Write-Host "4. 切换到官方账号"
    Write-Host "5. 返回"
    $choice = Read-Host "请选择"
    switch ($choice) {
        "1" { Add-ApiProfileInteractively }
        "2" { Add-OfficialProfileInteractively }
        "3" { Switch-ToApi -ProfileName (Read-Host '输入 API 配置名称或 ID') }
        "4" { Invoke-AutoSwitch -TargetModeOverride official -ProfileName (Read-Host '输入官方账号名称或 ID') }
        "5" { return }
        default { throw "无法识别的档案菜单选项：$choice" }
    }
}

function Show-AdvancedMenu {
    Write-Host ""
    Write-Host "高级维护"
    Write-Host "2/3 为快速切换：更新配置、认证并保留桌面项目和欢迎状态，跳过历史扫描。"
    Write-Host "1. 初始化或更新当前认证快照"
    Write-Host "2. 切换到官方 ChatGPT OAuth"
    Write-Host "3. 切换到中转 API"
    Write-Host "4. 只读扫描历史（不修改文件，也不生成官方切换准备记录）"
    Write-Host "5. 全量历史检查与安全修复（需先关闭 Codex）"
    Write-Host "6. 只读检查桌面项目和欢迎状态"
    Write-Host "7. 修复桌面项目和欢迎状态（保持当前认证模式）"
    Write-Host "8. 返回"
    $choice = Read-Host "请选择"
    switch ($choice) {
        "1" { Invoke-WithMonitorMaintenance -Action "init" -Operation { Initialize-Switcher } }
        "2" { Invoke-WithMonitorMaintenance -Action "config-official" -Operation { Switch-ToOfficial -SkipHistoryCheck } }
        "3" { Invoke-WithMonitorMaintenance -Action "config-api" -Operation { Switch-ToApi -SkipHistoryCheck } }
        "4" { Invoke-HistoryCompatibilityScan }
        "5" {
            Assert-CodexProcessesStopped
            Invoke-WithMonitorMaintenance -Action "history-prepare" -Operation { Invoke-HistoryCompatibilityPrepare -FullScan }
        }
        "6" { Invoke-DesktopStateCompatibility -ReadOnly }
        "7" {
            Assert-CodexProcessesStopped
            Invoke-WithMonitorMaintenance -Action "desktop-repair" -Operation { Invoke-DesktopStateCompatibility }
        }
        "8" { return }
        default { throw "无法识别的高级维护选项：$choice" }
    }
}

if ($LibraryOnly) { return }
[IO.Directory]::CreateDirectory($DataDir) | Out-Null
$lockStream = $null
try {
    try {
        $lockStream = [IO.File]::Open($LockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    }
    catch {
        throw "另一个 Codex 配置切换器正在运行。"
    }

    Restore-ProfileTransaction
    if ([IO.File]::Exists($TransactionPath)) {
        Assert-CodexProcessesStopped
        Write-Warning "检测到未完成的切换事务，正在恢复。"
        Invoke-WithMonitorMaintenance -Action "transaction-recovery" -Operation { Restore-Transaction }
        Write-Host "已经恢复切换前的配置、认证和桌面状态。"
    }
    if($Command -in @('menu','toggle','official','api','config-official','config-api','profile-use-api','profile-use-official','history-scan','history-prepare','history-repair','project-scan','project-repair','desktop-repair')){Initialize-WindowsSqlite}

    switch ($Command) {
        "menu" { Show-Menu }
        "toggle" { Invoke-WithMonitorMaintenance -Action "toggle" -Operation { Invoke-AutoSwitch } }
        "setup" { Invoke-WithMonitorMaintenance -Action "setup" -Operation { Initialize-Switcher } }
        "init" { Invoke-WithMonitorMaintenance -Action "init" -Operation { Initialize-Switcher } }
        "status" { Show-SwitcherStatus }
        "diagnose" { Get-SwitcherDiagnostics | Format-Table Name,Status,Detail -Wrap }
        "request" { Invoke-WithMonitorMaintenance -Action 'graphical' -Operation { Invoke-SwitcherRequest $RequestPath } }
        "profile-rename" { Set-ProfileDetails $Kind $Profile @{name=(Read-Host '新名称')} }
        "profile-remove" { Remove-ProfileEntry $Kind $Profile }
        "profile-update" { Set-ProfileDetails $Kind $Profile @{api_key=(Read-SwitcherPrompt 'api_key' '新的 API Key' -Secret)} }
        "profile-reauth" { Invoke-WithMonitorMaintenance -Action 'reauthorize' -Operation { Invoke-ReauthorizeProfile $Profile } }
        "profiles" { Show-ProfileRegistry }
        "profile-list" { Show-ProfileRegistry }
        "profile-add-api" { Invoke-WithMonitorMaintenance -Action "profile-add-api" -Operation { Add-ApiProfileInteractively } }
        "profile-add-official" { Invoke-WithMonitorMaintenance -Action "profile-add-official" -Operation { Add-OfficialProfileInteractively } }
        "profile-use-api" { Invoke-WithMonitorMaintenance -Action "profile-use-api" -Operation { Switch-ToApi -ProfileName $Profile } }
        "profile-use-official" { Invoke-WithMonitorMaintenance -Action "profile-use-official" -Operation { Invoke-AutoSwitch -TargetModeOverride official -ProfileName $Profile } }
        "official" { Invoke-WithMonitorMaintenance -Action "official" -Operation { Switch-ToOfficial -ProfileName $Profile } }
        "api" { Invoke-WithMonitorMaintenance -Action "api" -Operation { Switch-ToApi -ProfileName $Profile } }
        "config-official" { Invoke-WithMonitorMaintenance -Action "config-official" -Operation { Switch-ToOfficial -SkipHistoryCheck -ProfileName $Profile } }
        "config-api" { Invoke-WithMonitorMaintenance -Action "config-api" -Operation { Switch-ToApi -SkipHistoryCheck -ProfileName $Profile } }
        "history-scan" { Invoke-HistoryCompatibilityScan }
        "history-prepare" {
            Assert-CodexProcessesStopped
            Invoke-WithMonitorMaintenance -Action "history-prepare" -Operation { Invoke-HistoryCompatibilityPrepare }
        }
        "history-repair" {
            Assert-CodexProcessesStopped
            Invoke-WithMonitorMaintenance -Action "history-prepare" -Operation { Invoke-HistoryCompatibilityPrepare }
        }
        "project-scan" { Invoke-ProjectProjectionRepair -ReadOnly }
        "project-repair" {
            Assert-CodexProcessesStopped
            Invoke-WithMonitorMaintenance -Action "project-repair" -Operation { Invoke-ProjectProjectionRepair }
        }
        "desktop-scan" { Invoke-DesktopStateCompatibility -ReadOnly }
        "desktop-repair" {
            Assert-CodexProcessesStopped
            Invoke-WithMonitorMaintenance -Action "desktop-repair" -Operation { Invoke-DesktopStateCompatibility }
        }
    }
}
catch {
    $failure = $_
    try { Save-LastSwitcherRun -Succeeded $false } catch { Write-Warning '无法保存本次耗时记录。' }
    try {
        Save-LastSwitcherFailure -Failure $failure
        Write-Host "本次失败位置已记录（只保留最近一份，不含密钥或对话正文）：$LastErrorPath"
    }
    catch {
        Write-Warning "无法保存错误记录；原始错误仍会显示在下方。"
    }
    Write-Error -ErrorRecord $failure -ErrorAction Continue
    exit 1
}
finally {
    if ($null -ne $lockStream) {
        $lockStream.Dispose()
    }
}
