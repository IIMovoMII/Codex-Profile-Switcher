#requires -Version 5.1

[CmdletBinding()]
param(
    [ValidateSet("scan", "repair", "rollback")]
    [string]$Command = "scan",

    [string]$CodexHome,
    [string]$BackupRoot,
    [string[]]$ExcludePath = @(),
    [string]$ManifestPath,
    [switch]$PortableInputIds,
    [switch]$Incremental
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
    throw "Codex 对话兼容修复目前只支持 Windows。"
}

if ($null -eq ("CodexHistoryCompat.NativeMethods" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CodexHistoryCompat {
    public static class NativeMethods {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern bool MoveFileEx(string existingFileName, string newFileName, int flags);
    }
}
'@
}

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
if ($null -eq ("CodexHistoryCompat.HexCodec" -as [type])) {
    # Projection rows can contain megabytes of tool output. Decode in compiled
    # code, not one PowerShell invocation per byte (also works on PS 5.1).
    Add-Type -TypeDefinition @'
using System;
using System.Text;
namespace CodexHistoryCompat {
    public static class HexCodec {
        private static int Digit(char c) {
            if (c >= '0' && c <= '9') return c - '0';
            if (c >= 'A' && c <= 'F') return c - 'A' + 10;
            if (c >= 'a' && c <= 'f') return c - 'a' + 10;
            throw new FormatException("Invalid hexadecimal digit.");
        }
        public static string DecodeUtf8(string hex) {
            if (hex == null || (hex.Length & 1) != 0)
                throw new FormatException("Invalid hexadecimal length.");
            byte[] bytes = new byte[hex.Length / 2];
            try {
                for (int i = 0; i < bytes.Length; i++)
                    bytes[i] = (byte)((Digit(hex[i * 2]) << 4) | Digit(hex[i * 2 + 1]));
                return new UTF8Encoding(false).GetString(bytes);
            }
            finally { Array.Clear(bytes, 0, bytes.Length); }
        }
    }
}
'@
}
$script:SqliteExecutable = $null
$script:ProjectionFingerprintColumns = @{}
$script:ProjectionSchemaCounts = @{}
if ($null -eq ("CodexHistoryCompat.PortableHistory" -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot "CodexPortableHistory.cs")
}
$script:IdPrefixes = @{
    additional_tools         = "at"
    message                  = "msg"
    agent_message            = "amsg"
    reasoning                = "rs"
    local_shell_call         = "lsh"
    function_call            = "fc"
    tool_search_call         = "tsc"
    function_call_output     = "fco"
    custom_tool_call         = "ctc"
    custom_tool_call_output  = "ctco"
    tool_search_output       = "tso"
    web_search_call          = "ws"
    image_generation_call    = "ig"
    compaction               = "cmp"
    compaction_summary       = "cmp"
    context_compaction       = "cmp"
}

function Resolve-NormalizedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    return [IO.Path]::GetFullPath($expanded).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
}

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        $CodexHome = $env:CODEX_HOME
    }
    else {
        $CodexHome = Join-Path $env:USERPROFILE ".codex"
    }
}
$CodexHome = Resolve-NormalizedPath $CodexHome

if ([string]::IsNullOrWhiteSpace($BackupRoot) -and $Command -eq 'rollback' -and
    -not [string]::IsNullOrWhiteSpace($ManifestPath)) {
    $BackupRoot = Split-Path -Parent (Split-Path -Parent (Resolve-NormalizedPath $ManifestPath))
}
if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
    $localDataRoot = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($localDataRoot)) {
        $localDataRoot = Join-Path $env:USERPROFILE "AppData\Local"
    }
    $BackupRoot = Join-Path $localDataRoot "CodexProfileSwitcher\history-repair-backups"
}
$BackupRoot = Resolve-NormalizedPath $BackupRoot

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

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($Bytes))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-TextSha256 {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $bytes = $script:Utf8NoBom.GetBytes($Text)
    try {
        return Get-Sha256Hex $bytes
    }
    finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    $stream = New-Object IO.FileStream(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete),
        1048576,
        [IO.FileOptions]::SequentialScan
    )
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $stream.Dispose()
        $sha256.Dispose()
    }
}

function Move-ReplaceFile {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    $moveFileReplaceExisting = 0x1
    $moveFileWriteThrough = 0x8
    if (-not [CodexHistoryCompat.NativeMethods]::MoveFileEx(
        $Source,
        $Destination,
        ($moveFileReplaceExisting -bor $moveFileWriteThrough)
    )) {
        $win32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw (New-Object ComponentModel.Win32Exception($win32Error))
    }
}

function Write-AtomicText {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporaryPath = Join-Path $directory (".{0}.{1}.tmp" -f [IO.Path]::GetFileName($Path), [Guid]::NewGuid().ToString("N"))
    try {
        $bytes=$script:Utf8NoBom.GetBytes($Text)
        $stream=New-Object IO.FileStream($temporaryPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None,65536,[IO.FileOptions]::WriteThrough)
        try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        Move-ReplaceFile -Source $temporaryPath -Destination $Path
    }
    finally {
        if ([IO.File]::Exists($temporaryPath)) {
            [IO.File]::Delete($temporaryPath)
        }
    }
}

function Save-Manifest {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $Manifest.updated_utc = [DateTime]::UtcNow.ToString("o")
    $text = ($Manifest | ConvertTo-Json -Depth 12) + [Environment]::NewLine
    Write-AtomicText -Path $Path -Text $text
}

function Copy-DurableHistoryFile {
    param([string]$Source,[string]$Destination)
    [IO.File]::Copy($Source,$Destination,$false)
    $stream=[IO.File]::Open($Destination,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try { $stream.Flush($true) } finally { $stream.Dispose() }
}

function Get-RolloutFiles {
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($folderName in @("sessions", "archived_sessions")) {
        $folder = Join-Path $CodexHome $folderName
        if (-not [IO.Directory]::Exists($folder)) {
            continue
        }
        foreach ($file in [IO.Directory]::EnumerateFiles($folder, "*.jsonl", [IO.SearchOption]::AllDirectories)) {
            $files.Add((Resolve-NormalizedPath $file))
        }
    }
    return @($files | Sort-Object -Unique)
}

function Get-StateDatabaseFiles {
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($folder in @($CodexHome, (Join-Path $CodexHome "sqlite"))) {
        if (-not [IO.Directory]::Exists($folder)) {
            continue
        }
        foreach ($file in [IO.Directory]::EnumerateFiles($folder, "*.sqlite", [IO.SearchOption]::TopDirectoryOnly)) {
            $files.Add((Resolve-NormalizedPath $file))
        }
    }
    return @($files | Sort-Object -Unique)
}

function Get-SqliteExecutable {
    if (-not [string]::IsNullOrWhiteSpace([string]$script:SqliteExecutable)) {
        return $script:SqliteExecutable
    }

    $command = Get-Command sqlite3.exe -ErrorAction SilentlyContinue
    if ($null -eq $command) {
        $command = Get-Command sqlite3 -ErrorAction SilentlyContinue
    }
    if ($null -eq $command) {
        throw "发现 Codex SQLite 状态库，但系统中找不到 sqlite3.exe。"
    }
    $script:SqliteExecutable = [string]$command.Source
    return $script:SqliteExecutable
}

function Invoke-SqliteLines {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Sql,
        [switch]$ReadOnly
    )

    $executable = Get-SqliteExecutable
    $arguments = New-Object System.Collections.Generic.List[string]
    if ($ReadOnly) {
        $arguments.Add("-readonly")
    }
    $databaseArgument = ([Uri][IO.Path]::GetFullPath($Path)).AbsoluteUri
    foreach ($argument in @("-batch", "-bail", "-noheader", "-cmd", ".timeout 5000", $databaseArgument)) {
        $arguments.Add($argument)
    }

    $sqliteArguments=$arguments.ToArray()
    $output = $Sql | & $executable @sqliteArguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $message = (@($output) | ForEach-Object { [string]$_ }) -join "; "
        throw "SQLite 操作失败（退出码 $exitCode）：$Path：$message"
    }
    return @($output | ForEach-Object { [string]$_ })
}

function ConvertTo-SqlStringLiteral {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    return "'" + $Value.Replace("'", "''") + "'"
}

function ConvertFrom-HexUtf8 {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Hex)

    if (($Hex.Length % 2) -ne 0) {
        throw "SQLite 返回了长度无效的十六进制文本。"
    }
    return [CodexHistoryCompat.HexCodec]::DecodeUtf8($Hex)
}

function Test-ThreadProviderSchema {
    param([Parameter(Mandatory = $true)][string]$Path)

    $lines = @(Invoke-SqliteLines -Path $Path -ReadOnly -Sql "SELECT COUNT(*) FROM pragma_table_info('threads') WHERE name IN ('id','model_provider');")
    if ($lines.Count -ne 1) {
        throw "无法识别 SQLite threads 表结构：$Path"
    }
    $columnCount = [int]$lines[0]
    if ($columnCount -eq 0) {
        return $false
    }
    if ($columnCount -ne 2) {
        throw "SQLite threads 表缺少 id 或 model_provider 字段：$Path"
    }
    return $true
}

function Assert-SqliteQuickCheck {
    param([Parameter(Mandatory = $true)][string]$Path)

    $lines = @(Invoke-SqliteLines -Path $Path -ReadOnly -Sql "PRAGMA quick_check;")
    if ($lines.Count -ne 1 -or [string]$lines[0] -cne "ok") {
        throw "SQLite quick_check 未通过：$Path：$($lines -join '; ')"
    }
}

function Get-SqliteThreadProviderRows {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$ThreadIds
    )

    $rows = New-Object System.Collections.Generic.List[object]
    if ($ThreadIds.Count -eq 0) {
        return $rows.ToArray()
    }
    $lines = @(Invoke-SqliteLines -Path $Path -ReadOnly -Sql "SELECT hex(id) || '|' || hex(model_provider) FROM threads ORDER BY id;")
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $parts = $line.Split([char[]]@('|'), 2)
        if ($parts.Count -ne 2) {
            throw "SQLite provider 查询返回了无法解析的记录：$Path"
        }
        $threadId = ConvertFrom-HexUtf8 $parts[0]
        if (-not $ThreadIds.Contains($threadId)) {
            continue
        }
        $rows.Add([pscustomobject]@{
            ThreadId = $threadId
            Provider = ConvertFrom-HexUtf8 $parts[1]
        })
    }
    return $rows.ToArray()
}

function Get-DatabaseCompatibilityReports {
    param([Parameter(Mandatory = $true)]$ThreadIds)

    $reports = New-Object System.Collections.Generic.List[object]
    foreach ($path in @(Get-StateDatabaseFiles)) {
        if (-not (Test-ThreadProviderSchema -Path $path)) {
            continue
        }

        $counts = @{}
        $changes = New-Object System.Collections.Generic.List[object]
        foreach ($row in @(Get-SqliteThreadProviderRows -Path $path -ThreadIds $ThreadIds)) {
            $provider = [string]$row.Provider
            if (-not $counts.ContainsKey($provider)) {
                $counts[$provider] = 0
            }
            $counts[$provider]++
            if ($provider -cne "openai") {
                $changes.Add([pscustomobject]@{
                    ThreadId = [string]$row.ThreadId
                    OldProvider = $provider
                    NewProvider = "openai"
                })
            }
        }
        $reports.Add([pscustomobject]@{
            Path = $path
            ProviderCounts = $counts
            Changes = $changes.ToArray()
        })
    }
    return $reports.ToArray()
}

function Open-SharedTextReader {
    param([Parameter(Mandatory = $true)][string]$Path, [long]$StartOffset = 0)

    $stream = New-Object IO.FileStream(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete),
        1048576,
        [IO.FileOptions]::SequentialScan
    )
    $stream.Position = $StartOffset
    return New-Object IO.StreamReader($stream, (New-Object Text.UTF8Encoding($false, $true)), ($StartOffset -eq 0), 1048576, $false)
}

