#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [string]$PublishDirectory,
    [string]$CompilerPath,
    [string]$DotNetPath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $PSScriptRoot 'dist' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)

if ([string]::IsNullOrWhiteSpace($DotNetPath)) {
    $dotnetCommand = Get-Command dotnet.exe -ErrorAction SilentlyContinue
    if ($dotnetCommand) { $DotNetPath = $dotnetCommand.Source }
}
if ([string]::IsNullOrWhiteSpace($DotNetPath) -or -not [IO.File]::Exists($DotNetPath)) {
    throw '找不到 .NET 10 SDK。请安装 .NET 10 SDK，或通过 -DotNetPath 指定 dotnet.exe。'
}
$sdkVersion = (& $DotNetPath --version).Trim()
if ($LASTEXITCODE -ne 0 -or $sdkVersion -notmatch '^10\.') { throw "构建需要 .NET 10 SDK；当前 SDK：$sdkVersion" }

if ([string]::IsNullOrWhiteSpace($CompilerPath)) {
    $compilerCommand = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($compilerCommand) { $CompilerPath = $compilerCommand.Source }
}
if ([string]::IsNullOrWhiteSpace($CompilerPath)) {
    foreach ($candidate in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
        (Join-Path ([Environment]::GetEnvironmentVariable('ProgramFiles(x86)')) 'Inno Setup 6\ISCC.exe')
    )) {
        if ([IO.File]::Exists($candidate)) { $CompilerPath = $candidate; break }
    }
}
if ([string]::IsNullOrWhiteSpace($CompilerPath) -or -not [IO.File]::Exists($CompilerPath)) {
    throw '找不到 Inno Setup 6 编译器（ISCC.exe）。'
}

$version = (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'version.txt')).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'version.txt 必须使用 x.y.z 版本格式。' }
$releasePublishDirectory = if ([string]::IsNullOrWhiteSpace($PublishDirectory)) {
    Join-Path (Join-Path $PSScriptRoot 'artifacts\publish') ('v' + $version)
} else {
    [IO.Path]::GetFullPath((Join-Path $PSScriptRoot $PublishDirectory))
}
if ([IO.Directory]::Exists($releasePublishDirectory)) { throw "发布目录已存在，未覆盖：$releasePublishDirectory" }

$setupName = "Codex-Profile-Switcher-Setup-$version.exe"
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$setupPath = Join-Path $OutputDirectory $setupName
$checksumPath = $setupPath + '.sha256'
if ([IO.File]::Exists($setupPath) -or [IO.File]::Exists($checksumPath)) {
    throw "输出安装包已存在，请指定新的输出目录：$setupPath"
}

$workRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$workDirectory = Join-Path $workRoot ('CodexProfileSwitcher-build-' + [Guid]::NewGuid().ToString('N'))
$dotnetPublishDirectory = Join-Path $workDirectory 'publish'
$payloadDirectory = Join-Path $workDirectory 'payload'
[void][IO.Directory]::CreateDirectory($dotnetPublishDirectory)
[void][IO.Directory]::CreateDirectory($payloadDirectory)

