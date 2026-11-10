#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [string]$CompilerPath
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $PSScriptRoot 'dist' }
. (Join-Path $PSScriptRoot 'distribution-files.ps1')

$version = (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'version.txt')).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'version.txt 必须使用 x.y.z 版本格式。' }
$installerScript = Join-Path $PSScriptRoot 'installer\CodexProfileSwitcher.iss'

if (-not $CompilerPath) {
    $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($command) { $CompilerPath = $command.Source }
}
if (-not $CompilerPath) {
    foreach ($candidate in @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
        (Join-Path ([Environment]::GetEnvironmentVariable('ProgramFiles(x86)')) 'Inno Setup 6\ISCC.exe')
    )) {
        if ([IO.File]::Exists($candidate)) { $CompilerPath = $candidate; break }
    }
}
if (-not $CompilerPath -or -not [IO.File]::Exists($CompilerPath)) {
    throw '找不到 Inno Setup 6 编译器（ISCC.exe）。'
}

[void][IO.Directory]::CreateDirectory($OutputDirectory)
$setupName = "Codex-Profile-Switcher-Setup-$version.exe"
$setupPath = Join-Path $OutputDirectory $setupName
$checksumPath = $setupPath + '.sha256'
if ([IO.File]::Exists($setupPath) -or [IO.File]::Exists($checksumPath)) {
    throw "输出安装包已存在，请指定新的输出目录：$setupPath"
}

$workDirectory = Join-Path ([IO.Path]::GetTempPath()) ('CodexProfileSwitcher-build-' + [Guid]::NewGuid().ToString('N'))
$payloadDirectory = Join-Path $workDirectory 'payload'
[void][IO.Directory]::CreateDirectory($payloadDirectory)
try {
    foreach ($relativePath in $script:DistributionFiles) {
        $sourcePath = Join-Path $PSScriptRoot $relativePath
        if (-not [IO.File]::Exists($sourcePath)) { throw "分发文件缺失：$relativePath" }
        $destinationPath = Join-Path $payloadDirectory $relativePath
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destinationPath))
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath
    }

    $manifest = @($script:DistributionFiles | ForEach-Object {
        [ordered]@{
            path = $_
            sha256 = (Get-FileHash -LiteralPath (Join-Path $payloadDirectory $_) -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText((Join-Path $payloadDirectory 'SHA256.json'), (ConvertTo-Json -InputObject $manifest -Depth 5), $encoding)

    $env:CODEX_SWITCHER_SOURCE = $payloadDirectory
    $env:CODEX_SWITCHER_OUTPUT = [IO.Path]::GetFullPath($OutputDirectory)
    $env:CODEX_SWITCHER_VERSION = $version
    try {
        & $CompilerPath $installerScript
        if ($LASTEXITCODE -ne 0) { throw "Inno Setup 编译失败，退出码：$LASTEXITCODE" }
    } finally {
        Remove-Item Env:\CODEX_SWITCHER_SOURCE -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_SWITCHER_OUTPUT -ErrorAction SilentlyContinue
        Remove-Item Env:\CODEX_SWITCHER_VERSION -ErrorAction SilentlyContinue
    }

    if (-not [IO.File]::Exists($setupPath)) { throw "Inno Setup 未生成预期安装包：$setupPath" }
    $hash = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($checksumPath, ($hash + '  ' + $setupName + [Environment]::NewLine), $encoding)
    Write-Output $setupPath
    Write-Output $checksumPath
} finally {
    if ([IO.Directory]::Exists($workDirectory)) {
        Remove-Item -LiteralPath $workDirectory -Recurse -Force
    }
}