function Get-FileLayout {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = New-Object IO.FileStream(
        $Path,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete),
        65536,
        [IO.FileOptions]::SequentialScan
    )
    try {
        $head = New-Object byte[] 65536
        $read = $stream.Read($head, 0, $head.Length)
        $hasBom = $read -ge 3 -and $head[0] -eq 0xEF -and $head[1] -eq 0xBB -and $head[2] -eq 0xBF
        $newline = "`n"
        for ($index = 0; $index -lt $read; $index++) {
            if ($head[$index] -eq 10) {
                if ($index -gt 0 -and $head[$index - 1] -eq 13) {
                    $newline = "`r`n"
                }
                break
            }
        }

        $hasFinalNewline = $false
        if ($stream.Length -gt 0) {
            [void]$stream.Seek(-1, [IO.SeekOrigin]::End)
            $hasFinalNewline = $stream.ReadByte() -eq 10
        }
        return [pscustomobject]@{
            Newline = $newline
            HasBom = $hasBom
            HasFinalNewline = $hasFinalNewline
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Get-MaterializedForkThreadId {
    param([string]$Path, [object[]]$Metadata)

    # Verified native fork layout: child metadata at ordinal 0, followed by
    # copied parent metadata at ordinal 1. An ancestor ID is not file ownership.
    # Unknown/more complex layouts keep the existing multiple-thread refusal.
    if ($Metadata.Count -ne 2) { return $null }
    $child = $Metadata[0]
    $parent = $Metadata[1]
    $uuid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    $name = [IO.Path]::GetFileName($Path)
    $match = [regex]::Match($name, ('^rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-(?<owner>' + $uuid + ')\.jsonl$'))
    if (-not $match.Success -or $child.LineNumber -ne 1 -or $parent.LineNumber -ne 2 -or
        [string]$child.Ordinal -cne '0' -or [string]$parent.Ordinal -cne '1' -or
        $child.Id -cne $match.Groups['owner'].Value -or $parent.Id -cnotmatch ('^' + $uuid + '$') -or
        $child.Id -ceq $parent.Id -or $child.ForkedFromId -cne $parent.Id -or
        $child.HistoryMode -cne 'paginated' -or $parent.HistoryMode -cne 'paginated' -or
        $null -ne $child.HistoryBase) {
        return $null
    }
    if ($null -ne $parent.HistoryBase) {
        # A fully materialized fork may copy its parent's old base descriptor.
        # It is inert ancestry only when the child has no base and its next
        # record supplies a complete native compaction baseline at ordinal 2.
        $endOrdinal = 0L; $endOffset = 0L
        if ([string](Get-JsonPropertyValue $parent.HistoryBase 'thread_id') -cnotmatch ('^'+$uuid+'$') -or
            -not [long]::TryParse([string](Get-JsonPropertyValue $parent.HistoryBase 'end_ordinal_exclusive'),[ref]$endOrdinal) -or
            -not [long]::TryParse([string](Get-JsonPropertyValue $parent.HistoryBase 'end_byte_offset'),[ref]$endOffset) -or
            $endOrdinal -lt 1 -or $endOffset -lt 1) { return $null }
        $reader = Open-SharedTextReader $Path
        try { [void]$reader.ReadLine(); [void]$reader.ReadLine(); $baseline = $reader.ReadLine() | ConvertFrom-Json }
        finally { $reader.Dispose() }
        $payload = Get-JsonPropertyValue $baseline 'payload'
        $replacement = @(Get-JsonPropertyValue $payload 'replacement_history')
        $compactions = @($replacement | Where-Object {
            [string](Get-JsonPropertyValue $_ 'type') -ceq 'compaction' -and
            -not [string]::IsNullOrWhiteSpace([string](Get-JsonPropertyValue $_ 'encrypted_content'))
        })
        if ([string](Get-JsonPropertyValue $baseline 'ordinal') -cne '2' -or
            [string](Get-JsonPropertyValue $baseline 'type') -cne 'compacted' -or $compactions.Count -ne 1) { return $null }
    }
    return [string]$child.Id
}

function Get-FileCompatibilityItems {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$ExcludedPaths,
        [long]$StartOffset = 0,
        [int]$FirstLine = 0,
        $PreviousReport
    )

    $items = New-Object System.Collections.Generic.List[object]
    $providerItems = New-Object System.Collections.Generic.List[object]
    $threadIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $sessionMetadata = New-Object System.Collections.Generic.List[object]
    $fileIssues = New-Object System.Collections.Generic.List[object]
    $isMaterializedFork = $false
    $providerCounts = @{}
    $idCounts = @{}
    $isPaginatedHistory = $false
    $portableRecords = $null
    if ($StartOffset -gt 0 -and $null -ne $PreviousReport) {
        $isPaginatedHistory = [bool]$PreviousReport.IsPaginated
        $isMaterializedFork = [bool]$PreviousReport.IsMaterializedFork
        foreach ($id in @($PreviousReport.ThreadIds)) { [void]$threadIds.Add([string]$id) }
        foreach ($property in $PreviousReport.ProviderCounts.PSObject.Properties) {
            $providerCounts[$property.Name] = [int]$property.Value
        }
        $portableRecords = [CodexHistoryCompat.PortableHistory]::ScanFile($Path, $StartOffset, $FirstLine)
        $items.AddRange([object[]]@($portableRecords.Values))
    }

    # A zero-byte rollout can be left behind when Codex is interrupted before
    # writing session_meta. It is not a conversation and must never be treated
    # as a clean file during an account switch. Report it explicitly so the
    # stop-gated repair path can quarantine it instead of silently ignoring it.
    $fileLength = (Get-Item -LiteralPath $Path).Length
    if ($fileLength -eq 0) {
        $fileIssues.Add([pscustomobject]@{
            LineNumber = 0
            Reason = "历史文件为空，没有可用的 session_meta 头；必须停机隔离后才能继续。"
        })
        return [pscustomobject]@{
            Path = $Path
            IsPaginated = $false
            IsMaterializedFork = $false
            Excluded = $ExcludedPaths.Contains($Path)
            Items = @()
            ProviderItems = @()
            ProviderCounts = @{}
            ThreadIds = @()
            FileIssues = $fileIssues.ToArray()
        }
    }
    $lineNumber = $FirstLine
    $reader = Open-SharedTextReader -Path $Path -StartOffset $StartOffset
    try {
        while (($line = $reader.ReadLine()) -ne $null) {
            $lineNumber++
            if ($null -ne $portableRecords -and $portableRecords.ContainsKey($lineNumber)) { continue }
            # A relay can already use the correct prefix while exceeding the API's
            # 64-character limit (for example rs_resp_<uuid>_<uuid>_0).
            # A short, correctly prefixed reasoning ID is still unusable when
            # the relay did not return replayable content. Otherwise Codex
            # sends an ID-only item and the official API tries a persisted-item
            # lookup (which is unavailable with store=false).
            $isEmptyReasoningCandidate = $line -match '"type"\s*:\s*"reasoning"' -and
                $line -notmatch '"encrypted_content"\s*:\s*"(?:[^"\\]|\\.)+"' -and
                $line -notmatch '"content"\s*:\s*\[\s*\{'
            $isResponseCandidate = $line -match '"id"\s*:\s*"(?:item_|[^"\\]{65})' -or
                $isEmptyReasoningCandidate
            $isProviderCandidate = $line -match '"(?:model_provider|model_provider_id)"\s*:'
            $isSessionCandidate = $line -match '"type"\s*:\s*"session_meta"'
            if (-not $isResponseCandidate -and -not $isProviderCandidate -and -not $isSessionCandidate) {
                continue
            }

            try {
                $record = $line | ConvertFrom-Json
            }
            catch {
                throw "JSONL 记录无效：${Path}:${lineNumber}：$($_.Exception.Message)"
            }

            $recordType = [string](Get-JsonPropertyValue -Object $record -Name "type")
            $payload = Get-JsonPropertyValue -Object $record -Name "payload"
            if ($recordType -eq "session_meta" -and $null -ne $payload) {
                $isPaginatedHistory = [string](Get-JsonPropertyValue -Object $payload -Name "history_mode") -eq "paginated"
                if ($PortableInputIds -and $isPaginatedHistory -and $null -eq $portableRecords) {
                    $portableRecords = [CodexHistoryCompat.PortableHistory]::ScanFile($Path)
                    $items.AddRange([object[]]@($portableRecords.Values))
                }
                $threadId = [string](Get-JsonPropertyValue -Object $payload -Name "id")
                $sessionMetadata.Add([pscustomobject]@{
                    LineNumber = $lineNumber
                    Ordinal = Get-JsonPropertyValue $record 'ordinal'
                    Id = $threadId
                    ForkedFromId = [string](Get-JsonPropertyValue $payload 'forked_from_id')
                    HistoryMode = [string](Get-JsonPropertyValue $payload 'history_mode')
                    HistoryBase = Get-JsonPropertyValue $payload 'history_base'
                })
                if (-not [string]::IsNullOrWhiteSpace($threadId)) {
                    [void]$threadIds.Add($threadId)
                }
                $providerProperty = $payload.PSObject.Properties["model_provider"]
                if ($null -ne $providerProperty) {
                    $provider = [string]$providerProperty.Value
                    $providerKey = if ([string]::IsNullOrWhiteSpace($provider)) { "<empty>" } else { $provider }
                    if (-not $providerCounts.ContainsKey($providerKey)) {
                        $providerCounts[$providerKey] = 0
                    }
                    $providerCounts[$providerKey]++
                    if ($provider -cne "openai") {
                        $providerItems.Add([pscustomobject]@{
                            LineNumber = $lineNumber
                            RecordType = "session_meta"
                            Field = "model_provider"
                            ThreadId = $threadId
                            OldProvider = $provider
                            NewProvider = "openai"
                            OldLineSha256 = Get-TextSha256 $line
                            UnsupportedReason = $(if ([string]::IsNullOrWhiteSpace($provider)) { "provider 值为空，拒绝自动推断。" } elseif ($provider -notmatch '^[A-Za-z0-9._-]+$') { "provider 值包含未验证字符，拒绝自动改写。" } else { $null })
                        })
                    }
                }
            }
            elseif ($recordType -eq "event_msg" -and $null -ne $payload -and
                [string](Get-JsonPropertyValue -Object $payload -Name "type") -eq "thread_settings_applied") {
                $threadSettings = Get-JsonPropertyValue -Object $payload -Name "thread_settings"
                if ($null -ne $threadSettings) {
                    $providerProperty = $threadSettings.PSObject.Properties["model_provider_id"]
                    if ($null -ne $providerProperty) {
                        $provider = [string]$providerProperty.Value
                        $providerKey = if ([string]::IsNullOrWhiteSpace($provider)) { "<empty>" } else { $provider }
                        if (-not $providerCounts.ContainsKey($providerKey)) {
                            $providerCounts[$providerKey] = 0
                        }
                        $providerCounts[$providerKey]++
                        if ($provider -cne "openai") {
                            $providerItems.Add([pscustomobject]@{
                                LineNumber = $lineNumber
                                RecordType = "thread_settings_applied"
                                Field = "model_provider_id"
                                ThreadId = $null
                                OldProvider = $provider
                                NewProvider = "openai"
                                OldLineSha256 = Get-TextSha256 $line
                                UnsupportedReason = $(if ([string]::IsNullOrWhiteSpace($provider)) { "provider 值为空，拒绝自动推断。" } elseif ($provider -notmatch '^[A-Za-z0-9._-]+$') { "provider 值包含未验证字符，拒绝自动改写。" } else { $null })
                            })
                        }
                    }
                }
            }

            if (-not $isResponseCandidate -or $recordType -ne "response_item" -or $null -eq $payload) {
                continue
            }
            $id = [string](Get-JsonPropertyValue -Object $payload -Name "id")
            $isGenericId = $id.StartsWith("item_", [StringComparison]::Ordinal)
            $isOversizedId = $id.Length -gt 64
            $type = [string](Get-JsonPropertyValue -Object $payload -Name "type")
            $encryptedContent = [string](Get-JsonPropertyValue -Object $payload -Name "encrypted_content")
            $content = Get-JsonPropertyValue -Object $payload -Name "content"
            $hasContent = $null -ne $content -and @($content).Count -gt 0
            $isUnreplayableReasoning = $type -eq "reasoning" -and
                -not [string]::IsNullOrWhiteSpace($id) -and
                [string]::IsNullOrWhiteSpace($encryptedContent) -and -not $hasContent
            if (-not $isGenericId -and -not $isOversizedId -and -not $isUnreplayableReasoning) {
                continue
            }
            if (-not $idCounts.ContainsKey($id)) {
                $idCounts[$id] = 0
            }
            $idCounts[$id]++

            $action = "rename"
            $newId = $null
            $unsupportedReason = $null

            if (-not $script:IdPrefixes.ContainsKey($type)) {
                $unsupportedReason = "不支持自动处理的响应项目类型 '$type'。"
            }
            elseif ($type -eq "reasoning") {
                if ($isUnreplayableReasoning) {
                    $action = "drop"
                }
                elseif ($isGenericId) {
                    $newId = "rs_" + $id.Substring(5)
                }
                else {
                    $unsupportedReason = "推理编号超过 64 字符且带有可恢复内容；保留原记录，拒绝截断或伪造编号。"
                }
            }
            elseif ($isGenericId) {
                $newId = [string]$script:IdPrefixes[$type] + "_" + $id.Substring(5)
            }
            else {
                $unsupportedReason = "响应项目编号超过 64 字符；拒绝自动截断现有编号。"
            }
            if ($null -ne $newId -and $newId.Length -gt 64) {
                $unsupportedReason = "修正前缀后的响应项目编号仍超过 64 字符；拒绝自动截断编号。"
            }

            $items.Add([pscustomobject]@{
                LineNumber = $lineNumber
                RolloutOrdinal = $(
                    $ordinalProperty = $record.PSObject.Properties["ordinal"]
                    if ($null -ne $ordinalProperty) {
                        try { [long]$ordinalProperty.Value } catch { $null }
                    }
                    else { $null }
                )
                Type = $type
                OldId = $id
                NewId = $newId
                Action = $action
                CallId = [string](Get-JsonPropertyValue -Object $payload -Name "call_id")
                OldLineSha256 = Get-TextSha256 $line
                UnsupportedReason = $unsupportedReason
            })
        }
    }
    finally {
        $reader.Dispose()
    }

    if ($threadIds.Count -gt 1) {
        $forkOwner = Get-MaterializedForkThreadId -Path $Path -Metadata $sessionMetadata.ToArray()
        if (-not [string]::IsNullOrWhiteSpace($forkOwner)) {
            $threadIds.Clear()
            [void]$threadIds.Add($forkOwner)
            $isMaterializedFork = $true
        }
    }
    if ($threadIds.Count -eq 1) {
        $onlyThreadId = @($threadIds)[0]
        foreach ($providerItem in $providerItems) {
            if ([string]::IsNullOrWhiteSpace([string]$providerItem.ThreadId)) {
                $providerItem.ThreadId = $onlyThreadId
            }
        }
    }

    $targetIds = @(
        $items |
            Where-Object { $_.Action -eq "rename" -and -not [string]::IsNullOrWhiteSpace([string]$_.NewId) } |
            ForEach-Object { [string]$_.NewId } |
            Sort-Object -Unique
    )
    $targetIdHits = @{}
    foreach ($targetId in $targetIds) {
        $targetIdHits[$targetId] = 0
    }
    if ($targetIds.Count -gt 0) {
        $reader = Open-SharedTextReader $Path
        try {
            while (($line = $reader.ReadLine()) -ne $null) {
                foreach ($targetId in $targetIds) {
                    if ($line.Contains('"' + $targetId + '"')) {
                        $targetIdHits[$targetId]++
                    }
                }
            }
        }
        finally {
            $reader.Dispose()
        }
    }

    foreach ($item in $items) {
        if ($item.Action -eq 'clear_input_ids') { continue }
        if ($idCounts[$item.OldId] -ne 1) {
            $item.UnsupportedReason = "同一个对话文件中重复出现了相同的通用响应项目编号。"
            continue
        }
        if ($item.Action -eq "rename" -and -not [string]::IsNullOrWhiteSpace([string]$item.NewId) -and
            $targetIdHits[$item.NewId] -gt 0) {
            $item.UnsupportedReason = "目标标准编号 '$($item.NewId)' 已经存在于同一个对话文件中。"
        }
    }

    return [pscustomobject]@{
        Path = $Path
        IsPaginated = $isPaginatedHistory
        IsMaterializedFork = $isMaterializedFork
        Excluded = $ExcludedPaths.Contains($Path)
        Items = $items.ToArray()
        ProviderItems = $providerItems.ToArray()
        ProviderCounts = $providerCounts
        ThreadIds = @($threadIds)
        FileIssues = $fileIssues.ToArray()
    }
}

function Get-CompatibilityReport {
    $excludedPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $ExcludePath) {
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            [void]$excludedPaths.Add((Resolve-NormalizedPath $path))
        }
    }

    $fileReports = New-Object System.Collections.Generic.List[object]
    $localThreadIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $jsonlProviderCounts = @{}
    $databaseProviderCounts = @{}
    $renames = 0
    $portableRecords = 0
    $drops = 0
    $providerFileChanges = 0
    $providerDatabaseChanges = 0
    $unsupported = 0
    $excludedItems = 0
    $affectedFiles = 0
    $files = @(Get-RolloutFiles)
    foreach ($file in $files) {
        Write-Verbose "正在扫描历史文件：$file"
        $fileReport = Get-IncrementalFileReport -Path $file -ExcludedPaths $excludedPaths
        foreach ($key in $fileReport.ProviderCounts.Keys) {
            if (-not $jsonlProviderCounts.ContainsKey($key)) {
                $jsonlProviderCounts[$key] = 0
            }
            $jsonlProviderCounts[$key] += [int]$fileReport.ProviderCounts[$key]
        }
        if (-not $fileReport.Excluded) {
            foreach ($threadId in $fileReport.ThreadIds) {
                if (-not [string]::IsNullOrWhiteSpace([string]$threadId)) {
                    [void]$localThreadIds.Add([string]$threadId)
                }
            }
        }

        if ($fileReport.Items.Count -gt 0 -or $fileReport.ProviderItems.Count -gt 0 -or $fileReport.FileIssues.Count -gt 0) {
            $affectedFiles++
        }
        if ($fileReport.Items.Count -gt 0 -or $fileReport.ProviderItems.Count -gt 0 -or
            $fileReport.ProviderCounts.Count -gt 0 -or $fileReport.ThreadIds.Count -gt 0 -or
            $fileReport.FileIssues.Count -gt 0) {
            $fileReports.Add($fileReport)
        }

        foreach ($issue in $fileReport.FileIssues) {
            if ($fileReport.Excluded) {
                $excludedItems++
            }
            else {
                $unsupported++
            }
        }

        foreach ($item in $fileReport.Items) {
            if ($fileReport.Excluded) {
                $excludedItems++
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$item.UnsupportedReason)) {
                $unsupported++
            }
            elseif ($item.Action -eq "drop") {
                $drops++
            }
            elseif ($item.Action -eq 'clear_input_ids') {
                $portableRecords++
            }
            else {
                $renames++
            }
        }
        foreach ($item in $fileReport.ProviderItems) {
            if ($fileReport.Excluded) {
                $excludedItems++
            }
            elseif (-not [string]::IsNullOrWhiteSpace([string]$item.UnsupportedReason)) {
                $unsupported++
            }
            else {
                $providerFileChanges++
            }
        }
    }

    $databaseReports = @(Get-DatabaseCompatibilityReports -ThreadIds $localThreadIds)
    $affectedDatabases = 0
    foreach ($databaseReport in $databaseReports) {
        foreach ($key in $databaseReport.ProviderCounts.Keys) {
            if (-not $databaseProviderCounts.ContainsKey($key)) {
                $databaseProviderCounts[$key] = 0
            }
            $databaseProviderCounts[$key] += [int]$databaseReport.ProviderCounts[$key]
        }
        if ($databaseReport.Changes.Count -gt 0) {
            $affectedDatabases++
            $providerDatabaseChanges += $databaseReport.Changes.Count
        }
    }

    return [pscustomobject]@{
        FilesScanned = $files.Count
        AffectedFiles = $affectedFiles
        DatabasesScanned = $databaseReports.Count
        AffectedDatabases = $affectedDatabases
        Renames = $renames
        PortableRecords = $portableRecords
        Drops = $drops
        ProviderFileChanges = $providerFileChanges
        ProviderDatabaseChanges = $providerDatabaseChanges
        ProviderChanges = $providerFileChanges + $providerDatabaseChanges
        JsonlProviderCounts = $jsonlProviderCounts
        DatabaseProviderCounts = $databaseProviderCounts
        Unsupported = $unsupported
        ExcludedItems = $excludedItems
        Files = $fileReports.ToArray()
        Databases = $databaseReports
        ScanMetrics = [pscustomobject]@{
            SkippedFiles=$script:ScanCounters.SkippedFiles; TailFiles=$script:ScanCounters.TailFiles
            FullFiles=$script:ScanCounters.FullFiles; ParsedBytes=$script:ScanCounters.ParsedBytes
            PrefixVerifiedBytes=$script:ScanCounters.PrefixVerifiedBytes
            ProjectionTailFiles=0; ProjectionFullFiles=0
        }
    }
}

function Assert-ExclusiveAccess {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $stream = New-Object IO.FileStream(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
        $stream.Dispose()
    }
    catch {
        throw "此对话文件仍被 Codex 或其他进程占用：$Path"
    }
}