try {
    $publishArguments = @(
        'publish',
        (Join-Path $PSScriptRoot 'src\Switcher.Desktop\Switcher.Desktop.csproj'),
        '--configuration', 'Release',
        '--runtime', 'win-x64',
        '--self-contained', 'true',
        '--output', $dotnetPublishDirectory,
        '-p:SatelliteResourceLanguages=zh-Hans',
        '-p:PublishTrimmed=false',
        '-p:PublishAot=false',
        '-p:DebugType=None',
        '-p:DebugSymbols=false',
        "-p:Version=$version",
        "-p:AssemblyVersion=$version.0",
        "-p:FileVersion=$version.0"
    )
    & $DotNetPath @publishArguments
    if ($LASTEXITCODE -ne 0) { throw "WPF 发布失败，退出码：$LASTEXITCODE" }

    $cliArguments = @(
        'publish',
        (Join-Path $PSScriptRoot 'src\Switcher.Cli\Switcher.Cli.csproj'),
        '--configuration', 'Release',
        '--runtime', 'win-x64',
        '--self-contained', 'true',
        '--output', $dotnetPublishDirectory,
        '-p:SatelliteResourceLanguages=zh-Hans',
        '-p:PublishTrimmed=false',
        '-p:PublishAot=false',
        '-p:DebugType=None',
        '-p:DebugSymbols=false',
        "-p:Version=$version",
        "-p:AssemblyVersion=$version.0",
        "-p:FileVersion=$version.0"
    )
    & $DotNetPath @cliArguments
    if ($LASTEXITCODE -ne 0) { throw "CLI 发布失败，退出码：$LASTEXITCODE" }

    . (Join-Path $PSScriptRoot 'distribution-files.ps1')
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($relativePath in $script:DistributionFiles) {
        $sourcePath = Join-Path $PSScriptRoot $relativePath
        if (-not [IO.File]::Exists($sourcePath)) { throw "静态分发文件缺失：$relativePath" }
        $entries.Add([pscustomobject]@{ Path = $relativePath; Source = $sourcePath })
    }
    foreach ($entry in @(Get-PublishedDistributionFiles -PublishDirectory $dotnetPublishDirectory)) {
        if ($entry.Path -in $script:DistributionFiles) { throw "发布文件与静态分发文件重名：$($entry.Path)" }
        $entries.Add($entry)
    }

    foreach ($entry in $entries) {
        $destinationPath = Join-Path $payloadDirectory $entry.Path
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destinationPath))
        Copy-Item -LiteralPath $entry.Source -Destination $destinationPath
    }

    $manifest = @($entries | Sort-Object Path | ForEach-Object {
        [ordered]@{
            path = $_.Path.Replace('\', '/')
            sha256 = (Get-FileHash -LiteralPath (Join-Path $payloadDirectory $_.Path) -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $payloadDirectory 'SHA256.json'), (ConvertTo-Json -InputObject $manifest -Depth 5), $encoding)

    # Retire only shipped, byte-identical release notes. Never infer ownership from an arbitrary old manifest.
    $retiredNotesInclude = Join-Path $workDirectory 'retired-release-notes.iss'
    $cleanupLines = [System.Collections.Generic.List[string]]::new()
    $cleanupLines.Add('procedure MigrateRetiredReleaseNotes;')
    $cleanupLines.Add('begin')
    foreach ($note in @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'docs\zh-CN\releases') -File -Filter '*.md' | Sort-Object Name)) {
        if ($note.BaseName -notmatch '^\d+\.\d+\.\d+$' -or [version]$note.BaseName -ge [version]$version) { continue }
        $noteHash = (Get-FileHash -LiteralPath $note.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $cleanupLines.Add("  DeleteRetiredReleaseNote('$($note.Name)', '$noteHash');")
    }
    $cleanupLines.Add('end;')
    [IO.File]::WriteAllLines($retiredNotesInclude, $cleanupLines, $encoding)

    $env:CODEX_SWITCHER_SOURCE = $payloadDirectory
    $env:CODEX_SWITCHER_OUTPUT = $OutputDirectory
    $env:CODEX_SWITCHER_VERSION = $version
    $env:CODEX_SWITCHER_RETIRED_NOTES_INCLUDE = $retiredNotesInclude
    try {
        & $CompilerPath (Join-Path $PSScriptRoot 'installer\CodexProfileSwitcher.iss')
        if ($LASTEXITCODE -ne 0) { throw "Inno Setup 编译失败，退出码：$LASTEXITCODE" }
    } finally {
        Remove-Item Env:\CODEX_SWITCHER_SOURCE -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_SWITCHER_OUTPUT -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_SWITCHER_VERSION -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_SWITCHER_RETIRED_NOTES_INCLUDE -ErrorAction SilentlyContinue
    }

    if (-not [IO.File]::Exists($setupPath)) { throw "Inno Setup 未生成预期安装包：$setupPath" }
    $setupHash = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($checksumPath, ($setupHash + '  ' + $setupName + [Environment]::NewLine), $encoding)

    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $releasePublishDirectory))
    Move-Item -LiteralPath $payloadDirectory -Destination $releasePublishDirectory
    $pointerPath = Join-Path (Split-Path -Parent $releasePublishDirectory) 'current-path.txt'
    if ([IO.File]::Exists($pointerPath)) {
        $backupPath = $pointerPath + '.backup-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
        Copy-Item -LiteralPath $pointerPath -Destination $backupPath
    }
    $pointerTemporary = $pointerPath + '.tmp-' + [Guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText($pointerTemporary, $releasePublishDirectory, $encoding)
    if ([IO.File]::Exists($pointerPath)) { [IO.File]::Move($pointerTemporary, $pointerPath, $true) }
    else { [IO.File]::Move($pointerTemporary, $pointerPath) }

    Write-Output "发布目录：$releasePublishDirectory"
    Write-Output "安装包：$setupPath"
    Write-Output "SHA-256：$checksumPath"
} finally {
    if ([IO.Directory]::Exists($workDirectory)) {
        $fullWork = [IO.Path]::GetFullPath($workDirectory)
        if (-not $fullWork.StartsWith($workRoot, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($fullWork) -notlike 'CodexProfileSwitcher-build-*') {
            throw "拒绝清理临时目录之外的路径：$fullWork"
        }
        Remove-Item -LiteralPath $fullWork -Recurse -Force
    }
}
