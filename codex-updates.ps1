#requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Check','Download')]
    [string]$Mode = 'Check',
    [string]$CurrentVersion,
    [string]$RequestPath,
    [string]$ResultPath,
    [switch]$LibraryOnly
)

$ErrorActionPreference = 'Stop'
$script:ReleaseApi = 'https://api.github.com/repos/IIMovoMII/Codex-Profile-Switcher/releases/latest'
$script:LatestReleasePage = 'https://github.com/IIMovoMII/Codex-Profile-Switcher/releases/latest'
$script:SetupNamePrefix = 'Codex-Profile-Switcher-Setup-'

function Assert-GitHubAssetUri([string]$Value) {
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com' -or
        $uri.AbsolutePath -notmatch '^/IIMovoMII/Codex-Profile-Switcher/releases/download/v\d+\.\d+\.\d+/') {
        throw '更新资源地址不是受信任的 GitHub HTTPS 地址。'
    }
    return $uri
}

function Get-ReleaseUpdateStatus($Release, [string]$InstalledVersion) {
    if ($null -eq $Release -or $Release.prerelease -or $Release.draft) {
        return [pscustomobject]@{ state = 'current'; current_version = $InstalledVersion }
    }

    $latestVersion = ([string]$Release.tag_name).TrimStart('v')
    $current = $null
    $latest = $null
    if ($latestVersion -notmatch '^\d+\.\d+\.\d+$' -or
        -not [Version]::TryParse($InstalledVersion, [ref]$current) -or
        -not [Version]::TryParse($latestVersion, [ref]$latest)) {
        throw 'GitHub 发布版本号格式无效。'
    }
    if ($latest -le $current) {
        return [pscustomobject]@{
            state = 'current'
            current_version = $InstalledVersion
            latest_version = $latestVersion
        }
    }

    $setupName = $script:SetupNamePrefix + $latestVersion + '.exe'
    $checksumName = $setupName + '.sha256'
    $setup = @($Release.assets | Where-Object { $_.name -eq $setupName } | Select-Object -First 1)
    $checksum = @($Release.assets | Where-Object { $_.name -eq $checksumName } | Select-Object -First 1)
    if ($setup.Count -eq 0 -or $checksum.Count -eq 0) {
        return [pscustomobject]@{
            state = 'unavailable'
            current_version = $InstalledVersion
            latest_version = $latestVersion
        }
    }

    $null = Assert-GitHubAssetUri ([string]$setup[0].browser_download_url)
    $null = Assert-GitHubAssetUri ([string]$checksum[0].browser_download_url)
    return [pscustomobject]@{
        state = 'update'
        current_version = $InstalledVersion
        latest_version = $latestVersion
        asset_name = $setupName
        download_url = [string]$setup[0].browser_download_url
        checksum_url = [string]$checksum[0].browser_download_url
    }
}

function Test-GitHubReleaseAsset([string]$Value) {
    $uri = Assert-GitHubAssetUri $Value
    try {
        $response = Invoke-WebRequest -Uri $uri.AbsoluteUri -Method Head -UseBasicParsing -TimeoutSec 8
        return [int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 300
    } catch {
        return $false
    }
}

function Invoke-GitHubStablePageCheck([string]$InstalledVersion) {
    $response = Invoke-WebRequest -Uri $script:LatestReleasePage -Method Get -UseBasicParsing -TimeoutSec 8
    $finalUri = $null
    if ($response.BaseResponse) {
        if ($response.BaseResponse.PSObject.Properties['ResponseUri']) {
            $finalUri = $response.BaseResponse.ResponseUri
        } elseif ($response.BaseResponse.PSObject.Properties['RequestMessage']) {
            $finalUri = $response.BaseResponse.RequestMessage.RequestUri
        }
    }
    if ($null -eq $finalUri -or $finalUri.Scheme -ne 'https' -or $finalUri.Host -ne 'github.com' -or
        $finalUri.AbsolutePath -notmatch '^/IIMovoMII/Codex-Profile-Switcher/releases/tag/v(?<version>\d+\.\d+\.\d+)$') {
        throw 'GitHub 最新稳定版页面没有指向有效的项目版本标签。'
    }

    $latestVersion = $Matches.version
    $setupName = $script:SetupNamePrefix + $latestVersion + '.exe'
    $releaseBase = 'https://github.com/IIMovoMII/Codex-Profile-Switcher/releases/download/v' + $latestVersion + '/'
    $setupUrl = $releaseBase + $setupName
    $checksumUrl = $setupUrl + '.sha256'
    $release = [pscustomobject]@{
        tag_name = 'v' + $latestVersion
        prerelease = $false
        draft = $false
        assets = @(
            [pscustomobject]@{name=$setupName;browser_download_url=$setupUrl}
            [pscustomobject]@{name=($setupName+'.sha256');browser_download_url=$checksumUrl}
        )
    }
    $status = Get-ReleaseUpdateStatus $release $InstalledVersion
    if ($status.state -eq 'update' -and
        (-not (Test-GitHubReleaseAsset $setupUrl) -or -not (Test-GitHubReleaseAsset $checksumUrl))) {
        return [pscustomobject]@{state='unavailable';current_version=$InstalledVersion;latest_version=$latestVersion}
    }
    return $status
}

function Write-UpdateResult([string]$Path, $Value) {
    if (-not $Path) { throw '缺少更新结果文件路径。' }
    $parent = Split-Path -Parent $Path
    if ($parent) { [void][IO.Directory]::CreateDirectory($parent) }
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $Value -Depth 6), $encoding)
    [IO.File]::Move($temporary, $Path)
}