function Write-RepairedFile {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$ProviderItems
    )

    $layout = Get-FileLayout $SourcePath
    $encoding = if ($layout.HasBom) {
        New-Object System.Text.UTF8Encoding($true)
    }
    else {
        $script:Utf8NoBom
    }

    $itemsByLine = @{}
    foreach ($item in $Items) {
        $itemsByLine[[int]$item.LineNumber] = $item
    }
    $providerItemsByLine = @{}
    foreach ($item in $ProviderItems) {
        $providerItemsByLine[[int]$item.LineNumber] = $item
    }

    $reader = Open-SharedTextReader $SourcePath
    $stream = New-Object IO.FileStream(
        $DestinationPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None,
        1048576,
        [IO.FileOptions]::WriteThrough
    )
    $writer = New-Object IO.StreamWriter($stream, $encoding, 1048576, $true)
    try {
        $lineNumber = 0
        while (($line = $reader.ReadLine()) -ne $null) {
            $lineNumber++
            $hasFollowingLine = $reader.Peek() -ne -1
            $hadLineEnding = $hasFollowingLine -or $layout.HasFinalNewline

            $item = $itemsByLine[$lineNumber]
            if ($null -ne $item) {
                if ((Get-TextSha256 $line) -ne $item.OldLineSha256) {
                    throw "扫描后对话记录发生变化：${SourcePath}:${lineNumber}"
                }
                if ($item.Action -eq "drop") {
                    continue
                }

                $pattern = '(?<before>"id"\s*:\s*")(?<value>' + [regex]::Escape($item.OldId) + ')(?<after>")'
                $matches = [regex]::Matches($line, $pattern)
                if ($matches.Count -ne 1) {
                    throw "预期在 ${SourcePath}:${lineNumber} 找到一个响应项目编号，实际找到 $($matches.Count) 个。"
                }
                $valueGroup = $matches[0].Groups["value"]
                $line = $line.Remove($valueGroup.Index, $valueGroup.Length).Insert($valueGroup.Index, $item.NewId)
                $item | Add-Member -NotePropertyName NewLineSha256 -NotePropertyValue (Get-TextSha256 $line) -Force
            }

            $providerItem = $providerItemsByLine[$lineNumber]
            if ($null -ne $providerItem) {
                if ((Get-TextSha256 $line) -ne $providerItem.OldLineSha256) {
                    throw "扫描后 provider 记录发生变化：${SourcePath}:${lineNumber}"
                }
                $pattern = '(?<before>"' + [regex]::Escape($providerItem.Field) + '"\s*:\s*")(?<value>' +
                    [regex]::Escape($providerItem.OldProvider) + ')(?<after>")'
                $matches = [regex]::Matches($line, $pattern)
                if ($matches.Count -ne 1) {
                    throw "预期在 ${SourcePath}:${lineNumber} 找到一个 provider 字段，实际找到 $($matches.Count) 个。"
                }
                $valueGroup = $matches[0].Groups["value"]
                $line = $line.Remove($valueGroup.Index, $valueGroup.Length).Insert($valueGroup.Index, $providerItem.NewProvider)
                $providerItem | Add-Member -NotePropertyName NewLineSha256 -NotePropertyValue (Get-TextSha256 $line) -Force
            }

            $writer.Write($line)
            if ($hadLineEnding) {
                $writer.Write($layout.Newline)
            }
        }
        $writer.Flush()
        $stream.Flush($true)
    }
    finally {
        $writer.Dispose()
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Test-RepairedJsonl {
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$SyntaxOnly)

    if ($SyntaxOnly -and $PortableInputIds -and [CodexHistoryCompat.PortableHistory]::SupportsFastJson) {
        [void][CodexHistoryCompat.PortableHistory]::ValidateJsonFile($Path, $false)
        return # Full provider/item semantics are checked by the final report.
    }

    $lineNumber = 0
    $genericIds = 0
    $oversizedIds = 0
    $providerMismatches = 0
    $reader = Open-SharedTextReader $Path
    try {
        while (($line = $reader.ReadLine()) -ne $null) {
            $lineNumber++
            if ([string]::IsNullOrWhiteSpace($line)) {
                throw "JSONL 中存在空记录：${Path}:${lineNumber}。"
            }
            try {
                $record = $line | ConvertFrom-Json
            }
            catch {
                throw "修复后的 JSONL 记录无效：${Path}:${lineNumber}：$($_.Exception.Message)"
            }
            $recordType = [string](Get-JsonPropertyValue -Object $record -Name "type")
            $payload = Get-JsonPropertyValue -Object $record -Name "payload"
            if ($null -eq $payload) {
                continue
            }
            if ($recordType -eq "session_meta") {
                $providerProperty = $payload.PSObject.Properties["model_provider"]
                if ($null -ne $providerProperty -and [string]$providerProperty.Value -cne "openai") {
                    $providerMismatches++
                }
            }
            elseif ($recordType -eq "event_msg" -and
                [string](Get-JsonPropertyValue -Object $payload -Name "type") -eq "thread_settings_applied") {
                $threadSettings = Get-JsonPropertyValue -Object $payload -Name "thread_settings"
                if ($null -ne $threadSettings) {
                    $providerProperty = $threadSettings.PSObject.Properties["model_provider_id"]
                    if ($null -ne $providerProperty -and [string]$providerProperty.Value -cne "openai") {
                        $providerMismatches++
                    }
                }
            }
            if ($recordType -ne "response_item") {
                continue
            }
            $id = [string](Get-JsonPropertyValue -Object $payload -Name "id")
            if ($id.StartsWith("item_", [StringComparison]::Ordinal)) {
                $genericIds++
            }
            if ($id.Length -gt 64) {
                $oversizedIds++
            }
        }
    }
    finally {
        $reader.Dispose()
    }
    if ($genericIds -ne 0) {
        throw "修复后的对话仍包含 $genericIds 个通用响应项目编号：$Path"
    }
    if ($oversizedIds -ne 0) {
        throw "修复后的对话仍包含 $oversizedIds 个超过 64 字符的响应项目编号：$Path"
    }
    if ($providerMismatches -ne 0) {
        throw "修复后的对话仍包含 $providerMismatches 个非 openai provider 字段：$Path"
    }
}

function ConvertTo-PaginatedReplacementText {
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)][long]$OriginalBodyBytes
    )

    $replacement = [ordered]@{}
    foreach ($name in @("timestamp", "ordinal")) {
        $property = $Record.PSObject.Properties[$name]
        if ($null -ne $property) {
            $replacement[$name] = $property.Value
        }
    }
    $replacement["type"] = "event_msg"
    $replacement["payload"] = [ordered]@{
        type = "token_count"
        info = $null
        rate_limits = $null
    }
    $text = $replacement | ConvertTo-Json -Compress -Depth 12
    $length = [long]$script:Utf8NoBom.GetByteCount($text)
    if ($length -gt $OriginalBodyBytes) {
        throw "分页历史的等长占位记录放不进原始字节槽位（需要 $length 字节，原槽位 $OriginalBodyBytes 字节）。"
    }
    return $text + (" " * [int]($OriginalBodyBytes - $length))
}

function Write-PaginatedRepairedFile {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Items,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$ProviderItems
    )

    $layout = Get-FileLayout $SourcePath
    if ($PortableInputIds -and $ProviderItems.Count -eq 0 -and
        @($Items | Where-Object { $_.Action -ne 'clear_input_ids' }).Count -eq 0) {
        [CodexHistoryCompat.PortableHistory]::WriteFile($SourcePath,$DestinationPath,
            [CodexHistoryCompat.PortableRecord[]]$Items,$layout.HasBom,$layout.Newline,$layout.HasFinalNewline)
        return
    }
    $encoding = if ($layout.HasBom) {
        New-Object System.Text.UTF8Encoding($true)
    }
    else {
        $script:Utf8NoBom
    }
    $itemsByLine = @{}
    foreach ($item in $Items) {
        $itemsByLine[[int]$item.LineNumber] = $item
    }
    $providerItemsByLine = @{}
    foreach ($item in $ProviderItems) {
        $providerItemsByLine[[int]$item.LineNumber] = $item
    }

    $reader = Open-SharedTextReader $SourcePath
    $stream = New-Object IO.FileStream(
        $DestinationPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None,
        1048576,
        [IO.FileOptions]::WriteThrough
    )
    $writer = New-Object IO.StreamWriter($stream, $encoding, 1048576, $true)
    try {
        $lineNumber = 0
        while (($line = $reader.ReadLine()) -ne $null) {
            $lineNumber++
            $hasFollowingLine = $reader.Peek() -ne -1
            $hadLineEnding = $hasFollowingLine -or $layout.HasFinalNewline
            $originalBodyBytes = [long]$script:Utf8NoBom.GetByteCount($line)

            $item = $itemsByLine[$lineNumber]
            if ($null -ne $item) {
                if ((Get-TextSha256 $line) -ne $item.OldLineSha256) {
                    throw "扫描后分页对话记录发生变化：${SourcePath}:${lineNumber}"
                }
                if ($item.Action -eq "drop") {
                    $record = $line | ConvertFrom-Json
                    $line = ConvertTo-PaginatedReplacementText -Record $record -OriginalBodyBytes $originalBodyBytes
                    $item | Add-Member -NotePropertyName NewLineSha256 -NotePropertyValue (Get-TextSha256 $line) -Force
                }
                elseif ($item.Action -eq 'clear_input_ids') {
                    $line = [CodexHistoryCompat.PortableHistory]::Clear($line)
                    if ([long]$script:Utf8NoBom.GetByteCount($line) -ne $originalBodyBytes) {
                        throw "清除模型重放编号改变了原始字节槽位：${SourcePath}:${lineNumber}"
                    }
                    $item | Add-Member -NotePropertyName NewLineSha256 -NotePropertyValue (Get-TextSha256 $line) -Force
                }
                else {
                    $pattern = '(?<before>"id"\s*:\s*")(?<value>' + [regex]::Escape($item.OldId) + ')(?<after>")'
                    $matches = [regex]::Matches($line, $pattern)
                    if ($matches.Count -ne 1) {
                        throw "预期在 ${SourcePath}:${lineNumber} 找到一个分页响应项目编号，实际找到 $($matches.Count) 个。"
                    }
                    $valueGroup = $matches[0].Groups["value"]
                    $line = $line.Remove($valueGroup.Index, $valueGroup.Length).Insert($valueGroup.Index, $item.NewId)
                    $newLength = [long]$script:Utf8NoBom.GetByteCount($line)
                    if ($newLength -gt $originalBodyBytes) {
                        throw "分页历史响应项目编号变长，无法保持原始字节偏移：${SourcePath}:${lineNumber}"
                    }
                    $line += (" " * [int]($originalBodyBytes - $newLength))
                    $item | Add-Member -NotePropertyName NewLineSha256 -NotePropertyValue (Get-TextSha256 $line) -Force
                }
            }

            $providerItem = $providerItemsByLine[$lineNumber]
            if ($null -ne $providerItem) {
                if ((Get-TextSha256 $line) -ne $providerItem.OldLineSha256) {
                    throw "扫描后分页 provider 记录发生变化：${SourcePath}:${lineNumber}"
                }
                $pattern = '(?<before>"' + [regex]::Escape($providerItem.Field) + '"\s*:\s*")(?<value>' +
                    [regex]::Escape($providerItem.OldProvider) + ')(?<after>")'
                $matches = [regex]::Matches($line, $pattern)
                if ($matches.Count -ne 1) {
                    throw "预期在 ${SourcePath}:${lineNumber} 找到一个分页 provider 字段，实际找到 $($matches.Count) 个。"
                }
                $valueGroup = $matches[0].Groups["value"]
                $line = $line.Remove($valueGroup.Index, $valueGroup.Length).Insert($valueGroup.Index, $providerItem.NewProvider)
                $newLength = [long]$script:Utf8NoBom.GetByteCount($line)
                if ($newLength -gt $originalBodyBytes) {
                    throw "分页 provider 字段变长，无法保持原始字节偏移：${SourcePath}:${lineNumber}"
                }
                $line += (" " * [int]($originalBodyBytes - $newLength))
                $providerItem | Add-Member -NotePropertyName NewLineSha256 -NotePropertyValue (Get-TextSha256 $line) -Force
            }

            $writer.Write($line)
            if ($hadLineEnding) {
                $writer.Write($layout.Newline)
            }
        }
        $writer.Flush()
        $stream.Flush($true)
    }
    finally {
        $writer.Dispose()
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Get-SqliteProjectionRows {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [long]$RolloutOrdinal,
        [string]$OldItemId,
        [switch]$AllForThread
    )

    $threadLiteral = ConvertTo-SqlStringLiteral $ThreadId
    $oldItemLiteral = ConvertTo-SqlStringLiteral $OldItemId
    $filter = if ($AllForThread) { "" } else { " AND (rollout_ordinal=$RolloutOrdinal OR item_id=$oldItemLiteral)" }
    $sql = "SELECT hex(turn_id)||'|'||hex(item_id)||'|'||rollout_ordinal||'|'||created_at_ms||'|'||hex(item_json)||'|'||hex(item_type)||'|'||updated_at_ordinal FROM thread_items WHERE thread_id=$threadLiteral$filter ORDER BY rollout_ordinal,turn_id,item_id;"
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($line in @(Invoke-SqliteLines -Path $Path -ReadOnly -Sql $sql)) {
        if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
        $parts = ([string]$line).Split([char[]]@('|'), 7)
        if ($parts.Count -ne 7) {
            throw "分页 SQLite 投影查询返回了无法解析的记录：$Path"
        }
        $rows.Add([pscustomobject]@{
            ThreadId = $ThreadId
            TurnId = ConvertFrom-HexUtf8 $parts[0]
            ItemId = ConvertFrom-HexUtf8 $parts[1]
            RolloutOrdinal = [long]$parts[2]
            CreatedAtMs = [long]$parts[3]
            ItemJson = ConvertFrom-HexUtf8 $parts[4]
            ItemType = ConvertFrom-HexUtf8 $parts[5]
            UpdatedAtOrdinal = [long]$parts[6]
        })
    }
    return $rows.ToArray()
}

function New-PaginatedProjectionDropChange {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$TurnReferences
    )

    return [pscustomobject]@{
        Action = "drop"
        ThreadId = $Row.ThreadId
        TurnId = $Row.TurnId
        ItemId = $Row.ItemId
        RolloutOrdinal = $Row.RolloutOrdinal
        CreatedAtMs = $Row.CreatedAtMs
        ItemJson = $Row.ItemJson
        ItemType = $Row.ItemType
        UpdatedAtOrdinal = $Row.UpdatedAtOrdinal
        NewItemId = $null
        NewItemJson = $null
        TurnReferences = @($TurnReferences)
    }
}

function ConvertTo-SqlNullableStringLiteral {
    param([AllowNull()][object]$Value)

    if ($null -eq $Value) {
        return "NULL"
    }
    return ConvertTo-SqlStringLiteral ([string]$Value)
}

function Get-SqliteThreadTurnReferences {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][string]$OldItemId
    )

    $schemaCount = [int](@(Invoke-SqliteLines -Path $Path -ReadOnly -Sql "SELECT COUNT(*) FROM pragma_table_info('thread_turns') WHERE name IN ('thread_id','turn_id','first_user_item_id','final_agent_item_id');")[0])
    if ($schemaCount -eq 0) {
        return @()
    }
    if ($schemaCount -ne 4) {
        throw "SQLite thread_turns 表缺少引用字段：$Path"
    }

    $threadLiteral = ConvertTo-SqlStringLiteral $ThreadId
    $oldLiteral = ConvertTo-SqlStringLiteral $OldItemId
    $sql = @"
SELECT hex(turn_id) || '|' ||
       CASE WHEN first_user_item_id IS NULL THEN '<NULL>' ELSE hex(first_user_item_id) END || '|' ||
       CASE WHEN final_agent_item_id IS NULL THEN '<NULL>' ELSE hex(final_agent_item_id) END
FROM thread_turns
WHERE thread_id=$threadLiteral AND (first_user_item_id=$oldLiteral OR final_agent_item_id=$oldLiteral)
ORDER BY turn_id;
"@
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($line in @(Invoke-SqliteLines -Path $Path -ReadOnly -Sql $sql)) {
        if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
        $parts = ([string]$line).Split([char[]]@('|'), 3)
        if ($parts.Count -ne 3) {
            throw "SQLite thread_turns 引用查询返回了无法解析的记录：$Path"
        }
        $first = if ($parts[1] -ceq "<NULL>") { $null } else { ConvertFrom-HexUtf8 $parts[1] }
        $final = if ($parts[2] -ceq "<NULL>") { $null } else { ConvertFrom-HexUtf8 $parts[2] }
        $rows.Add([pscustomobject]@{
            ThreadId = $ThreadId
            TurnId = ConvertFrom-HexUtf8 $parts[0]
            FirstUserItemId = $first
            FinalAgentItemId = $final
        })
    }
    return $rows.ToArray()
}

function Get-SqliteThreadTurnReference {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ThreadId,
        [Parameter(Mandatory = $true)][string]$TurnId
    )

    $schemaCount = [int](@(Invoke-SqliteLines -Path $Path -ReadOnly -Sql "SELECT COUNT(*) FROM pragma_table_info('thread_turns') WHERE name IN ('thread_id','turn_id','first_user_item_id','final_agent_item_id');")[0])
    if ($schemaCount -eq 0) {
        return $null
    }
    if ($schemaCount -ne 4) {
        throw "SQLite thread_turns 表缺少引用字段：$Path"
    }
    $threadLiteral = ConvertTo-SqlStringLiteral $ThreadId
    $turnLiteral = ConvertTo-SqlStringLiteral $TurnId
    $sql = @"
SELECT hex(turn_id) || '|' ||
       CASE WHEN first_user_item_id IS NULL THEN '<NULL>' ELSE hex(first_user_item_id) END || '|' ||
       CASE WHEN final_agent_item_id IS NULL THEN '<NULL>' ELSE hex(final_agent_item_id) END
FROM thread_turns
WHERE thread_id=$threadLiteral AND turn_id=$turnLiteral;
"@
    $lines = @(Invoke-SqliteLines -Path $Path -ReadOnly -Sql $sql)
    if ($lines.Count -eq 0) {
        return $null
    }
    if ($lines.Count -ne 1) {
        throw "SQLite thread_turns 引用查询返回重复轮次：$Path / $ThreadId / $TurnId"
    }
    $parts = ([string]$lines[0]).Split([char[]]@('|'), 3)
    if ($parts.Count -ne 3) {
        throw "SQLite thread_turns 单轮次引用无法解析：$Path"
    }
    return [pscustomobject]@{
        ThreadId = $ThreadId
        TurnId = ConvertFrom-HexUtf8 $parts[0]
        FirstUserItemId = if ($parts[1] -ceq "<NULL>") { $null } else { ConvertFrom-HexUtf8 $parts[1] }
        FinalAgentItemId = if ($parts[2] -ceq "<NULL>") { $null } else { ConvertFrom-HexUtf8 $parts[2] }
    }
}

