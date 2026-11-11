#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$SetupPath)
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot


$ErrorActionPreference = 'Stop'
$setup = [IO.Path]::GetFullPath($SetupPath)
if (-not [IO.File]::Exists($setup)) { throw "Installer not found: $setup" }

$checksumFile = $setup + '.sha256'
if (-not [IO.File]::Exists($checksumFile)) { throw 'The installer checksum file is missing.' }
$checksumLine = [IO.File]::ReadAllText($checksumFile)
if ($checksumLine -notmatch '^(?<hash>[a-f0-9]{64})\s+') { throw 'The installer checksum file is invalid.' }
if ((Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Matches.hash.ToLowerInvariant()) {
    throw 'The installer checksum does not match.'
}

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempRoot ('CodexSwitcherInstallTest-' + [Guid]::NewGuid().ToString('N'))
if (-not $testRoot.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase)) { throw 'Test directory escapes the system temporary directory.' }
$installRoot = Join-Path $testRoot 'installed'
$launcherRoot = Join-Path $testRoot 'fixed-launcher'
$codexHome = Join-Path $testRoot 'codex-home'
$store = Join-Path $testRoot 'switcher-store'
$uninstaller = Join-Path $installRoot 'unins000.exe'
[void][IO.Directory]::CreateDirectory($codexHome)
[void][IO.Directory]::CreateDirectory($store)
$marker = Join-Path $store 'retain-marker.txt'
[IO.File]::WriteAllText($marker,'isolated install test')
$uninstalled = $false

function Quote-WindowsArgument([string]$Value) {
    return '"' + [regex]::Replace([regex]::Replace($Value,'(\\*)"$','$1$1\"'),'(\\+)$','$1$1') + '"'
}