function Invoke-GitHubReleaseCheck([string]$InstalledVersion) {
    $headers = @{
        Accept = 'application/vnd.github+json'
        'User-Agent' = 'Codex-Profile-Switcher'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    try {
        $release = Invoke-RestMethod -Uri $script:ReleaseApi -Method Get -Headers $headers -TimeoutSec 8
        return Get-ReleaseUpdateStatus $release $InstalledVersion
    } catch {
        $apiError = $_.Exception.Message
        try {
            return Invoke-GitHubStablePageCheck $InstalledVersion
        } catch {
            throw ('GitHub 更新查询失败（API：'+$apiError+'；稳定版页面：'+$_.Exception.Message+'）。')
        }
    }
}

function Invoke-VerifiedUpdateDownload([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { throw '更新请求文件不存在。' }
    $request = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
    $downloadUri = Assert-GitHubAssetUri ([string]$request.download_url)
    $checksumUri = Assert-GitHubAssetUri ([string]$request.checksum_url)
    $assetName = [string]$request.asset_name
    if ($assetName -notmatch '^Codex-Profile-Switcher-Setup-\d+\.\d+\.\d+\.exe$') {
        throw '安装包文件名无效。'
    }
    $releaseVersion = [regex]::Match($assetName, '(\d+\.\d+\.\d+)').Groups[1].Value
    if ([string]$request.latest_version -ne $releaseVersion) { throw '更新版本和安装包名称不一致。' }
    $expectedAssetPath = '/IIMovoMII/Codex-Profile-Switcher/releases/download/v' + $releaseVersion + '/' + $assetName
    if ($downloadUri.AbsolutePath -cne $expectedAssetPath -or
        $checksumUri.AbsolutePath -cne ($expectedAssetPath + '.sha256')) {
        throw '更新资源地址与预期版本和安装包名称不一致。'
    }

    $destination = Join-Path ([IO.Path]::GetTempPath()) ($script:SetupNamePrefix + [Guid]::NewGuid().ToString('N') + '.exe')
    $partial = $destination + '.download'
    $checksumPath = $destination + '.sha256'
    try {
        Invoke-WebRequest -Uri $checksumUri.AbsoluteUri -OutFile $checksumPath -UseBasicParsing -TimeoutSec 30
        $checksumText = [IO.File]::ReadAllText($checksumPath)
        if ($checksumText -notmatch '(?im)^\s*(?<hash>[a-f0-9]{64})\s+') {
            throw 'GitHub 发布页没有有效的 SHA-256 清单。'
        }
        $expectedHash = $Matches.hash.ToLowerInvariant()

        Invoke-WebRequest -Uri $downloadUri.AbsoluteUri -OutFile $partial -UseBasicParsing -TimeoutSec 120
        $actualHash = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $expectedHash) {
            throw '安装包 SHA-256 校验失败，已拒绝运行。'
        }
        Move-Item -LiteralPath $partial -Destination $destination
        return [pscustomobject]@{ state = 'ready'; path = $destination; version = [string]$request.latest_version }
    } catch {
        if ([IO.File]::Exists($destination)) { Remove-Item -LiteralPath $destination -Force }
        if ([IO.File]::Exists($partial)) { Remove-Item -LiteralPath $partial -Force }
        throw
    } finally {
        if ([IO.File]::Exists($checksumPath)) { Remove-Item -LiteralPath $checksumPath -Force }
    }
}

if (-not $LibraryOnly) {
    try {
        if (-not $ResultPath) { throw '缺少更新结果文件路径。' }
        if ($Mode -eq 'Check') {
            $result = Invoke-GitHubReleaseCheck $CurrentVersion
        } else {
            $result = Invoke-VerifiedUpdateDownload $RequestPath
        }
        Write-UpdateResult $ResultPath $result
    } catch {
        Write-UpdateResult $ResultPath ([pscustomobject]@{ state = 'error'; message = $_.Exception.Message })
        exit 1
    }
}