function Get-PaginatedJournalBoundary {
    param([Parameter(Mandatory = $true)][string]$Path, [string]$IndependentThreadId)

    if ($PortableInputIds -and [CodexHistoryCompat.PortableHistory]::SupportsFastJson) {
        $last = [CodexHistoryCompat.PortableHistory]::ValidateJsonFile($Path, $true, $IndependentThreadId)
        return [pscustomobject]@{ LastOrdinal=$last; NextOrdinal=($last + 1) }
    }

    $reader = Open-SharedTextReader $Path
    $lineNumber = 0
    $lastOrdinal = $null
    try {
        while (($line = $reader.ReadLine()) -ne $null) {
            $lineNumber++
            try {
                $record = $line | ConvertFrom-Json
            }
            catch {
                throw "分页历史包含无法解析的 JSONL 记录：${Path}:${lineNumber}：$($_.Exception.Message)"
            }
            $ordinalProperty = $record.PSObject.Properties["ordinal"]
            if ($null -eq $ordinalProperty) {
                throw "分页历史记录缺少 ordinal，拒绝推断游标：${Path}:$lineNumber"
            }
            $ordinal = 0L
            if (-not [long]::TryParse([string]$ordinalProperty.Value, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$ordinal) -or $ordinal -lt 0) {
                throw "分页历史 ordinal 无效，拒绝推断游标：${Path}:$lineNumber"
            }
            if ($null -ne $lastOrdinal -and $ordinal -le $lastOrdinal) {
                throw "分页历史 ordinal 不严格递增，拒绝推断游标：${Path}:$lineNumber"
            }
            if (-not [string]::IsNullOrWhiteSpace($IndependentThreadId)) {
                if ($ordinal -ne ($lineNumber - 1)) {
                    throw "独立分页分段 ordinal 未从零连续排列，拒绝自动改写：${Path}:$lineNumber"
                }
                $recordType = [string](Get-JsonPropertyValue $record 'type')
                if ($lineNumber -eq 1 -and $recordType -cne 'session_meta') {
                    throw "独立分页分段缺少起始元数据：$Path"
                }
                $payload = Get-JsonPropertyValue $record 'payload'
                if ($recordType -ceq 'session_meta') {
                    $sessionId = Get-JsonPropertyValue $payload 'session_id'
                    if ([string](Get-JsonPropertyValue $payload 'id') -cne $IndependentThreadId -or
                        [string](Get-JsonPropertyValue $payload 'history_mode') -cne 'paginated' -or
                        ($null -ne $sessionId -and [string]$sessionId -cne $IndependentThreadId) -or
                        $null -ne (Get-JsonPropertyValue $payload 'history_base') -or
                        $null -ne (Get-JsonPropertyValue $payload 'forked_from_id') -or
                        $null -ne (Get-JsonPropertyValue $payload 'forked_from_ordinal_exclusive')) {
                        throw "独立分页分段仍有继承信息或归属冲突，拒绝自动改写：${Path}:$lineNumber"
                    }
                }
                elseif ($recordType -ceq 'event_msg') {
                    $eventThread = Get-JsonPropertyValue $payload 'thread_id'
                    if ($null -ne $eventThread -and [string]$eventThread -cne $IndependentThreadId) {
                        throw "独立分页分段含有其他会话的事件，拒绝自动改写：${Path}:$lineNumber"
                    }
                }
            }
            $lastOrdinal = $ordinal
        }
    }
    finally {
        $reader.Dispose()
    }
    if ($null -eq $lastOrdinal) {
        throw "分页历史为空，拒绝推断游标：$Path"
    }
    return [pscustomobject]@{
        LastOrdinal = [long]$lastOrdinal
        NextOrdinal = [long]($lastOrdinal + 1)
    }
}

function Test-SqliteThreadTurnReferenceMatch {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)]$Reference,
        [Parameter(Mandatory = $true)][string]$OldItemId,
        [Parameter(Mandatory = $true)][string]$NewItemId,
        [switch]$Repaired
    )

    $expectedFirst = $Reference.FirstUserItemId
    $expectedFinal = $Reference.FinalAgentItemId
    if ($Repaired) {
        if ([string]$Reference.FirstUserItemId -ceq $OldItemId) { $expectedFirst = $NewItemId }
        if ([string]$Reference.FinalAgentItemId -ceq $OldItemId) { $expectedFinal = $NewItemId }
    }
    $firstMatches = if ($null -eq $expectedFirst) { $null -eq $Row.FirstUserItemId } else { [string]$Row.FirstUserItemId -ceq [string]$expectedFirst }
    $finalMatches = if ($null -eq $expectedFinal) { $null -eq $Row.FinalAgentItemId } else { [string]$Row.FinalAgentItemId -ceq [string]$expectedFinal }
    return ([string]$Row.ThreadId -ceq [string]$Reference.ThreadId -and
        [string]$Row.TurnId -ceq [string]$Reference.TurnId -and
        $firstMatches -and $finalMatches)
}

function Test-SqliteThreadTurnState {
    param(
        [AllowNull()]$ActualFirstUserItemId,
        [AllowNull()]$ActualFinalAgentItemId,
        [AllowNull()]$ExpectedFirstUserItemId,
        [AllowNull()]$ExpectedFinalAgentItemId
    )

    $firstMatches = if ($null -eq $ExpectedFirstUserItemId) { $null -eq $ActualFirstUserItemId } else { [string]$ActualFirstUserItemId -ceq [string]$ExpectedFirstUserItemId }
    $finalMatches = if ($null -eq $ExpectedFinalAgentItemId) { $null -eq $ActualFinalAgentItemId } else { [string]$ActualFinalAgentItemId -ceq [string]$ExpectedFinalAgentItemId }
    return $firstMatches -and $finalMatches
}

function Test-EmptyTerminalSubagentProjection {
    param([string]$Path, [string]$DatabasePath, [string]$ThreadId, [string]$LogicalThreadId)

    # Native subagents can stop before their first UI item. Prove the exact
    # terminal lifecycle instead of treating every empty projection as safe.
    if ($ThreadId -cne $LogicalThreadId) { return $false }
    $thread = ConvertTo-SqlStringLiteral $ThreadId
    $required = @(Invoke-SqliteLines -Path $DatabasePath -ReadOnly -Sql "SELECT COUNT(*) FROM pragma_table_info('thread_turns') WHERE name IN ('thread_id','turn_id','rollout_ordinal','status','first_user_item_id','final_agent_item_id','rollout_byte_offset','rollout_end_ordinal','rollout_end_byte_offset','root_turn_id');")
    if ([int]$required[0] -ne 10) { return $false }
    $count = @(Invoke-SqliteLines -Path $DatabasePath -ReadOnly -Sql "SELECT COUNT(*) FROM thread_items WHERE thread_id=$thread;")
    if ([long]$count[0] -ne 0) { return $false }
    $turns = @(Invoke-SqliteLines -Path $DatabasePath -ReadOnly -Sql "SELECT json_object('id',turn_id,'ordinal',rollout_ordinal,'status',status,'first',first_user_item_id,'final',final_agent_item_id,'start',rollout_byte_offset,'end_ordinal',rollout_end_ordinal,'end_offset',rollout_end_byte_offset,'root',root_turn_id) FROM thread_turns WHERE thread_id=$thread;")
    if ($turns.Count -ne 1) { return $false }
    $turn = $turns[0] | ConvertFrom-Json
    if ($turn.status -cnotin @('failed','interrupted') -or $null -ne $turn.first -or $null -ne $turn.final -or
        [string]::IsNullOrWhiteSpace([string]$turn.id) -or [string]::IsNullOrWhiteSpace([string]$turn.root) -or
        $null -eq $turn.start -or $null -eq $turn.end_ordinal -or $null -eq $turn.end_offset -or
        [long]$turn.ordinal -ne 1 -or [long]$turn.end_offset -ne (Get-Item -LiteralPath $Path).Length) { return $false }

    $number = 0L; $started = $false; $terminal = $false; $agentPath = $null
    foreach ($line in [CodexHistoryCompat.IncrementalIo]::ReadLines($Path, 0, 0)) {
        $record = $line.Text | ConvertFrom-Json
        $ordinal = Get-JsonPropertyValue $record 'ordinal'
        $kind = [string](Get-JsonPropertyValue $record 'type')
        $payload = Get-JsonPropertyValue $record 'payload'
        if ($null -eq $ordinal -or [long]$ordinal -ne $number -or $null -eq $payload -or $terminal) { return $false }
        if ($number -eq 0) {
            if ($kind -cne 'session_meta' -or [string](Get-JsonPropertyValue $payload 'id') -cne $LogicalThreadId -or
                [string](Get-JsonPropertyValue $payload 'history_mode') -cne 'paginated' -or
                [string](Get-JsonPropertyValue $payload 'thread_source') -cne 'subagent' -or
                $null -ne (Get-JsonPropertyValue $payload 'history_base') -or
                $null -ne (Get-JsonPropertyValue $payload 'forked_from_id') -or
                $null -ne (Get-JsonPropertyValue $payload 'forked_from_ordinal_exclusive')) { return $false }
            $source = Get-JsonPropertyValue $payload 'source'
            $subagent = if ($null -ne $source) { Get-JsonPropertyValue $source 'subagent' } else { $null }
            $spawn = if ($null -ne $subagent) { Get-JsonPropertyValue $subagent 'thread_spawn' } else { $null }
            if ($null -eq $spawn) { return $false }
            $parent = [string](Get-JsonPropertyValue $spawn 'parent_thread_id')
            $agentPath = [string](Get-JsonPropertyValue $spawn 'agent_path')
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $LogicalThreadId -or
                $parent -cne [string](Get-JsonPropertyValue $payload 'parent_thread_id') -or
                $parent -cne [string](Get-JsonPropertyValue $payload 'session_id') -or
                [long](Get-JsonPropertyValue $spawn 'depth') -lt 1 -or
                -not $agentPath.StartsWith('/root/', [StringComparison]::Ordinal)) { return $false }
        }
        elseif ($kind -ceq 'event_msg') {
            $eventType = [string](Get-JsonPropertyValue $payload 'type')
            switch -CaseSensitive ($eventType) {
                'task_started' {
                    if ($started -or $number -ne 1 -or $line.Offset -ne [long]$turn.start) { return $false }
                    $started = $true
                }
                'task_complete' {
                    if ($turn.status -cne 'failed' -or -not $started -or $number -ne [long]$turn.end_ordinal -or
                        $null -eq (Get-JsonPropertyValue $payload 'error') -or
                        $null -ne (Get-JsonPropertyValue $payload 'last_agent_message')) { return $false }
                    $terminal = $true
                }
                'turn_aborted' {
                    if ($turn.status -cne 'interrupted' -or -not $started -or $number -ne [long]$turn.end_ordinal -or
                        [string](Get-JsonPropertyValue $payload 'reason') -cne 'interrupted') { return $false }
                    $terminal = $true
                }
                'thread_settings_applied' {
                    if ([string](Get-JsonPropertyValue $payload 'thread_id') -cne $LogicalThreadId) { return $false }
                }
                'token_count' { }
                default { return $false }
            }
            if ($eventType -cin @('task_started','task_complete','turn_aborted') -and
                ([string](Get-JsonPropertyValue $payload 'turn_id') -cne [string]$turn.id -or
                 [string](Get-JsonPropertyValue $payload 'root_turn_id') -cne [string]$turn.root)) { return $false }
        }
        elseif ($kind -ceq 'response_item') {
            $itemType = [string](Get-JsonPropertyValue $payload 'type')
            if ($itemType -ceq 'message') {
                if ([string](Get-JsonPropertyValue $payload 'role') -cnotin @('system','developer','user')) { return $false }
            }
            elseif ($itemType -ceq 'additional_tools') {
                if ([string](Get-JsonPropertyValue $payload 'role') -cne 'developer') { return $false }
            }
            elseif ($itemType -ceq 'agent_message') {
                if ([string](Get-JsonPropertyValue $payload 'recipient') -cne $agentPath -or
                    [string]::IsNullOrWhiteSpace([string](Get-JsonPropertyValue $payload 'author'))) { return $false }
            }
            else { return $false }
        }
        elseif ($kind -ceq 'turn_context') {
            if ([string](Get-JsonPropertyValue $payload 'turn_id') -cne [string]$turn.id -or
                [string](Get-JsonPropertyValue $payload 'root_turn_id') -cne [string]$turn.root) { return $false }
        }
        elseif ($kind -cnotin @('world_state','inter_agent_communication_metadata')) { return $false }
        if ($number -gt 1 -and -not $started) { return $false }
        $number++
    }
    return $started -and $terminal -and $number -eq (1 + [long]$turn.end_ordinal)
}

function Get-PaginatedEventProjectionEvidence {
    param([string]$Path, [string]$DatabasePath, [string]$ThreadId, [string]$LogicalThreadId,
        [switch]$PortableOnly, [switch]$NonVisualOnly, $PreviousCertificate)

    if ([string]::IsNullOrWhiteSpace($LogicalThreadId)) { $LogicalThreadId = $ThreadId }

    # Native Desktop projects UI events, not the adjacent model response items.
    # Establish provenance for EVERY existing UI row before accepting that layout.
    # A same-ID row at another ordinal is not, by itself, sufficient evidence.
    $outputs = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if (-not $script:ProjectionSchemaCounts.ContainsKey($DatabasePath)) {
        $schemaCount = @(Invoke-SqliteLines -Path $DatabasePath -ReadOnly -Sql "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('thread_items','thread_turns','thread_history_projection_state');")
        $script:ProjectionSchemaCounts[$DatabasePath] = [int]$schemaCount[0]
    }
    if ($script:ProjectionSchemaCounts[$DatabasePath] -ne 3) {
        return [pscustomobject]@{ Verified=$false; OutputCallIds=$outputs; Fingerprint=$null }
    }
    $beforeFingerprint = Get-ThreadProjectionFingerprint -Path $DatabasePath -ThreadId $ThreadId
    if ($PortableOnly -and [CodexHistoryCompat.PortableHistory]::SupportsFastJson) {
        $thread = ConvertTo-SqlStringLiteral $ThreadId
        $sql = "SELECT json_object('turn',turn_id,'id',item_id,'type',item_type,'ordinal',rollout_ordinal,'updated',updated_at_ordinal,'json_id',json_extract(item_json,'$.id'),'json_type',json_extract(item_json,'$.type')) FROM thread_items WHERE thread_id=$thread;"
        $startOffset=0L
        $oldWitness=if ($null -ne $PreviousCertificate) {Get-JsonPropertyValue $PreviousCertificate 'ProjectionWitness'} else {$null}
        if ($null -ne $oldWitness -and $oldWitness.Rows -gt 0 -and $oldWitness.ThreadId -ceq $ThreadId -and
            $oldWitness.LogicalThreadId -ceq $LogicalThreadId -and
            (Get-ThreadProjectionFingerprint -Path $DatabasePath -ThreadId $ThreadId -NoCursor -BeforeOrdinal ([long]$oldWitness.NextOrdinal)) -ceq $oldWitness.UiHash) {
            $startOffset=[long]$PreviousCertificate.Length
            $sql=$sql.TrimEnd(';') + " AND (rollout_ordinal >= $($oldWitness.NextOrdinal) OR updated_at_ordinal >= $($oldWitness.NextOrdinal));"
        }
        $summaryRows = [string[]]@(Invoke-SqliteLines -Path $DatabasePath -ReadOnly -Sql $sql)
        if ($startOffset -gt 0) { $script:ScanCounters.ProjectionTailFiles++ } else { $script:ScanCounters.ProjectionFullFiles++ }
        $noDanglingTurns = $true
        if ($summaryRows.Count -eq 0) {
            $refs = @(Invoke-SqliteLines -Path $DatabasePath -ReadOnly -Sql "SELECT COUNT(*) FROM thread_turns WHERE thread_id=$thread AND (first_user_item_id IS NOT NULL OR final_agent_item_id IS NOT NULL);")
            $noDanglingTurns = [long]$refs[0] -eq 0
        }
        $verified = if ($startOffset -gt 0 -and $summaryRows.Count -eq 0) { $true } else {
            [CodexHistoryCompat.PortableHistory]::VerifyEventSources($Path,$LogicalThreadId,$summaryRows,[bool]$NonVisualOnly,$noDanglingTurns,$startOffset)
        }
        if (-not $verified -and $startOffset -eq 0 -and $summaryRows.Count -eq 0 -and $noDanglingTurns) {
            $verified = Test-EmptyTerminalSubagentProjection -Path $Path -DatabasePath $DatabasePath -ThreadId $ThreadId -LogicalThreadId $LogicalThreadId
        }
        if ($verified -and (Get-ThreadProjectionFingerprint -Path $DatabasePath -ThreadId $ThreadId) -cne $beforeFingerprint) {
            throw "界面投影在核对来源期间发生变化，拒绝继续：$ThreadId"
        }
        if ($verified) {
            $cursor=@(Invoke-SqliteLines -Path $DatabasePath -ReadOnly -Sql "SELECT next_rollout_ordinal FROM thread_history_projection_state WHERE thread_id=$thread;")
            $count=@(Invoke-SqliteLines -Path $DatabasePath -ReadOnly -Sql "SELECT COUNT(*) FROM thread_items WHERE thread_id=$thread;")
            $script:ProjectionWitnesses[$Path]=[pscustomobject]@{ThreadId=$ThreadId;LogicalThreadId=$LogicalThreadId;Rows=[long]$count[0];
                NextOrdinal=[long]$cursor[0];UiHash=(Get-ThreadProjectionFingerprint -Path $DatabasePath -ThreadId $ThreadId -NoCursor)}
        }
        return [pscustomobject]@{ Verified=$verified; OutputCallIds=$outputs; Fingerprint=$beforeFingerprint }
    }
    $script:ScanCounters.ProjectionFullFiles++
    $rows = @(Get-SqliteProjectionRows -Path $DatabasePath -ThreadId $ThreadId -AllForThread)
    $events = @{}
    $wanted = [Collections.Generic.HashSet[long]]::new()
    foreach ($row in $rows) {
        [void]$wanted.Add([long]$row.RolloutOrdinal)
        [void]$wanted.Add([long]$row.UpdatedAtOrdinal)
    }
    $reader = Open-SharedTextReader $Path
    $nativeEvents = 0
    $nativeEventsValid = $true
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            # Parse only possible sources and tool results. Large unrelated model
            # payloads are already checked by the journal validator.
            $ordinalMatch = [regex]::Match($line, '"ordinal"\s*:\s*(\d+)')
            $sourceCandidate = $ordinalMatch.Success -and $wanted.Contains([long]$ordinalMatch.Groups[1].Value)
            $emptyCandidate = $rows.Count -eq 0 -and $line.Contains('"item_completed"')
            $outputCandidate = -not $PortableOnly -and
                ($line.Contains('"function_call_output"') -or $line.Contains('"custom_tool_call_output"'))
            if (-not $sourceCandidate -and -not $emptyCandidate -and -not $outputCandidate) { continue }
            $record = $line | ConvertFrom-Json
            $ordinal = [long](Get-JsonPropertyValue $record "ordinal")
            if ($wanted.Contains($ordinal)) { $events[$ordinal] = $record }
            $payload = Get-JsonPropertyValue $record "payload"
            if ($rows.Count -eq 0 -and [string](Get-JsonPropertyValue $record 'type') -ceq 'event_msg' -and
                [string](Get-JsonPropertyValue $payload 'type') -ceq 'item_completed') {
                $nativeEvents++
                $eventItem = Get-JsonPropertyValue $payload 'item'
                if ([string](Get-JsonPropertyValue $payload 'thread_id') -cne $LogicalThreadId -or
                    [string]::IsNullOrWhiteSpace([string](Get-JsonPropertyValue $payload 'turn_id')) -or
                    [string]::IsNullOrWhiteSpace([string](Get-JsonPropertyValue $eventItem 'id')) -or
                    [string]::IsNullOrWhiteSpace([string](Get-JsonPropertyValue $eventItem 'type'))) { $nativeEventsValid = $false }
            }
            if ([string](Get-JsonPropertyValue $record "type") -eq "response_item" -and
                [string](Get-JsonPropertyValue $payload "type") -in @("function_call_output", "custom_tool_call_output")) {
                $callId = [string](Get-JsonPropertyValue $payload "call_id")
                if (-not [string]::IsNullOrWhiteSpace($callId)) { [void]$outputs.Add($callId) }
            }
        }
    }
    finally { $reader.Dispose() }

    $verified = $rows.Count -gt 0
    if ($rows.Count -eq 0 -and $PortableOnly -and $nativeEventsValid -and ($nativeEvents -gt 0 -or $NonVisualOnly)) {
        # Evicted/sub-agent projections can have a valid cursor but no UI rows.
        # There must be no dangling turn reference; UI source events remain
        # byte-identical, or this is an invisible compaction-only history.
        $refs = @(Invoke-SqliteLines -Path $DatabasePath -ReadOnly -Sql "SELECT COUNT(*) FROM thread_turns WHERE thread_id=$(ConvertTo-SqlStringLiteral $ThreadId) AND (first_user_item_id IS NOT NULL OR final_agent_item_id IS NOT NULL);")
        $verified = [long]$refs[0] -eq 0
    }
    foreach ($row in $rows) {
        $projected = $row.ItemJson | ConvertFrom-Json
        foreach ($ordinal in @([long]$row.RolloutOrdinal, [long]$row.UpdatedAtOrdinal)) {
            $source = $events[$ordinal]
            if ($null -eq $source -or [string](Get-JsonPropertyValue $source "type") -cne "event_msg") {
                $verified = $false
                break
            }
            $payload = Get-JsonPropertyValue $source "payload"
            if ($null -eq $payload) { $verified = $false; break }
            $item = Get-JsonPropertyValue $payload "item"
            if ($null -eq $item) { $verified = $false; break }
            $type = [string](Get-JsonPropertyValue $item "type")
            $projectedType = if ($type.Length -gt 0) { $type.Substring(0,1).ToLowerInvariant() + $type.Substring(1) } else { "" }
            if ($type -ceq "Extension" -and [string](Get-JsonPropertyValue $item "kind") -ceq "clock.sleep") {
                $projectedType = "sleep"
            }
            elseif ($type -ceq "Extension" -and [string](Get-JsonPropertyValue $item "kind") -ceq "web.search") {
                # The native UI projects this extension as webSearch. Keep all
                # thread/turn/ID/ordinal checks; other extension kinds stay untrusted.
                $projectedType = "webSearch"
            }
            if ([string](Get-JsonPropertyValue $source "type") -cne "event_msg" -or
                [string](Get-JsonPropertyValue $payload "type") -cne "item_completed" -or
                [string](Get-JsonPropertyValue $payload "thread_id") -cne $LogicalThreadId -or
                [string](Get-JsonPropertyValue $payload "turn_id") -cne $row.TurnId -or
                [string](Get-JsonPropertyValue $item "id") -cne $row.ItemId -or
                [string](Get-JsonPropertyValue $projected "id") -cne $row.ItemId -or
                [string](Get-JsonPropertyValue $projected "type") -cne $row.ItemType -or
                $projectedType -cne $row.ItemType) {
                $verified = $false
                break
            }
        }
        if (-not $verified) { break }
    }
    if (-not $verified -and $PortableOnly -and $rows.Count -eq 0) {
        $verified = Test-EmptyTerminalSubagentProjection -Path $Path -DatabasePath $DatabasePath -ThreadId $ThreadId -LogicalThreadId $LogicalThreadId
    }
    if ($verified -and (Get-ThreadProjectionFingerprint -Path $DatabasePath -ThreadId $ThreadId) -cne $beforeFingerprint) {
        throw "界面投影在核对来源期间发生变化，拒绝继续：$ThreadId"
    }
    return [pscustomobject]@{ Verified=$verified; OutputCallIds=$outputs; Fingerprint=$beforeFingerprint }
}