function Get-ComparableFileHash([string]$Path) {
    $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -in @('.ps1','.vbs','.cmd','.md','.iss','.xaml','.txt','.cs')) {
        $text = [IO.File]::ReadAllText($Path)
        $canonical = $text.Replace("`r`n", "`n").Replace("`r", "`n")
        $encoding = New-Object System.Text.UTF8Encoding($false)
        $bytes = $encoding.GetBytes($canonical)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant() }
        finally { $sha.Dispose() }
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-FixedLauncher([string]$InstalledEntry,[string]$Root) {
    $executionRoot = Join-Path $Root 'fixed launcher execution test'
    $launcherDirectory = Join-Path $executionRoot 'launcher files'
    $appDirectory = Join-Path $executionRoot 'installed app'
    [void][IO.Directory]::CreateDirectory($launcherDirectory)
    [void][IO.Directory]::CreateDirectory($appDirectory)
    $entry = Join-Path $launcherDirectory 'CodexProfileSwitcher.vbs'
    $pointer = Join-Path $launcherDirectory 'install-path.txt'
    $stub = Join-Path $appDirectory 'start-gui.ps1'
    $marker = Join-Path $executionRoot 'entry-started.txt'
    Copy-Item -LiteralPath $InstalledEntry -Destination $entry
    [IO.File]::WriteAllText($pointer,$appDirectory,(New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($stub,"[IO.File]::WriteAllText(`$env:CODEX_SWITCHER_ENTRY_MARKER,'started')",(New-Object System.Text.UTF8Encoding($false)))
    $previousMarker = [Environment]::GetEnvironmentVariable('CODEX_SWITCHER_ENTRY_MARKER','Process')
    try {
        [Environment]::SetEnvironmentVariable('CODEX_SWITCHER_ENTRY_MARKER',$marker,'Process')
        $cscript = Join-Path $env:SystemRoot 'System32\cscript.exe'
        $output = @(& $cscript //NoLogo $entry 2>&1)
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) { throw ('The fixed launcher returned code ' + $exitCode + ': ' + ($output -join ' ')) }
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while (-not [IO.File]::Exists($marker) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
        if (-not [IO.File]::Exists($marker) -or [IO.File]::ReadAllText($marker) -cne 'started') { throw 'The fixed launcher did not start the pointed-to app.' }
    } finally {
        [Environment]::SetEnvironmentVariable('CODEX_SWITCHER_ENTRY_MARKER',$previousMarker,'Process')
    }
}

try {
    $installArguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /NOICONS /DIR=' + (Quote-WindowsArgument $installRoot) + ' /SWITCHERLAUNCHERDIR=' + (Quote-WindowsArgument $launcherRoot)
    $process = Start-Process -FilePath $setup -ArgumentList $installArguments -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Installer exited with code $($process.ExitCode)." }
    $process.Dispose()

    $manifestPath = Join-Path $installRoot 'SHA256.json'
    if (-not [IO.File]::Exists($manifestPath)) { throw 'The installed file manifest is missing.' }
    $manifest = [IO.File]::ReadAllText($manifestPath,[Text.Encoding]::UTF8) | ConvertFrom-Json
    . (Join-Path $script:ProjectRoot 'distribution-files.ps1')
    if (@($manifest).Count -ne $script:DistributionFiles.Count) { throw 'Installed manifest differs from the distribution allowlist.' }
    foreach ($entry in $manifest) {
        if ([string]$entry.path -notin $script:DistributionFiles) { throw "Unexpected installed payload: $($entry.path)" }
        $path = Join-Path $installRoot ([string]$entry.path)
        if (-not [IO.File]::Exists($path)) { throw "Installed runtime file missing: $($entry.path)" }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne [string]$entry.sha256) { throw "Installed runtime file failed its manifest hash: $($entry.path)" }
        $source = Join-Path $script:ProjectRoot ([string]$entry.path)
        if ((Get-ComparableFileHash $path) -ne (Get-ComparableFileHash $source)) {
            throw "Installer is stale relative to current source: $($entry.path)"
        }
    }

    $launcherFile = Join-Path $launcherRoot 'CodexProfileSwitcher.vbs'
    $launcherPointer = Join-Path $launcherRoot 'install-path.txt'
    if (-not [IO.File]::Exists($launcherFile) -or -not [IO.File]::Exists($launcherPointer)) { throw 'The fixed launcher or its install-path pointer is missing.' }
    if ((Get-ComparableFileHash $launcherFile) -ne (Get-ComparableFileHash (Join-Path $script:ProjectRoot 'CodexProfileSwitcher.vbs'))) { throw 'The installed fixed launcher differs from the source.' }
    if ([IO.File]::ReadAllText($launcherPointer).Trim() -cne $installRoot) { throw 'The fixed launcher points to the wrong install directory.' }
    Test-FixedLauncher $launcherFile $testRoot
    $installerSource = [IO.File]::ReadAllText((Join-Path $script:ProjectRoot 'installer\CodexProfileSwitcher.iss'))
    $desktopIconLine = @($installerSource -split '[\r\n]+' | Where-Object { $_.Contains('{autodesktop}') })[0]
    $desktopTaskPresent = $installerSource.Contains('Name: "desktopicon";')
    $desktopTargetPresent = $desktopIconLine -and $desktopIconLine.Contains('{code:GetLauncherFile}') -and $desktopIconLine.Contains('Tasks: desktopicon')
    if (-not $desktopTaskPresent -or -not $desktopTargetPresent) { throw ('The optional desktop shortcut does not target the fixed launcher. Task=' + $desktopTaskPresent + '; line=' + [string]$desktopIconLine) }
    [IO.File]::AppendAllText($launcherFile, "`r`n' immutable-launcher-test-marker")
    $process = Start-Process -FilePath $setup -ArgumentList $installArguments -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Installer update exited with code $($process.ExitCode)." }
    $process.Dispose()
    if ([IO.File]::ReadAllText($launcherFile) -notmatch 'immutable-launcher-test-marker') { throw 'An installer update overwrote the fixed launcher.' }
    if ([IO.File]::ReadAllText($launcherPointer).Trim() -cne $installRoot) { throw 'An installer update failed to refresh the launcher path pointer.' }

    $powerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $gui = Join-Path $installRoot 'start-gui.ps1'
    $args = @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-STA','-File',$gui,'-NoShow','-CodexHome',$codexHome,'-DataDir',$store,'-MonitorDataDir',(Join-Path $testRoot 'monitor'))
    $quoted = ($args | ForEach-Object { Quote-WindowsArgument ([string]$_) }) -join ' '
    $process = Start-Process -FilePath $powerShell -ArgumentList $quoted -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Installed GUI entry exited with code $($process.ExitCode)." }
    $process.Dispose()

    $uninstaller = Join-Path $installRoot 'unins000.exe'
    if (-not [IO.File]::Exists($uninstaller)) { throw 'Inno Setup did not register an uninstaller.' }
    $process = Start-Process -FilePath $uninstaller -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Uninstaller exited with code $($process.ExitCode)." }
    $process.Dispose()
    $uninstalled = $true
    if (-not [IO.File]::Exists($marker)) { throw 'Uninstall removed the isolated data marker.' }
    if (-not [IO.Directory]::Exists($codexHome)) { throw 'Uninstall removed the isolated CODEX_HOME.' }

    Write-Output 'Installer integration passed: SHA-256, isolated install, runtime manifest, GUI startup, uninstall, and data retention.'
} finally {
    if (-not $uninstalled -and [IO.File]::Exists($uninstaller)) {
        try {
            $cleanup = Start-Process -FilePath $uninstaller -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -WindowStyle Hidden -Wait -PassThru
            $uninstalled = $cleanup.ExitCode -eq 0
            $cleanup.Dispose()
        } catch {}
    }
    if ($uninstalled -and [IO.Directory]::Exists($testRoot) -and
        $testRoot.StartsWith($tempRoot,[StringComparison]::OrdinalIgnoreCase) -and
        ([IO.Path]::GetFileName($testRoot) -like 'CodexSwitcherInstallTest-*')) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    } elseif ([IO.Directory]::Exists($testRoot)) {
        Write-Warning "Isolated installer test files retained at $testRoot because uninstall or validation did not finish."
    }
}
