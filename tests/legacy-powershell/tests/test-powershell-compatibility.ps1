#requires -Version 7.0

[CmdletBinding()]
param()
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot


Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$switcher = Join-Path $script:ProjectRoot "codex-profile-switcher.ps1"
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("Codex切换-编码测试-" + [Guid]::NewGuid().ToString("N"))
$utf8 = New-Object Text.UTF8Encoding($false)

function Write-TestFile {
    param([string]$Path, [string]$Text)
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Invoke-EncodedProcess {
    param(
        [string]$Executable,
        [string[]]$Arguments
    )

    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $Executable
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    foreach ($argument in $Arguments) {
        [void]$info.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $exitCode = $process.ExitCode
    $process.Dispose()
    return [pscustomobject]@{
        ExitCode = $exitCode
        Text = $stdout + $stderr
    }
}

function Assert-CleanChineseOutput {
    param([string]$Text, [string]$Context)

    if ($Text -notmatch "当前模式" -or $Text -notmatch "跟随系统代理") {
        throw "$Context 没有输出预期的中文界面：$Text"
    }
    if ($Text.Contains([char]0xFFFD)) {
        throw "$Context 输出中出现了 Unicode 替换字符。"
    }
}

function Test-Engine {
    param([string]$EngineName, [string]$EnginePath, [string]$FakeCodex)

    $testCodexHome = Join-Path $tempRoot ("$EngineName-CODEX目录")
    $store = Join-Path $tempRoot ("$EngineName-状态目录")
    [IO.Directory]::CreateDirectory($testCodexHome) | Out-Null
    Write-TestFile (Join-Path $store 'settings.json') '{"version":1,"official_proxy":"system","api_proxy":"direct","context_window":""}'
    Write-TestFile (Join-Path $testCodexHome "config.toml") @'
model_provider = "openai"
openai_base_url = "https://relay.example/v1"
cli_auth_credentials_store = "file"
'@
    Write-TestFile (Join-Path $testCodexHome "auth.json") '{"OPENAI_API_KEY":"encoding-test-key"}'
    Write-TestFile (Join-Path $testCodexHome "models_cache.json") '{"models":[{"slug":"gpt-6.1-sol","visibility":"list","supported_in_api":true,"context_window":500000}]}'

    $common = @(
        "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", $switcher,
        "-CodexHome", $testCodexHome,
        "-DataDir", $store,
        "-MonitorDataDir", (Join-Path $store "提醒状态"),
        "-CodexExecutable", $FakeCodex,
        "-UnsafeAllowRunningCodex"
    )

    $init = Invoke-EncodedProcess $EnginePath (@($common) + @("-Command", "init"))
    if ($init.ExitCode -ne 0) { throw "$EngineName 初始化失败：$($init.Text)" }

    $official = Invoke-EncodedProcess $EnginePath (@($common) + @("-Command", "official"))
    if ($official.ExitCode -ne 0) { throw "$EngineName 官方切换失败：$($official.Text)" }
    if ([IO.File]::ReadAllText((Join-Path $testCodexHome "config.toml")) -notmatch '(?m)^respect_system_proxy = true$') {
        throw "$EngineName 官方模式未开启系统代理跟随。"
    }

    $api = Invoke-EncodedProcess $EnginePath (@($common) + @("-Command", "api"))
    if ($api.ExitCode -ne 0) { throw "$EngineName 中转切换失败：$($api.Text)" }
    if ([IO.File]::ReadAllText((Join-Path $testCodexHome "config.toml")) -notmatch '(?m)^respect_system_proxy = false$') {
        throw "$EngineName 中转模式未关闭系统代理跟随。"
    }

    $status = Invoke-EncodedProcess $EnginePath (@($common) + @("-Command", "status"))
    if ($status.ExitCode -ne 0) { throw "$EngineName 状态检查失败：$($status.Text)" }
    Assert-CleanChineseOutput $status.Text $EngineName
    return [pscustomobject]@{ Engine = $EngineName; ChineseOutput = $true; ModeProxySwitching = $true }
}

try {
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $fakeCodex = Join-Path $tempRoot "模拟-codex.ps1"
    Write-TestFile $fakeCodex @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
$authPath = Join-Path $env:CODEX_HOME "auth.json"
if ($Arguments.Count -ge 1 -and $Arguments[0] -eq "login") {
    if ($Arguments.Count -ge 2 -and $Arguments[1] -eq "status") {
        $auth = Get-Content -Raw -LiteralPath $authPath | ConvertFrom-Json
        if ($null -ne $auth.PSObject.Properties["tokens"]) { "Logged in using ChatGPT" }
        else { "Logged in using an API key" }
        exit 0
    }
    $official = [ordered]@{
        auth_mode = "chatgpt"
        tokens = [ordered]@{
            id_token = "id"
            access_token = "access"
            refresh_token = "refresh"
            account_id = "account"
        }
    } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($authPath, $official, (New-Object Text.UTF8Encoding($false)))
    exit 0
}
exit 3
'@

    $engines = @(
        [pscustomobject]@{ Name = "PowerShell 7"; Path = (Get-Command pwsh.exe -ErrorAction Stop).Source },
        [pscustomobject]@{ Name = "Windows PowerShell 5.1"; Path = (Get-Command powershell.exe -ErrorAction Stop).Source }
    )
    $results = foreach ($engine in $engines) {
        Test-Engine $engine.Name $engine.Path $fakeCodex
    }
    $results | Format-Table -AutoSize
}
finally {
    if ([IO.Directory]::Exists($tempRoot)) {
        $resolvedTemp = [IO.Path]::GetFullPath($tempRoot)
        $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
        if (-not $resolvedTemp.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw "拒绝删除非临时测试目录：$resolvedTemp"
        }
        Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
    }
}