function Get-ThreadProjectionFingerprint {
    param([string]$Path, [string]$ThreadId, [switch]$NoCursor, [long]$BeforeOrdinal = -1)
    $thread = ConvertTo-SqlStringLiteral $ThreadId
    if (-not $script:ProjectionFingerprintColumns.ContainsKey($Path)) {
        $schema = [ordered]@{}
        foreach ($table in @('thread_items','thread_turns','thread_history_projection_state')) {
            $columns = @(Invoke-SqliteLines -Path $Path -ReadOnly -Sql "PRAGMA table_info($table);")
            if ($columns.Count -eq 0) { throw "分页投影缺少 $table，拒绝推断界面状态。" }
            $expressions = @($columns | ForEach-Object {
                $name = ([string]$_).Split('|')[1].Replace('"','""')
                'quote("' + $name + '")'
            })
            $schema[$table] = $expressions -join "||'|'||"
        }
        $script:ProjectionFingerprintColumns[$Path] = $schema
    }
    # One sqlite process per complete fingerprint, retaining every column and
    # explicit empty-table markers. Avoid thousands of Windows process starts.
    $statements = New-Object Collections.Generic.List[string]
    foreach ($entry in $script:ProjectionFingerprintColumns[$Path].GetEnumerator()) {
        $table = $entry.Key
        if ($NoCursor -and $table -ceq 'thread_history_projection_state') { continue }
        $filter=''
        if ($BeforeOrdinal -ge 0) {
            $filter=" AND rollout_ordinal < $BeforeOrdinal"
            if ($table -ceq 'thread_items') { $filter += " AND updated_at_ordinal < $BeforeOrdinal" }
        }
        $statements.Add("SELECT '$table'; SELECT '$table|'||hex($($entry.Value)) FROM $table WHERE thread_id=$thread$filter;")
    }
    $lines = [string[]]@(Invoke-SqliteLines -Path $Path -ReadOnly -Sql ([string]::Join("`n",$statements.ToArray())))
    [Array]::Sort($lines,[StringComparer]::Ordinal)
    return Get-TextSha256 ([string]::Join("`n",$lines))
}

function Assert-PreservedEventProjections {
    param([AllowEmptyCollection()][object[]]$Plans)
    foreach ($plan in $Plans) {
        $expected = Get-JsonPropertyValue $plan "PreservedProjectionFingerprint"
        if ($null -ne $expected -and
            (Get-ThreadProjectionFingerprint -Path $plan.Path -ThreadId $plan.ThreadId) -cne $expected) {
            throw "界面投影在历史修复期间发生变化，拒绝继续：$($plan.ThreadId)"
        }
    }
}

function Get-PaginatedProjectionIdentity {
    param([string]$Path, [string]$LogicalThreadId, [Parameter(Mandatory = $true)][ref]$IndependentSegment)

    $IndependentSegment.Value = $false

    # Continuations retain session_meta.id, but the native projection is keyed
    # by the segment UUID (the second UUID), not that logical conversation ID.
    $uuid = '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
    $name = [IO.Path]::GetFileName($Path)
    $match = [regex]::Match($name, ('^rollout-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-(?<logical>' + $uuid + ')_(?<segment>' + $uuid + ')\.jsonl$'))
    if (-not $match.Success) { return $LogicalThreadId }
    if ($match.Groups['logical'].Value -cne $LogicalThreadId) {
        throw "分页分段文件名与会话编号不一致，拒绝自动改写：$Path"
    }
    $reader = Open-SharedTextReader $Path
    try { $first = $reader.ReadLine() | ConvertFrom-Json }
    finally { $reader.Dispose() }
    $meta = Get-JsonPropertyValue $first 'payload'
    if ([string](Get-JsonPropertyValue $first 'type') -cne 'session_meta' -or
        $null -eq $meta -or [string](Get-JsonPropertyValue $meta 'id') -cne $LogicalThreadId -or
        [string](Get-JsonPropertyValue $meta 'history_mode') -cne 'paginated') {
        throw "分页分段缺少有效的会话元数据，拒绝自动改写：$Path"
    }
    $base = Get-JsonPropertyValue $meta 'history_base'
    $endOrdinal = 0L
    $endOffset = 0L
    $firstOrdinal = -1L
    if ($null -eq $base -and
        [long]::TryParse([string](Get-JsonPropertyValue $first 'ordinal'), [ref]$firstOrdinal) -and
        $firstOrdinal -eq 0 -and
        $null -eq (Get-JsonPropertyValue $meta 'forked_from_id') -and
        $null -eq (Get-JsonPropertyValue $meta 'forked_from_ordinal_exclusive')) {
        # Fully materialized segments keep their physical two-UUID filenames.
        # Validate every record's ownership/ancestry and zero-based contiguous
        # ordinals below; existing cursor and UI-source checks still apply.
        $IndependentSegment.Value = $true
        return $match.Groups['segment'].Value
    }
    if ($null -eq $base -or
        [string](Get-JsonPropertyValue $base 'thread_id') -cnotmatch ('^' + $uuid + '$') -or
        -not [long]::TryParse([string](Get-JsonPropertyValue $base 'end_ordinal_exclusive'), [ref]$endOrdinal) -or
        -not [long]::TryParse([string](Get-JsonPropertyValue $base 'end_byte_offset'), [ref]$endOffset) -or
        -not [long]::TryParse([string](Get-JsonPropertyValue $first 'ordinal'), [ref]$firstOrdinal) -or
        $endOrdinal -lt 1 -or $endOffset -lt 1 -or $firstOrdinal -ne $endOrdinal) {
        throw "分页分段继承边界无效，拒绝自动改写：$Path"
    }
    return $match.Groups['segment'].Value
}

function Get-VerifiedLegacyLayoutSource {
    param($FileReport, [long]$ExpectedLength)

    # Narrow recovery for old v2 repairs which physically deleted a record.
    # Never infer padding/ordinals from a stale DB cursor. The live file must
    # still be EXACTLY the old transaction output, with an intact original.
    if (-not $PortableInputIds -or -not [IO.Directory]::Exists($BackupRoot)) { return $null }
    $livePath = Resolve-NormalizedPath $FileReport.Path
    $liveHash = Get-FileSha256 $livePath
    $backupPrefix = (Resolve-NormalizedPath $BackupRoot).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    foreach ($manifestPath in @(Get-ChildItem -LiteralPath $BackupRoot -Filter manifest.json -File -Recurse)) {
        try { $oldManifest = [IO.File]::ReadAllText($manifestPath.FullName, $script:Utf8NoBom) | ConvertFrom-Json }
        catch { continue }
        if ([int](Get-JsonPropertyValue $oldManifest 'version') -ne 2 -or
            [string](Get-JsonPropertyValue $oldManifest 'status') -cne 'complete') { continue }
        foreach ($entry in @($oldManifest.files)) {
            if ((Resolve-NormalizedPath ([string]$entry.path)) -ine $livePath -or
                [string]$entry.repaired_sha256 -cne $liveHash -or [long]$entry.original_length -ne $ExpectedLength -or
                [string]$entry.status -cne 'applied') { continue }
            $sourcePath = Resolve-NormalizedPath ([string]$entry.backup_path)
            if (-not $sourcePath.StartsWith($backupPrefix, [StringComparison]::OrdinalIgnoreCase) -or
                -not [IO.File]::Exists($sourcePath) -or (Get-Item -LiteralPath $sourcePath).Length -ne $ExpectedLength -or
                (Get-FileSha256 $sourcePath) -cne [string]$entry.original_sha256) { continue }
            $changes = @{}
            foreach ($change in @($entry.changes)) {
                if ([string]$change.kind -cne 'response_item' -or $change.action -notin @('drop','rename') -or
                    $changes.ContainsKey([int]$change.line_number)) { throw '旧修复清单包含未验证的操作，拒绝恢复字节布局。' }
                $changes[[int]$change.line_number] = $change
            }
            $original = Open-SharedTextReader $sourcePath
            $current = Open-SharedTextReader $livePath
            $lineNumber = 0
            $seen = 0
            try {
                while ($null -ne ($line = $original.ReadLine())) {
                    $lineNumber++
                    $change = $changes[$lineNumber]
                    if ($null -ne $change) {
                        $seen++
                        if ((Get-TextSha256 $line) -cne [string]$change.old_line_sha256) { throw '旧修复原行哈希不匹配。' }
                        $record = $line | ConvertFrom-Json
                        if ([string]$record.type -cne 'response_item' -or [string]$record.payload.id -cne [string]$change.old_id) { throw '旧修复对象不匹配。' }
                        if ($change.action -eq 'drop') {
                            $content = Get-JsonPropertyValue $record.payload 'content'
                            if ([string]$record.payload.type -cne 'reasoning' -or
                                -not [string]::IsNullOrWhiteSpace([string](Get-JsonPropertyValue $record.payload 'encrypted_content')) -or
                                ($null -ne $content -and @($content).Count -gt 0)) { throw '旧删除项包含可重放内容，拒绝推断恢复。' }
                            continue
                        }
                        $pattern = '"id"\s*:\s*"(?<value>' + [regex]::Escape([string]$change.old_id) + ')"'
                        $matches = [regex]::Matches($line, $pattern)
                        if ($matches.Count -ne 1) { throw '旧修复改名范围不唯一。' }
                        $value = $matches[0].Groups['value']
                        $line = $line.Remove($value.Index,$value.Length).Insert($value.Index,[string]$change.new_id)
                        if ((Get-TextSha256 $line) -cne [string]$change.new_line_sha256) { throw '旧修复结果行哈希不匹配。' }
                    }
                    if ($line -cne $current.ReadLine()) { throw '旧备份与现有历史存在清单之外的差异，拒绝恢复。' }
                }
                if ($null -ne $current.ReadLine() -or $seen -ne $changes.Count) { throw '旧修复范围与现有历史不一致。' }
            }
            finally { $original.Dispose(); $current.Dispose() }
            $excluded = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            $baseline = Get-FileCompatibilityItems -Path $sourcePath -ExcludedPaths $excluded
            if (-not $baseline.IsPaginated -or $baseline.ThreadIds.Count -ne 1 -or
                $baseline.ThreadIds[0] -cne $FileReport.ThreadIds[0] -or $baseline.FileIssues.Count -gt 0 -or
                @($baseline.Items | Where-Object { -not [string]::IsNullOrWhiteSpace($_.UnsupportedReason) }).Count -gt 0 -or
                @($baseline.ProviderItems | Where-Object { -not [string]::IsNullOrWhiteSpace($_.UnsupportedReason) }).Count -gt 0) {
                throw '旧备份未通过当前兼容检查，拒绝恢复。'
            }
            $FileReport.Items = $baseline.Items
            $FileReport.ProviderItems = $baseline.ProviderItems
            return [pscustomobject]@{ Path=$sourcePath; Sha256=[string]$entry.original_sha256; Length=$ExpectedLength; Manifest=$manifestPath.FullName; ExpectedLiveSha256=$liveHash }
        }
    }
    return $null
}

