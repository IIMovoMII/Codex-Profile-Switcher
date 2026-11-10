#requires -Version 5.1
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$ErrorActionPreference = 'Stop'
. (Join-Path $script:ProjectRoot 'codex-updates.ps1') -LibraryOnly

function Assert-Equal($Actual, $Expected, [string]$Name) {
    if ($Actual -cne $Expected) { throw ('{0}: expected {1}, received {2}.' -f $Name,$Expected,$Actual) }
}

$version = '0.2.5'
$setupName = 'Codex-Profile-Switcher-Setup-0.2.6.exe'
$release = [pscustomobject]@{
    tag_name = 'v0.2.6'
    prerelease = $false
    draft = $false
    assets = @(
        [pscustomobject]@{name=$setupName;browser_download_url="https://github.com/IIMovoMII/Codex-Profile-Switcher/releases/download/v0.2.6/$setupName"}
        [pscustomobject]@{name="$setupName.sha256";browser_download_url="https://github.com/IIMovoMII/Codex-Profile-Switcher/releases/download/v0.2.6/$setupName.sha256"}
    )
}
$update = Get-ReleaseUpdateStatus $release $version
Assert-Equal $update.state 'update' 'new release detection'
Assert-Equal $update.latest_version '0.2.6' 'release tag parsing'
Assert-Equal $update.asset_name $setupName 'installer asset selection'

$current = Get-ReleaseUpdateStatus $release '0.2.6'
Assert-Equal $current.state 'current' 'current release'
$missingAsset = Get-ReleaseUpdateStatus ([pscustomobject]@{tag_name='v0.2.6';prerelease=$false;draft=$false;assets=@()}) $version
Assert-Equal $missingAsset.state 'unavailable' 'missing installer asset'

$rejected = $false
try { $null = Assert-GitHubAssetUri 'https://example.com/setup.exe' } catch { $rejected = $true }
if (-not $rejected) { throw 'Non-GitHub update asset URLs must be rejected.' }
$rejected = $false
try { $null = Assert-GitHubAssetUri 'http://github.com/setup.exe' } catch { $rejected = $true }
if (-not $rejected) { throw 'Non-HTTPS update asset URLs must be rejected.' }
$rejected = $false
try { $null = Assert-GitHubAssetUri 'https://github.com/other/project/releases/download/v0.2.6/setup.exe' } catch { $rejected = $true }
if (-not $rejected) { throw 'Other GitHub projects must not be accepted as update sources.' }
$rejected = $false
try {
    $requestPath = Join-Path ([IO.Path]::GetTempPath()) ('codex-update-test-' + [Guid]::NewGuid().ToString('N') + '.json')
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $request = [ordered]@{
        latest_version='0.2.6'
        asset_name=$setupName
        download_url="https://github.com/IIMovoMII/Codex-Profile-Switcher/releases/download/v0.2.5/$setupName"
        checksum_url="https://github.com/IIMovoMII/Codex-Profile-Switcher/releases/download/v0.2.5/$setupName.sha256"
    }
    [IO.File]::WriteAllText($requestPath,(ConvertTo-Json $request),$encoding)
    try { $null = Invoke-VerifiedUpdateDownload $requestPath } catch { $rejected = $true }
    if (-not $rejected) { throw 'An asset version mismatch must be rejected.' }
} finally {
    if ([IO.File]::Exists($requestPath)) { Remove-Item -LiteralPath $requestPath -Force }
}

$mockPayload = [Text.Encoding]::UTF8.GetBytes('isolated installer payload')
$mockFile = Join-Path ([IO.Path]::GetTempPath()) ('codex-update-hash-test-' + [Guid]::NewGuid().ToString('N') + '.tmp')
[IO.File]::WriteAllBytes($mockFile,$mockPayload)
$script:MockInstallerHash = (Get-FileHash -LiteralPath $mockFile -Algorithm SHA256).Hash.ToLowerInvariant()
Remove-Item -LiteralPath $mockFile -Force
function Invoke-WebRequest {
    param([string]$Uri,[string]$OutFile,[switch]$UseBasicParsing,[int]$TimeoutSec)
    if ($Uri.EndsWith('.sha256')) {
        [IO.File]::WriteAllText($OutFile,($script:MockInstallerHash + ' installer.exe' + [Environment]::NewLine))
    } else {
        [IO.File]::WriteAllBytes($OutFile,$mockPayload)
    }
}
$downloadRequestPath = Join-Path ([IO.Path]::GetTempPath()) ('codex-update-download-test-' + [Guid]::NewGuid().ToString('N') + '.json')
$downloadRequest = [ordered]@{
    latest_version='0.2.6'
    asset_name=$setupName
    download_url="https://github.com/IIMovoMII/Codex-Profile-Switcher/releases/download/v0.2.6/$setupName"
    checksum_url="https://github.com/IIMovoMII/Codex-Profile-Switcher/releases/download/v0.2.6/$setupName.sha256"
}
[IO.File]::WriteAllText($downloadRequestPath,(ConvertTo-Json $downloadRequest),$encoding)
try {
    $verified = Invoke-VerifiedUpdateDownload $downloadRequestPath
    Assert-Equal $verified.state 'ready' 'verified download'
    if ((Get-FileHash -LiteralPath $verified.path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $script:MockInstallerHash) {
        throw 'A verified installer did not match the published checksum.'
    }
    Remove-Item -LiteralPath $verified.path -Force

    $script:MockInstallerHash = '0000000000000000000000000000000000000000000000000000000000000000'
    $rejected = $false
    try { $null = Invoke-VerifiedUpdateDownload $downloadRequestPath } catch { $rejected = $true }
    if (-not $rejected) { throw 'A checksum mismatch must reject the downloaded installer.' }
} finally {
    if ([IO.File]::Exists($downloadRequestPath)) { Remove-Item -LiteralPath $downloadRequestPath -Force }
}

Write-Output 'GitHub update selection and trusted URL checks passed.'