function Get-PaginatedProjectionPlans {
    param([Parameter(Mandatory = $true)]$Report)

    $plans = New-Object System.Collections.Generic.List[object]
    $paginatedReports = @($Report.Files | Where-Object {
        -not $_.Excluded -and $_.IsPaginated -and $_.Items.Count -gt 0
    })
    if ($paginatedReports.Count -eq 0) {
        return $plans.ToArray()
    }

    $databasePath = Join-Path $CodexHome "thread_history_1.sqlite"
    if (-not [IO.File]::Exists($databasePath)) {
        throw "发现需要改写的分页历史，但缺少 thread_history_1.sqlite；为避免历史显示错乱，已停止。"
    }

    $seenProjectionIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $cursorRows = @{}
    foreach ($row in @(Invoke-SqliteLines -Path $databasePath -ReadOnly -Sql "SELECT hex(thread_id)||'|'||next_rollout_byte_offset||'|'||next_rollout_ordinal FROM thread_history_projection_state;")) {
        $parts = ([string]$row).Split([char[]]@('|'),3)
        if ($parts.Count -ne 3) { throw '分页历史 SQLite 投影游标格式无效。' }
        $id = ConvertFrom-HexUtf8 $parts[0]
        if ($cursorRows.ContainsKey($id)) { throw "分页历史 SQLite 投影游标重复：$id" }
        $cursorRows[$id] = $parts[1] + '|' + $parts[2]
    }
    foreach ($fileReport in $paginatedReports) {
        if ($fileReport.ThreadIds.Count -ne 1) {
            throw "分页历史文件必须只对应一个本地线程：$($fileReport.Path)"
        }
        $logicalThreadId = [string]$fileReport.ThreadIds[0]
        $independentSegment = $false
        $threadId = Get-PaginatedProjectionIdentity -Path $fileReport.Path -LogicalThreadId $logicalThreadId -IndependentSegment ([ref]$independentSegment)
        if (-not $seenProjectionIds.Add($threadId)) {
            throw "多个分页文件指向同一段数据库投影，拒绝自动改写：$threadId"
        }
        if (-not $cursorRows.ContainsKey($threadId)) {
            throw "分页历史缺少 SQLite 投影游标，拒绝自动改写：$threadId"
        }
        $stateParts = ([string]$cursorRows[$threadId]).Split([char[]]@('|'), 2)
        if ($stateParts.Count -ne 2) {
            throw "分页历史 SQLite 投影游标格式无效，拒绝自动改写：$threadId"
        }
        $nextByteOffset = 0L
        $nextOrdinal = 0L
        if (-not [long]::TryParse($stateParts[0], [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$nextByteOffset) -or
            -not [long]::TryParse($stateParts[1], [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$nextOrdinal) -or
            $nextByteOffset -lt 0 -or $nextOrdinal -lt 0) {
            throw "分页历史 SQLite 投影游标数值无效，拒绝自动改写：$threadId"
        }
        $sourcePath = $fileReport.Path
        $journalLength = (Get-Item -LiteralPath $sourcePath).Length
        if ($nextByteOffset -ne $journalLength) {
            $source = Get-VerifiedLegacyLayoutSource -FileReport $fileReport -ExpectedLength $nextByteOffset
            if ($null -eq $source) {
                throw "分页历史 SQLite 投影游标没有对齐 JSONL 文件末尾，且没有可精确核对的旧修复备份，拒绝自动改写：$threadId"
            }
            $sourcePath = $source.Path
            $fileReport | Add-Member -NotePropertyName LayoutSource -NotePropertyValue $source -Force
            Write-Host "已核实旧修复备份，将在本轮事务内恢复原有字节位置：$threadId"
        }
        $independentThread = if ($independentSegment) { $logicalThreadId } else { $null }
        if (-not $independentSegment -and [long](Get-JsonPropertyValue $fileReport 'ScanStartOffset') -gt 0 -and
            $sourcePath -ceq $fileReport.Path) {
            $journalBoundary=[pscustomobject]@{NextOrdinal=1+[long]$fileReport.TailLastOrdinal}
        } else {
            $journalBoundary = Get-PaginatedJournalBoundary -Path $sourcePath -IndependentThreadId $independentThread
        }
        if ($nextOrdinal -ne $journalBoundary.NextOrdinal) {
            throw "分页历史 SQLite 下一 ordinal 与 JSONL 不一致，拒绝自动改写：$threadId（SQLite=$nextOrdinal，JSONL=$($journalBoundary.NextOrdinal)）"
        }

        $projectionChanges = New-Object System.Collections.Generic.List[object]
        $portableOnly = @($fileReport.Items | Where-Object { $_.Action -ne 'clear_input_ids' }).Count -eq 0
        $nonVisualOnly = $portableOnly -and @($fileReport.Items | Where-Object { -not $_.NonVisualOnly }).Count -eq 0
        $eventEvidence = Get-PaginatedEventProjectionEvidence -Path $sourcePath -DatabasePath $databasePath -ThreadId $threadId -LogicalThreadId $logicalThreadId -PortableOnly:$portableOnly -NonVisualOnly:$nonVisualOnly -PreviousCertificate (Get-JsonPropertyValue $fileReport 'PreviousCertificate')
        $isMaterializedFork = [bool](Get-JsonPropertyValue $fileReport 'IsMaterializedFork')
        if (($threadId -cne $logicalThreadId -or $isMaterializedFork) -and -not $eventEvidence.Verified) {
            throw "分页分段的界面事件来源无法核实，拒绝自动改写：$threadId"
        }
        $uiFingerprint = if ($eventEvidence.Verified) { $eventEvidence.Fingerprint } else { $null }
        foreach ($item in @($fileReport.Items)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$item.UnsupportedReason)) { continue }
            if ($null -eq $item.RolloutOrdinal) {
                throw "分页历史响应项目缺少 rollout ordinal，拒绝自动改写：$($fileReport.Path):$($item.LineNumber)"
            }
            if ([long]$item.RolloutOrdinal -ge $nextOrdinal) {
                throw "分页历史响应项目尚未进入 SQLite 投影游标范围，拒绝自动改写：$threadId ordinal=$($item.RolloutOrdinal) next=$nextOrdinal"
            }
            if ($item.Action -eq 'clear_input_ids') {
                if (-not $eventEvidence.Verified) {
                    throw "模型编号与界面索引未证实独立，拒绝清除：$threadId"
                }
                # The fully verified UI projection comes exclusively from
                # unchanged event_msg records. Its IDs and DB stay untouched.
                continue
            }
            $rows = @(Get-SqliteProjectionRows -Path $databasePath -ThreadId $threadId -RolloutOrdinal ([long]$item.RolloutOrdinal) -OldItemId ([string]$item.OldId))
            if ($item.Action -eq "drop" -and $rows.Count -eq 0 -and $eventEvidence.Verified) {
                # Some older paginated relays emitted a separate visible
                # Reasoning event with a different UI ID and never projected
                # the adjacent model item into thread_items. There is no
                # database row to delete or rename; confirm that no turn still
                # references the bad model ID, then keep the UI event intact.
                $orphanTurnReferences = @(Get-SqliteThreadTurnReferences -Path $databasePath -ThreadId $threadId -OldItemId ([string]$item.OldId))
                if ($orphanTurnReferences.Count -eq 0) { continue }
                throw "分页 SQLite 轮次仍引用无投影的待删除项目，拒绝自动改写：$threadId ordinal=$($item.RolloutOrdinal)"
            }
            if ($eventEvidence.Verified) {
                # UI IDs and turn references belong to their unchanged event_msg.
                # Repair only the model-facing response_item; never erase visible
                # reasoning or rename the independently sourced UI projection.
                $expectedType = switch ($item.Type) {
                    "reasoning" { "reasoning" }
                    "message" { "agentMessage" }
                    default { $null }
                }
                if ($null -ne $expectedType -and $rows.Count -eq 1 -and
                    $rows[0].ItemId -ceq $item.OldId -and $rows[0].ItemType -ceq $expectedType -and
                    $rows[0].RolloutOrdinal -ne $item.RolloutOrdinal) { continue }
                # Native function_call response IDs have no UI row. Require a
                # verified event-only projection and an intact tool-result pair.
                if ($rows.Count -eq 0 -and $item.Type -eq "function_call" -and
                    $eventEvidence.OutputCallIds.Contains([string]$item.CallId)) { continue }
                throw "分页界面事件与模型响应无法安全对应：$threadId ordinal=$($item.RolloutOrdinal)"
            }
            if ($rows.Count -ne 1) {
                throw "分页 SQLite 投影与 JSONL 无法一一对应：$threadId ordinal=$($item.RolloutOrdinal) old_id=$($item.OldId)（匹配 $($rows.Count) 行）。"
            }
            $row = $rows[0]
            if ([long]$row.RolloutOrdinal -ne [long]$item.RolloutOrdinal -or [string]$row.ItemId -cne [string]$item.OldId) {
                throw "分页 SQLite 投影内容与 JSONL 不一致：$threadId ordinal=$($item.RolloutOrdinal)。"
            }
            $turnReferences = @(Get-SqliteThreadTurnReferences -Path $databasePath -ThreadId $threadId -OldItemId ([string]$item.OldId))
            if ($item.Action -eq "drop" -and $turnReferences.Count -gt 0) {
                throw "分页 SQLite 轮次仍引用待删除项目，拒绝留下悬空引用：$threadId ordinal=$($item.RolloutOrdinal)"
            }
            $newItemJson = [string]$row.ItemJson
            if ($item.Action -eq "drop") {
                $projectionChanges.Add((New-PaginatedProjectionDropChange -Row $row -TurnReferences @()))
                continue
            }
            $pattern = '(?<before>"id"\s*:\s*")(?<value>' + [regex]::Escape([string]$item.OldId) + ')(?<after>")'
            $matches = [regex]::Matches($newItemJson, $pattern)
            if ($matches.Count -ne 1) {
                throw "分页 SQLite item_json 中找不到唯一旧编号：$threadId ordinal=$($item.RolloutOrdinal)"
            }
            $valueGroup = $matches[0].Groups["value"]
            $newItemJson = $newItemJson.Remove($valueGroup.Index, $valueGroup.Length).Insert($valueGroup.Index, [string]$item.NewId)
            $conflictSql = "SELECT COUNT(*) FROM thread_items WHERE thread_id=$(ConvertTo-SqlStringLiteral $threadId) AND item_id=$(ConvertTo-SqlStringLiteral ([string]$item.NewId));"
            $conflictCount = [int](@(Invoke-SqliteLines -Path $databasePath -ReadOnly -Sql $conflictSql)[0])
            if ($conflictCount -ne 0) {
                throw "分页 SQLite 投影目标编号已经存在：$threadId / $($item.NewId)"
            }
            $projectionChanges.Add([pscustomobject]@{
                Action = "rename"
                ThreadId = $threadId
                TurnId = $row.TurnId
                ItemId = $row.ItemId
                RolloutOrdinal = $row.RolloutOrdinal
                CreatedAtMs = $row.CreatedAtMs
                ItemJson = $row.ItemJson
                ItemType = $row.ItemType
                UpdatedAtOrdinal = $row.UpdatedAtOrdinal
                NewItemId = [string]$item.NewId
                NewItemJson = $newItemJson
                TurnReferences = $turnReferences
            })
        }
        if ($projectionChanges.Count -gt 0 -or $eventEvidence.Verified) {
            $plans.Add([pscustomobject]@{
                Path = $databasePath
                ThreadId = $threadId
                LogicalThreadId = $logicalThreadId
                ProjectionChanges = $projectionChanges.ToArray()
                PreservedProjectionFingerprint = $uiFingerprint
            })
        }
    }
    return $plans.ToArray()
}

function Test-SqliteProjectionRowMatch {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)]$Change,
        [switch]$Repaired
    )

    $expectedId = if ($Repaired) { [string]$Change.NewItemId } else { [string]$Change.ItemId }
    $expectedJson = if ($Repaired) { [string]$Change.NewItemJson } else { [string]$Change.ItemJson }
    return ([string]$Row.ThreadId -ceq [string]$Change.ThreadId -and
        [string]$Row.TurnId -ceq [string]$Change.TurnId -and
        [string]$Row.ItemId -ceq $expectedId -and
        [long]$Row.RolloutOrdinal -eq [long]$Change.RolloutOrdinal -and
        [long]$Row.CreatedAtMs -eq [long]$Change.CreatedAtMs -and
        [string]$Row.ItemJson -ceq $expectedJson -and
        [string]$Row.ItemType -ceq [string]$Change.ItemType -and
        [long]$Row.UpdatedAtOrdinal -eq [long]$Change.UpdatedAtOrdinal)
}

function Set-SqliteProjectionRows {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Changes,
        [Parameter(Mandatory = $true)][ValidateSet("forward", "rollback")][string]$Direction
    )

    if ($Changes.Count -eq 0) { return }
    $turnReferenceGroups = @{}
    foreach ($change in $Changes) {
        foreach ($reference in @(
            Get-JsonPropertyValue -Object $change -Name "TurnReferences" |
                Where-Object { $null -ne $_ }
        )) {
            $groupKey = [string]$reference.ThreadId + "`0" + [string]$reference.TurnId
            if (-not $turnReferenceGroups.ContainsKey($groupKey)) {
                $turnReferenceGroups[$groupKey] = [pscustomobject]@{
                    Reference = $reference
                    Changes = New-Object System.Collections.Generic.List[object]
                }
            }
            else {
                $knownReference = $turnReferenceGroups[$groupKey].Reference
                if (-not (Test-SqliteThreadTurnState -ActualFirstUserItemId $knownReference.FirstUserItemId -ActualFinalAgentItemId $knownReference.FinalAgentItemId -ExpectedFirstUserItemId $reference.FirstUserItemId -ExpectedFinalAgentItemId $reference.FinalAgentItemId)) {
                    throw "同一 SQLite 轮次的引用快照不一致，拒绝改写：$($reference.ThreadId) / $($reference.TurnId)"
                }
            }
            $turnReferenceGroups[$groupKey].Changes.Add($change)
        }
    }
    $statements = New-Object System.Collections.Generic.List[string]
    $statements.Add("CREATE TEMP TABLE IF NOT EXISTS history_compat_write_guard (affected INTEGER CHECK(affected=1));")
    $statements.Add("BEGIN IMMEDIATE;")
    foreach ($change in $Changes) {
        $turnReferences = @(
            Get-JsonPropertyValue -Object $change -Name "TurnReferences" |
                Where-Object { $null -ne $_ }
        )
        $rows = @(Get-SqliteProjectionRows -Path $Path -ThreadId ([string]$change.ThreadId) -RolloutOrdinal ([long]$change.RolloutOrdinal) -OldItemId ([string]$change.ItemId))
        $turnReferencesAreOriginal = $true
        if ($turnReferences.Count -gt 0) {
            foreach ($reference in $turnReferences) {
                $currentReference = Get-SqliteThreadTurnReference -Path $Path -ThreadId ([string]$reference.ThreadId) -TurnId ([string]$reference.TurnId)
                if ($null -eq $currentReference -or
                    -not (Test-SqliteThreadTurnReferenceMatch -Row $currentReference -Reference $reference -OldItemId ([string]$change.ItemId) -NewItemId ([string]$change.NewItemId))) {
                    $turnReferencesAreOriginal = $false
                    break
                }
            }
        }
        if ($Direction -eq "rollback" -and $rows.Count -eq 1 -and
            (Test-SqliteProjectionRowMatch -Row $rows[0] -Change $change) -and
            $turnReferencesAreOriginal) {
            # A failed SQLite transaction may already have left the old row
            # intact. Manual rollback may also be invoked more than once.
            continue
        }
        $isDrop = [string]$change.Action -eq "drop"
        if ($Direction -eq "rollback" -and $isDrop) {
            if ($rows.Count -ne 0) {
                throw "分页投影回滚目标已被其他内容占用，拒绝覆盖：$($change.ThreadId) ordinal=$($change.RolloutOrdinal)"
            }
        }
        elseif ($rows.Count -ne 1 -or
            -not (Test-SqliteProjectionRowMatch -Row $rows[0] -Change $change -Repaired:($Direction -eq "rollback"))) {
            throw "分页 SQLite 投影在处理前发生变化，拒绝覆盖：$($change.ThreadId) ordinal=$($change.RolloutOrdinal)"
        }
        $thread = ConvertTo-SqlStringLiteral ([string]$change.ThreadId)
        $turn = ConvertTo-SqlStringLiteral ([string]$change.TurnId)
        $old = ConvertTo-SqlStringLiteral ([string]$change.ItemId)
        $new = ConvertTo-SqlStringLiteral ([string]$change.NewItemId)
        $oldJson = ConvertTo-SqlStringLiteral ([string]$change.ItemJson)
        $newJson = ConvertTo-SqlStringLiteral ([string]$change.NewItemJson)
        $itemType = ConvertTo-SqlStringLiteral ([string]$change.ItemType)
        $rowGuard = "thread_id=$thread AND turn_id=$turn AND rollout_ordinal=$([long]$change.RolloutOrdinal) AND created_at_ms=$([long]$change.CreatedAtMs) AND item_type=$itemType AND updated_at_ordinal=$([long]$change.UpdatedAtOrdinal)"
        if ($Direction -eq "forward") {
            if ($isDrop) {
                $statements.Add("DELETE FROM thread_items WHERE $rowGuard AND item_id=$old AND item_json=$oldJson;")
            }
            else {
                $statements.Add("UPDATE thread_items SET item_id=$new, item_json=$newJson WHERE $rowGuard AND item_id=$old AND item_json=$oldJson;")
            }
        }
        else {
            if ($isDrop) {
                $statements.Add("INSERT INTO thread_items (thread_id,turn_id,item_id,rollout_ordinal,created_at_ms,item_json,item_type,updated_at_ordinal) VALUES ($thread,$turn,$old,$([long]$change.RolloutOrdinal),$([long]$change.CreatedAtMs),$oldJson,$itemType,$([long]$change.UpdatedAtOrdinal));")
            }
            else {
                $statements.Add("UPDATE thread_items SET item_id=$old, item_json=$oldJson WHERE $rowGuard AND item_id=$new AND item_json=$newJson;")
            }
        }
        $statements.Add("INSERT INTO history_compat_write_guard VALUES(changes());")
    }
    foreach ($group in $turnReferenceGroups.Values) {
        $reference = $group.Reference
        $referenceThread = ConvertTo-SqlStringLiteral ([string]$reference.ThreadId)
        $referenceTurn = ConvertTo-SqlStringLiteral ([string]$reference.TurnId)
        $originalFirst = $reference.FirstUserItemId
        $originalFinal = $reference.FinalAgentItemId
        $repairedFirst = $originalFirst
        $repairedFinal = $originalFinal
        foreach ($change in $group.Changes) {
            if ([string]$reference.FirstUserItemId -ceq [string]$change.ItemId) { $repairedFirst = [string]$change.NewItemId }
            if ([string]$reference.FinalAgentItemId -ceq [string]$change.ItemId) { $repairedFinal = [string]$change.NewItemId }
        }
        $expectedFirst = if ($Direction -eq "forward") { $originalFirst } else { $repairedFirst }
        $expectedFinal = if ($Direction -eq "forward") { $originalFinal } else { $repairedFinal }
        $targetFirst = if ($Direction -eq "forward") { $repairedFirst } else { $originalFirst }
        $targetFinal = if ($Direction -eq "forward") { $repairedFinal } else { $originalFinal }
        $currentReference = Get-SqliteThreadTurnReference -Path $Path -ThreadId ([string]$reference.ThreadId) -TurnId ([string]$reference.TurnId)
        if ($null -eq $currentReference) {
            throw "SQLite thread_turns 中找不到待处理轮次：$($reference.ThreadId) / $($reference.TurnId)"
        }
        if (Test-SqliteThreadTurnState -ActualFirstUserItemId $currentReference.FirstUserItemId -ActualFinalAgentItemId $currentReference.FinalAgentItemId -ExpectedFirstUserItemId $targetFirst -ExpectedFinalAgentItemId $targetFinal) {
            continue
        }
        if (-not (Test-SqliteThreadTurnState -ActualFirstUserItemId $currentReference.FirstUserItemId -ActualFinalAgentItemId $currentReference.FinalAgentItemId -ExpectedFirstUserItemId $expectedFirst -ExpectedFinalAgentItemId $expectedFinal)) {
            throw "SQLite thread_turns 在处理前发生变化，拒绝覆盖：$($reference.ThreadId) / $($reference.TurnId)"
        }
        $firstGuard = if ($null -eq $expectedFirst) { "first_user_item_id IS NULL" } else { "first_user_item_id=" + (ConvertTo-SqlStringLiteral $expectedFirst) }
        $finalGuard = if ($null -eq $expectedFinal) { "final_agent_item_id IS NULL" } else { "final_agent_item_id=" + (ConvertTo-SqlStringLiteral $expectedFinal) }
        $targetFirstSql = ConvertTo-SqlNullableStringLiteral $targetFirst
        $targetFinalSql = ConvertTo-SqlNullableStringLiteral $targetFinal
        $statements.Add(
            "UPDATE thread_turns SET first_user_item_id=$targetFirstSql, final_agent_item_id=$targetFinalSql WHERE thread_id=$referenceThread AND turn_id=$referenceTurn AND $firstGuard AND $finalGuard;"
        )
        $statements.Add("INSERT INTO history_compat_write_guard VALUES(changes());")
    }
    $statements.Add("COMMIT;")
    [void](Invoke-SqliteScript -Path $Path -Sql ([string]::Join([Environment]::NewLine, $statements.ToArray())))

    foreach ($change in $Changes) {
        $rows = @(Get-SqliteProjectionRows -Path $Path -ThreadId ([string]$change.ThreadId) -RolloutOrdinal ([long]$change.RolloutOrdinal) -OldItemId ([string]$change.ItemId))
        if ($Direction -eq "forward" -and [string]$change.Action -eq "drop") {
            if ($rows.Count -ne 0) { throw "分页 SQLite 删除后仍存在投影行：$($change.ThreadId) ordinal=$($change.RolloutOrdinal)" }
        }
        elseif ($rows.Count -ne 1) {
            throw "分页 SQLite 投影写入后行数异常：$($change.ThreadId) ordinal=$($change.RolloutOrdinal)"
        }
        elseif (-not (Test-SqliteProjectionRowMatch -Row $rows[0] -Change $change -Repaired:($Direction -eq "forward"))) {
            throw "分页 SQLite 投影内容验证失败：$($change.ThreadId) ordinal=$($change.RolloutOrdinal)"
        }
    }
    foreach ($group in $turnReferenceGroups.Values) {
        $reference = $group.Reference
        $expectedFirst = $reference.FirstUserItemId
        $expectedFinal = $reference.FinalAgentItemId
        if ($Direction -eq "forward") {
            foreach ($change in $group.Changes) {
                if ([string]$reference.FirstUserItemId -ceq [string]$change.ItemId) { $expectedFirst = [string]$change.NewItemId }
                if ([string]$reference.FinalAgentItemId -ceq [string]$change.ItemId) { $expectedFinal = [string]$change.NewItemId }
            }
        }
        $currentReference = Get-SqliteThreadTurnReference -Path $Path -ThreadId ([string]$reference.ThreadId) -TurnId ([string]$reference.TurnId)
        if ($null -eq $currentReference -or
            -not (Test-SqliteThreadTurnState -ActualFirstUserItemId $currentReference.FirstUserItemId -ActualFinalAgentItemId $currentReference.FinalAgentItemId -ExpectedFirstUserItemId $expectedFirst -ExpectedFinalAgentItemId $expectedFinal)) {
            throw "分页 SQLite 轮次引用写入后验证失败：$($reference.ThreadId) turn=$($reference.TurnId)"
        }
    }
    Assert-SqliteQuickCheck -Path $Path
}

function Invoke-SqliteScript {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Sql
    )

    $executable = Get-SqliteExecutable
    $databaseArgument = ([Uri][IO.Path]::GetFullPath($Path)).AbsoluteUri
    $output = $Sql | & $executable -batch -bail -cmd ".timeout 5000" $databaseArgument 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        $message = (@($output) | ForEach-Object { [string]$_ }) -join "; "
        throw "SQLite 写入失败（退出码 $exitCode）：$Path：$message"
    }
    return @($output | ForEach-Object { [string]$_ })
}

function Copy-SqliteBackup {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    [IO.Directory]::CreateDirectory((Split-Path -Parent $DestinationPath)) | Out-Null
    if ([IO.File]::Exists($DestinationPath)) {
        throw "SQLite 备份目标已经存在：$DestinationPath"
    }
    $escapedDestination = $DestinationPath.Replace("'", "''")
    [void](Invoke-SqliteScript -Path $SourcePath -Sql (".backup '" + $escapedDestination + "'"))
    if (-not [IO.File]::Exists($DestinationPath)) {
        throw "SQLite 备份未生成：$DestinationPath"
    }
    Assert-SqliteQuickCheck -Path $DestinationPath
}

function Set-SqliteProviderRows {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Changes,
        [Parameter(Mandatory = $true)][ValidateSet("forward", "rollback")][string]$Direction
    )

    if ($Changes.Count -eq 0) {
        return
    }
    $threadIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($change in $Changes) {
        [void]$threadIds.Add([string]$change.ThreadId)
    }
    $currentRows = @{}
    foreach ($row in @(Get-SqliteThreadProviderRows -Path $Path -ThreadIds $threadIds)) {
        $currentRows[[string]$row.ThreadId] = [string]$row.Provider
    }

    $statements = New-Object System.Collections.Generic.List[string]
    $statements.Add("BEGIN IMMEDIATE;")
    foreach ($change in $Changes) {
        $threadId = [string]$change.ThreadId
        $oldProvider = [string]$change.OldProvider
        $newProvider = [string]$change.NewProvider
        $expectedCurrent = if ($Direction -eq "forward") { $oldProvider } else { $newProvider }
        $targetProvider = if ($Direction -eq "forward") { $newProvider } else { $oldProvider }

        if (-not $currentRows.ContainsKey($threadId)) {
            throw "SQLite 中找不到待处理的本地线程：$threadId（$Path）"
        }
        if ([string]$currentRows[$threadId] -ceq $targetProvider) {
            continue
        }
        if ([string]$currentRows[$threadId] -cne $expectedCurrent) {
            throw "SQLite provider 在处理前发生变化：$threadId，当前为 '$($currentRows[$threadId])'，预期为 '$expectedCurrent'。"
        }
        $statements.Add(
            "UPDATE threads SET model_provider = " + (ConvertTo-SqlStringLiteral $targetProvider) +
            " WHERE id = " + (ConvertTo-SqlStringLiteral $threadId) +
            " AND model_provider = " + (ConvertTo-SqlStringLiteral $expectedCurrent) + ";"
        )
    }
    $statements.Add("COMMIT;")
    [void](Invoke-SqliteScript -Path $Path -Sql ([string]::Join([Environment]::NewLine, $statements.ToArray())))

    $verifiedRows = @{}
    foreach ($row in @(Get-SqliteThreadProviderRows -Path $Path -ThreadIds $threadIds)) {
        $verifiedRows[[string]$row.ThreadId] = [string]$row.Provider
    }
    foreach ($change in $Changes) {
        $threadId = [string]$change.ThreadId
        $targetProvider = if ($Direction -eq "forward") { [string]$change.NewProvider } else { [string]$change.OldProvider }
        if (-not $verifiedRows.ContainsKey($threadId) -or [string]$verifiedRows[$threadId] -cne $targetProvider) {
            throw "SQLite provider 写入后验证失败：$threadId（$Path）"
        }
    }
    Assert-SqliteQuickCheck -Path $Path
}

function Restore-ManifestDatabase {
    param([Parameter(Mandatory = $true)]$DatabaseEntry)

    $livePath = Resolve-NormalizedPath ([string]$DatabaseEntry.path)
    $backupPath = Resolve-NormalizedPath ([string]$DatabaseEntry.backup_path)
    if (-not [IO.File]::Exists($livePath)) {
        throw "SQLite 状态库不存在，拒绝回滚：$livePath"
    }
    if (-not [IO.File]::Exists($backupPath) -or
        (Get-FileSha256 $backupPath) -cne [string]$DatabaseEntry.backup_sha256) {
        throw "SQLite 备份不存在或哈希不匹配，拒绝回滚：$backupPath"
    }
    Assert-SqliteQuickCheck -Path $backupPath
    Assert-ExclusiveAccess $livePath
    $changes = @(
        foreach ($change in @($DatabaseEntry.changes)) {
            [pscustomobject]@{
                ThreadId = [string]$change.thread_id
                OldProvider = [string]$change.old_provider
                NewProvider = [string]$change.new_provider
            }
        }
    )
    Set-SqliteProviderRows -Path $livePath -Changes $changes -Direction rollback
    $projectionChangesProperty = @(Get-JsonPropertyValue -Object $DatabaseEntry -Name "projection_changes" | Where-Object { $null -ne $_ })
    $projectionChanges = @(
        foreach ($change in $projectionChangesProperty) {
            [pscustomobject]@{
                Action = [string]$change.action
                ThreadId = [string]$change.thread_id
                TurnId = [string]$change.turn_id
                ItemId = [string]$change.item_id
                RolloutOrdinal = [long]$change.rollout_ordinal
                CreatedAtMs = [long]$change.created_at_ms
                ItemJson = [string]$change.item_json
                ItemType = [string]$change.item_type
                UpdatedAtOrdinal = [long]$change.updated_at_ordinal
                NewItemId = [string]$change.new_item_id
                NewItemJson = [string]$change.new_item_json
                TurnReferences = @(
                    foreach ($reference in @(
                        Get-JsonPropertyValue -Object $change -Name "turn_references" |
                            Where-Object { $null -ne $_ }
                    )) {
                        [pscustomobject]@{
                            ThreadId = [string]$reference.thread_id
                            TurnId = [string]$reference.turn_id
                            FirstUserItemId = if ($null -eq $reference.first_user_item_id) { $null } else { [string]$reference.first_user_item_id }
                            FinalAgentItemId = if ($null -eq $reference.final_agent_item_id) { $null } else { [string]$reference.final_agent_item_id }
                        }
                    }
                )
            }
        }
    )
    Set-SqliteProjectionRows -Path $livePath -Changes $projectionChanges -Direction rollback
    $DatabaseEntry.status = "restored"
}

function Restore-ManifestFile {
    param([Parameter(Mandatory = $true)]$FileEntry)

    $livePath = Resolve-NormalizedPath ([string]$FileEntry.path)
    $backupPath = Resolve-NormalizedPath ([string]$FileEntry.backup_path)
    if ([string](Get-JsonPropertyValue $FileEntry 'kind') -ceq 'fixed_slots') {
        if (-not [IO.File]::Exists($backupPath) -or (Get-FileSha256 $backupPath) -cne [string]$FileEntry.backup_sha256) {
            throw "字段恢复材料不存在或哈希不匹配：$backupPath"
        }
        if ([CodexHistoryCompat.IncrementalIo]::Stamp($livePath).Identity -cne [string]$FileEntry.identity) { throw "字段修复文件已被替换，拒绝恢复：$livePath" }
        [CodexHistoryCompat.IncrementalIo]::ApplySlots($livePath,$backupPath,[long]$FileEntry.original_length,
            [string]$FileEntry.original_sha256,[string]$FileEntry.repaired_sha256,$true,-1,[string]$FileEntry.identity)
        if ((Get-FileSha256 $livePath) -cne [string]$FileEntry.original_sha256) { throw "字段恢复后哈希不匹配：$livePath" }
        $FileEntry.status='restored'
        return
    }
    if (-not [IO.File]::Exists($backupPath)) {
        throw "缺少对话历史备份：$backupPath"
    }

    Assert-ExclusiveAccess $livePath
    $liveHash = Get-FileSha256 $livePath
    if ($liveHash -eq [string]$FileEntry.original_sha256) {
        $FileEntry.status = "restored"
        return
    }
    if ($liveHash -ne [string]$FileEntry.repaired_sha256) {
        throw "修复后的对话文件又发生了变化，拒绝回滚：$livePath"
    }
    if ((Get-FileSha256 $backupPath) -ne [string]$FileEntry.original_sha256) {
        throw "对话历史备份哈希不匹配：$backupPath"
    }

    $temporaryPath = Join-Path (Split-Path -Parent $livePath) (".history-restore-{0}.tmp" -f [Guid]::NewGuid().ToString("N"))
    try {
        Copy-DurableHistoryFile -Source $backupPath -Destination $temporaryPath
        Move-ReplaceFile -Source $temporaryPath -Destination $livePath
    }
    finally {
        if ([IO.File]::Exists($temporaryPath)) {
            [IO.File]::Delete($temporaryPath)
        }
    }
    if ((Get-FileSha256 $livePath) -ne [string]$FileEntry.original_sha256) {
        throw "恢复后的对话文件哈希不匹配：$livePath"
    }
    $FileEntry.status = "restored"
}

function Invoke-Repair {
    Recover-ActiveHistoryTransaction
    $phaseTimer = [Diagnostics.Stopwatch]::StartNew()
    Write-Host "正在扫描 Codex 对话历史中的中转兼容问题……"
    $report = Get-CompatibilityReport
    $scanSeconds=$phaseTimer.Elapsed.TotalSeconds
    Write-Host ("历史扫描耗时：{0:N1} 秒。" -f $phaseTimer.Elapsed.TotalSeconds)
    if ($report.Unsupported -gt 0) {
        $details = @(
            foreach ($file in $report.Files) {
                if ($file.Excluded) {
                    continue
                }
                foreach ($item in $file.Items) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$item.UnsupportedReason)) {
                        "$($file.Path):$($item.LineNumber) $($item.UnsupportedReason)"
                    }
                }
                foreach ($item in $file.ProviderItems) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$item.UnsupportedReason)) {
                        "$($file.Path):$($item.LineNumber) $($item.UnsupportedReason)"
                    }
                }
                foreach ($issue in $file.FileIssues) {
                    $detailLine = if ([int]$issue.LineNumber -gt 0) { [string]$issue.LineNumber } else { "文件" }
                    "$($file.Path):$detailLine $($issue.Reason)"
                }
            }
        )
        throw "兼容扫描发现无法安全自动处理的记录：$($details -join '; ')"
    }

    $repairFiles = @(
        $report.Files | Where-Object {
            -not $_.Excluded -and ($_.Items.Count -gt 0 -or $_.ProviderItems.Count -gt 0)
        }
    )
    Write-Host "正在核对待修复历史的分页索引与界面记录来源……"
    $phaseTimer.Restart()
    $paginatedPlans = @(Get-PaginatedProjectionPlans -Report $report)
    $report.ScanMetrics.ProjectionTailFiles=$script:ScanCounters.ProjectionTailFiles
    $report.ScanMetrics.ProjectionFullFiles=$script:ScanCounters.ProjectionFullFiles
    $projectionSeconds=$phaseTimer.Elapsed.TotalSeconds
    Write-Host ("分页校验耗时：{0:N1} 秒。" -f $phaseTimer.Elapsed.TotalSeconds)
    $repairDatabases = @($report.Databases | Where-Object { $_.Changes.Count -gt 0 })
    if (@($paginatedPlans | Where-Object { $_.ProjectionChanges.Count -gt 0 }).Count -gt 0) {
        $projectionDatabasePath = Resolve-NormalizedPath (Join-Path $CodexHome "thread_history_1.sqlite")
        $projectionChanges = New-Object System.Collections.Generic.List[object]
        foreach ($plan in $paginatedPlans) {
            foreach ($change in @($plan.ProjectionChanges)) {
                $projectionChanges.Add($change)
            }
        }
        $matchingDatabases = @($repairDatabases | Where-Object {
            (Resolve-NormalizedPath ([string]$_.Path)) -ieq $projectionDatabasePath
        })
        if ($matchingDatabases.Count -gt 1) {
            throw "同一个分页 SQLite 状态库在修复清单中出现了重复记录：$projectionDatabasePath"
        }
        if ($matchingDatabases.Count -eq 1) {
            # The same database can contain both the legacy threads provider
            # projection and the paginated thread_items projection. Keep one
            # backup/journal entry so forward and rollback each open it once.
            $matchingDatabases[0] | Add-Member -NotePropertyName ProjectionChanges -NotePropertyValue $projectionChanges.ToArray() -Force
        }
        else {
            $repairDatabases += [pscustomobject]@{
                Path = $projectionDatabasePath
                Changes = @()
                ProjectionChanges = $projectionChanges.ToArray()
            }
        }
    }
    if ($repairFiles.Count -eq 0 -and $repairDatabases.Count -eq 0) {
        Save-HistoryFileCertificates
        $report | Add-Member -NotePropertyName PhaseSeconds -NotePropertyValue @{scan=$scanSeconds;projection=$projectionSeconds;repair=0} -Force
        Write-Host "对话兼容检查完成：没有需要修复的记录。"
        return $report
    }

    foreach ($fileReport in $repairFiles) {
        Assert-ExclusiveAccess (Resolve-NormalizedPath $fileReport.Path)
    }
    foreach ($databaseReport in $repairDatabases) {
        $databasePath = Resolve-NormalizedPath $databaseReport.Path
        Assert-ExclusiveAccess $databasePath
        Assert-SqliteQuickCheck -Path $databasePath
    }

    [IO.Directory]::CreateDirectory($BackupRoot) | Out-Null
    $transactionName = [DateTime]::UtcNow.ToString("yyyyMMddTHHmmssfffZ") + "-" + [Guid]::NewGuid().ToString("N")
    $transactionRoot = Join-Path $BackupRoot $transactionName
    [IO.Directory]::CreateDirectory($transactionRoot) | Out-Null
    $manifestFile = Join-Path $transactionRoot "manifest.json"
    $manifest = [ordered]@{
        version = 3
        status = "preparing"
        codex_home = $CodexHome
        created_utc = [DateTime]::UtcNow.ToString("o")
        updated_utc = [DateTime]::UtcNow.ToString("o")
        files = New-Object System.Collections.Generic.List[object]
        databases = New-Object System.Collections.Generic.List[object]
    }
    Save-Manifest -Manifest $manifest -Path $manifestFile
    Assert-HistorySnapshotStable
    Invalidate-HistoryFileCertificates
    Write-HistoryStateJson -Path $script:HistoryActivePath -Value @{manifest=$manifestFile}

    $appliedFiles = New-Object System.Collections.Generic.List[object]
    $appliedDatabases = New-Object System.Collections.Generic.List[object]
    $temporaryFiles = New-Object System.Collections.Generic.List[string]
    Write-Host "正在备份并修复已确认的问题，随后复查受影响历史及关联索引……"
    $phaseTimer.Restart()
    try {
        Assert-PreservedEventProjections -Plans $paginatedPlans
        foreach ($fileReport in $repairFiles) {
            $livePath = Resolve-NormalizedPath $fileReport.Path
            Assert-ExclusiveAccess $livePath
            $startOffset=Get-JsonPropertyValue $fileReport 'ScanStartOffset'
            if ($fileReport.IsPaginated -and [long]$startOffset -gt 0 -and $fileReport.ProviderItems.Count -eq 0 -and
                @($fileReport.Items | Where-Object { $_.Action -ne 'clear_input_ids' }).Count -eq 0 -and
                $null -eq (Get-JsonPropertyValue $fileReport 'LayoutSource')) {
                $originalStamp=[CodexHistoryCompat.IncrementalIo]::Stamp($livePath)
                if (-not (Test-HistoryStampEqual $originalStamp $script:CurrentFileStamps[$livePath])) { throw "历史在规划后变化：$livePath" }
                $originalHash=Get-FileSha256 $livePath
                $slots=[CodexHistoryCompat.IncrementalIo]::BuildSlots($livePath,[long]$startOffset,[int]$fileReport.ScanFirstLine,
                    [CodexHistoryCompat.PortableRecord[]]$fileReport.Items)
                $slotBackup=Join-Path $transactionRoot ("slots-{0:D6}.bin" -f $manifest.files.Count)
                [CodexHistoryCompat.IncrementalIo]::SaveSlots($slotBackup,$slots)
                $repairedHash=[CodexHistoryCompat.IncrementalIo]::RepairedHash($livePath,$slots)
                $entry=[pscustomobject][ordered]@{
                    kind='fixed_slots'; path=$livePath; identity=$originalStamp.Identity; backup_path=$slotBackup
                    backup_sha256=(Get-FileSha256 $slotBackup); original_sha256=$originalHash; repaired_sha256=$repairedHash
                    original_length=$originalStamp.Length; repaired_length=$originalStamp.Length; status='applying'
                    changes=@(@{kind='portable_model_input';action='clear_input_ids';record_count=$fileReport.Items.Count;slot_count=$slots.Count})
                }
                $manifest.files.Add($entry)
                Save-Manifest -Manifest $manifest -Path $manifestFile
                $appliedFiles.Add($entry)
                if ([CodexHistoryCompat.IncrementalIo]::Stamp($livePath).Identity -cne $entry.identity) { throw "字段修复前历史文件被替换：$livePath" }
                [CodexHistoryCompat.IncrementalIo]::ApplySlots($livePath,$slotBackup,$entry.original_length,$originalHash,$repairedHash,$false,-1,$entry.identity)
                if ((Get-FileSha256 $livePath) -cne $repairedHash) { throw "字段修复后的文件哈希不匹配：$livePath" }
                $entry.status='applied'; Save-Manifest -Manifest $manifest -Path $manifestFile
                continue
            }

            # The manifest retains the exact original path. A short backup name
            # avoids MAX_PATH failures with native two-UUID continuation names
            # in Windows PowerShell 5.1 (including automatic rollback).
            $backupPath = Join-Path (Join-Path $transactionRoot "files") ("{0:D6}.jsonl" -f $manifest.files.Count)
            [IO.Directory]::CreateDirectory((Split-Path -Parent $backupPath)) | Out-Null

            $originalHash = Get-FileSha256 $livePath
            $originalLength = (Get-Item -LiteralPath $livePath).Length
            Copy-DurableHistoryFile -Source $livePath -Destination $backupPath
            if ((Get-FileSha256 $backupPath) -ne $originalHash) {
                throw "复制后备份哈希立即出现不一致：$livePath"
            }

            # A continuation filename contains two UUIDs. Repeating it in the
            # temporary filename can exceed Win32's path limit during rename.
            $temporaryPath = Join-Path (Split-Path -Parent $livePath) (".history-repair-{0}.tmp" -f [Guid]::NewGuid().ToString("N"))
            $temporaryFiles.Add($temporaryPath)
            $repairSource = $backupPath
            $expectedLength = $originalLength
            $layoutSource = Get-JsonPropertyValue $fileReport 'LayoutSource'
            if ($null -ne $layoutSource) {
                if ($originalHash -cne $layoutSource.ExpectedLiveSha256) { throw '旧修复文件在规划后发生变化，拒绝覆盖。' }
                if ((Get-FileSha256 $layoutSource.Path) -cne $layoutSource.Sha256) { throw '已核对的旧备份在写入前发生变化。' }
                $repairSource = $layoutSource.Path
                $expectedLength = [long]$layoutSource.Length
            }
            if ($fileReport.IsPaginated) {
                Write-PaginatedRepairedFile `
                    -SourcePath $repairSource `
                    -DestinationPath $temporaryPath `
                    -Items @($fileReport.Items) `
                    -ProviderItems @($fileReport.ProviderItems)
            }
            else {
                Write-RepairedFile `
                    -SourcePath $backupPath `
                    -DestinationPath $temporaryPath `
                    -Items @($fileReport.Items) `
                    -ProviderItems @($fileReport.ProviderItems)
            }
            Test-RepairedJsonl $temporaryPath -SyntaxOnly:$PortableInputIds
            $repairedHash = Get-FileSha256 $temporaryPath
            $repairedLength = (Get-Item -LiteralPath $temporaryPath).Length
            if ($fileReport.IsPaginated -and $repairedLength -ne $expectedLength) {
                throw "分页历史修复改变了文件总字节长度，拒绝替换：$livePath"
            }

            $portableRecordCount = 0
            $changeRecords = @(
                foreach ($item in $fileReport.Items) {
                    if ($item.Action -eq 'clear_input_ids') { $portableRecordCount++; continue }
                    [ordered]@{
                        kind = 'response_item'
                        line_number = $item.LineNumber
                        type = $item.Type
                        action = $item.Action
                        old_id = $item.OldId
                        new_id = $item.NewId
                        call_id = $item.CallId
                        old_line_sha256 = $item.OldLineSha256
                        new_line_sha256 = [string](Get-JsonPropertyValue -Object $item -Name "NewLineSha256")
                        rollout_ordinal = $item.RolloutOrdinal
                    }
                }
                if ($portableRecordCount -gt 0) {
                    # Whole-file before/after hashes and the verified backup
                    # define rollback. Do not serialize hundreds of thousands
                    # of redundant per-line entries on every journal flush.
                    [ordered]@{ kind='portable_model_input'; action='clear_input_ids'; record_count=$portableRecordCount;
                        paths=@('response_item.payload.id','compacted.payload.replacement_history[].id'); encoding='fixed_byte_null' }
                }
                foreach ($item in $fileReport.ProviderItems) {
                    [ordered]@{
                        kind = "provider"
                        line_number = $item.LineNumber
                        record_type = $item.RecordType
                        field = $item.Field
                        thread_id = $item.ThreadId
                        old_provider = $item.OldProvider
                        new_provider = $item.NewProvider
                        old_line_sha256 = $item.OldLineSha256
                        new_line_sha256 = [string](Get-JsonPropertyValue -Object $item -Name "NewLineSha256")
                    }
                }
            )
            $fileEntry = [pscustomobject][ordered]@{
                path = $livePath
                backup_path = $backupPath
                original_sha256 = $originalHash
                original_length = $originalLength
                repaired_sha256 = $repairedHash
                repaired_length = $repairedLength
                status = "prepared"
                changes = $changeRecords
                layout_recovery = $layoutSource
            }
            $manifest.files.Add($fileEntry)
            Save-Manifest -Manifest $manifest -Path $manifestFile

            Assert-ExclusiveAccess $livePath
            if ((Get-FileSha256 $livePath) -ne $originalHash) {
                throw "对话文件在备份与替换之间发生了变化：$livePath"
            }
            Move-ReplaceFile -Source $temporaryPath -Destination $livePath
            $fileEntry.status = "applied"
            $appliedFiles.Add($fileEntry)
            if ((Get-FileSha256 $livePath) -ne $repairedHash) {
                throw "替换后修复文件哈希不匹配：$livePath"
            }
            Test-RepairedJsonl $livePath -SyntaxOnly:$PortableInputIds
            Save-Manifest -Manifest $manifest -Path $manifestFile
            if ($repairFiles.Count -gt 10 -and ($appliedFiles.Count % 10 -eq 0 -or $appliedFiles.Count -eq $repairFiles.Count)) {
                Write-Host ("历史修复进度：{0}/{1} 个文件。" -f $appliedFiles.Count,$repairFiles.Count)
            }
        }

        foreach ($databaseReport in $repairDatabases) {
            $livePath = Resolve-NormalizedPath $databaseReport.Path
            Assert-ExclusiveAccess $livePath
            Assert-SqliteQuickCheck -Path $livePath

            $relativePath = $livePath.Substring($CodexHome.Length).TrimStart("\", "/")
            $backupPath = Join-Path (Join-Path $transactionRoot "database-backups") $relativePath
            Copy-SqliteBackup -SourcePath $livePath -DestinationPath $backupPath

            $changeRecords = @(
                foreach ($change in $databaseReport.Changes) {
                    [ordered]@{
                        thread_id = $change.ThreadId
                        old_provider = $change.OldProvider
                        new_provider = $change.NewProvider
                    }
                }
            )
            $projectionChangesProperty = @(Get-JsonPropertyValue -Object $databaseReport -Name "ProjectionChanges" | Where-Object { $null -ne $_ })
            $projectionChangeRecords = @(
                foreach ($change in $projectionChangesProperty) {
                    [ordered]@{
                        action = $change.Action
                        thread_id = $change.ThreadId
                        turn_id = $change.TurnId
                        item_id = $change.ItemId
                        rollout_ordinal = $change.RolloutOrdinal
                        created_at_ms = $change.CreatedAtMs
                        item_json = $change.ItemJson
                        item_type = $change.ItemType
                        updated_at_ordinal = $change.UpdatedAtOrdinal
                        new_item_id = $change.NewItemId
                        new_item_json = $change.NewItemJson
                        turn_references = @(
                            foreach ($reference in @(
                                Get-JsonPropertyValue -Object $change -Name "TurnReferences" |
                                    Where-Object { $null -ne $_ }
                            )) {
                                [ordered]@{
                                    thread_id = $reference.ThreadId
                                    turn_id = $reference.TurnId
                                    first_user_item_id = $reference.FirstUserItemId
                                    final_agent_item_id = $reference.FinalAgentItemId
                                }
                            }
                        )
                    }
                }
            )
            $databaseEntry = [pscustomobject][ordered]@{
                path = $livePath
                backup_path = $backupPath
                backup_sha256 = Get-FileSha256 $backupPath
                status = "prepared"
                changes = $changeRecords
                projection_changes = $projectionChangeRecords
            }
            $manifest.databases.Add($databaseEntry)
            Save-Manifest -Manifest $manifest -Path $manifestFile

            $databaseEntry.status = "applying"
            $appliedDatabases.Add($databaseEntry)
            Save-Manifest -Manifest $manifest -Path $manifestFile
            Set-SqliteProviderRows -Path $livePath -Changes @($databaseReport.Changes) -Direction forward
            Set-SqliteProjectionRows -Path $livePath -Changes @($projectionChangesProperty) -Direction forward
            $databaseEntry.status = "applied"
            Save-Manifest -Manifest $manifest -Path $manifestFile
        }

        Assert-PreservedEventProjections -Plans $paginatedPlans
        $script:HistoryPostPass=$true
        $postReport = Get-CompatibilityReport
        if ($postReport.Unsupported -ne 0 -or $postReport.Renames -ne 0 -or $postReport.Drops -ne 0 -or $postReport.PortableRecords -ne 0 -or
            $postReport.ProviderChanges -ne 0) {
            throw "修复后的全量复查仍发现兼容问题。"
        }
        Save-HistoryFileCertificates
        $manifest.status = "complete"
        Save-Manifest -Manifest $manifest -Path $manifestFile
        [IO.File]::Delete($script:HistoryActivePath)
        $postReport | Add-Member -NotePropertyName ManifestPath -NotePropertyValue $manifestFile
        $postReport | Add-Member -NotePropertyName RepairedFiles -NotePropertyValue $repairFiles.Count
        $postReport | Add-Member -NotePropertyName RepairedDatabases -NotePropertyValue $repairDatabases.Count
        $postReport | Add-Member -NotePropertyName ScanMetrics -NotePropertyValue $report.ScanMetrics -Force
        $postReport | Add-Member -NotePropertyName PhaseSeconds -NotePropertyValue @{scan=$scanSeconds;projection=$projectionSeconds;repair=$phaseTimer.Elapsed.TotalSeconds} -Force
        Write-Host "对话兼容修复完成：已修复 $($repairFiles.Count) 个 JSONL 文件和 $($repairDatabases.Count) 个 SQLite 状态库。"
        Write-Host "修复清单：$manifestFile"
        Write-Host ("备份、修改与复查耗时：{0:N1} 秒。" -f $phaseTimer.Elapsed.TotalSeconds)
        return $postReport
    }
    catch {
        Invalidate-HistoryFileCertificates
        $repairError = $_
        $rollbackErrors = New-Object System.Collections.Generic.List[string]
        for ($index = $appliedDatabases.Count - 1; $index -ge 0; $index--) {
            $databaseEntry = $appliedDatabases[$index]
            try {
                Restore-ManifestDatabase $databaseEntry
            }
            catch {
                $rollbackErrors.Add([string]$_)
            }
        }
        for ($index = $appliedFiles.Count - 1; $index -ge 0; $index--) {
            $fileEntry = $appliedFiles[$index]
            try {
                Restore-ManifestFile $fileEntry
            }
            catch {
                $rollbackErrors.Add([string]$_)
            }
        }
        $manifest.status = if ($rollbackErrors.Count -eq 0) { "rolled_back" } else { "rollback_failed" }
        Save-Manifest -Manifest $manifest -Path $manifestFile
        if ($rollbackErrors.Count -eq 0) { [IO.File]::Delete($script:HistoryActivePath) }
        if ($rollbackErrors.Count -gt 0) {
            throw "对话修复失败，并且回滚也失败。修复错误：$repairError；回滚错误：$($rollbackErrors -join '; ')"
        }
        throw "对话修复失败，已经恢复本轮修改过的 JSONL 和 SQLite 记录。$repairError"
    }
    finally {
        foreach ($temporaryPath in $temporaryFiles) {
            if ([IO.File]::Exists($temporaryPath)) {
                [IO.File]::Delete($temporaryPath)
            }
        }
    }
}

function Invoke-Rollback {
    Invalidate-HistoryFileCertificates
    if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
        throw "回滚时必须提供 -ManifestPath。"
    }
    $resolvedManifestPath = Resolve-NormalizedPath $ManifestPath
    if (-not [IO.File]::Exists($resolvedManifestPath)) {
        throw "对话修复清单不存在：$resolvedManifestPath"
    }
    $manifest = [IO.File]::ReadAllText($resolvedManifestPath, $script:Utf8NoBom) | ConvertFrom-Json
    $databaseProperty = Get-JsonPropertyValue -Object $manifest -Name "databases"
    $manifestDatabases = @($databaseProperty | Where-Object { $null -ne $_ })
    for ($index = $manifestDatabases.Count - 1; $index -ge 0; $index--) {
        $databaseEntry = $manifestDatabases[$index]
        if ([string]$databaseEntry.status -in @("applying", "applied", "prepared", "restored")) {
            Restore-ManifestDatabase $databaseEntry
        }
    }
    $manifestFiles = @($manifest.files)
    for ($index = $manifestFiles.Count - 1; $index -ge 0; $index--) {
        $fileEntry = $manifestFiles[$index]
        if ([string]$fileEntry.status -in @("applying", "applied", "prepared", "restored")) {
            Restore-ManifestFile $fileEntry
        }
    }
    $manifest.status = "rolled_back"
    Save-Manifest -Manifest $manifest -Path $resolvedManifestPath
    if ([IO.File]::Exists($script:HistoryActivePath)) {
        $active = [IO.File]::ReadAllText($script:HistoryActivePath) | ConvertFrom-Json
        if ([string]$active.manifest -ceq $resolvedManifestPath) { [IO.File]::Delete($script:HistoryActivePath) }
    }
    Write-Host "对话修复回滚完成。"
    return $manifest
}

function Format-ProviderCounts {
    param([Parameter(Mandatory = $true)]$Counts)

    if ($Counts.Count -eq 0) {
        return "无"
    }
    return (@(
        $Counts.Keys | Sort-Object | ForEach-Object {
            "$_=$($Counts[$_])"
        }
    ) -join ", ")
}

$lockPath = Join-Path $BackupRoot "history-repair.lock"
[IO.Directory]::CreateDirectory($BackupRoot) | Out-Null
$lockStream = $null
try {
    try {
        $lockStream = [IO.File]::Open(
            $lockPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
    }
    catch {
        throw "另一个 Codex 对话兼容处理进程正在运行。"
    }

    . (Join-Path $PSScriptRoot 'codex-history-incremental.ps1')

    switch ($Command) {
        "scan" {
            Recover-ActiveHistoryTransaction
            $report = Get-CompatibilityReport
            Write-Host "对话兼容扫描：JSONL=$($report.FilesScanned)，受影响文件=$($report.AffectedFiles)，SQLite=$($report.DatabasesScanned)，受影响库=$($report.AffectedDatabases)，编号改名=$($report.Renames)，模型重放编号清理=$($report.PortableRecords)，推理移除=$($report.Drops)，provider 字段=$($report.ProviderFileChanges)，provider 数据库行=$($report.ProviderDatabaseChanges)，排除=$($report.ExcludedItems)，无法处理=$($report.Unsupported)"
            Write-Host "JSONL provider 统计：$(Format-ProviderCounts $report.JsonlProviderCounts)"
            Write-Host "SQLite provider 统计（仅本地 JSONL 对应线程）：$(Format-ProviderCounts $report.DatabaseProviderCounts)"
            $report
        }
        "repair" {
            Invoke-Repair
        }
        "rollback" {
            Invoke-Rollback
        }
    }
}
finally {
    if ($null -ne $lockStream) {
        $lockStream.Dispose()
    }
}
