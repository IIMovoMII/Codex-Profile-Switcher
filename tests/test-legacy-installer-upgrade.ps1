#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$LegacySetupPath,
    [Parameter(Mandatory = $true)][string]$CurrentSetupPath,
    [switch]$ModifyLegacyScript
)

$ErrorActionPreference = 'Stop'
$legacySetup = [IO.Path]::GetFullPath($LegacySetupPath)
$currentSetup = [IO.Path]::GetFullPath($CurrentSetupPath)
foreach ($path in @($legacySetup, $currentSetup)) {
    if (-not [IO.File]::Exists($path)) { throw "Installer not found: $path" }
}

. (Join-Path $PSScriptRoot 'installer-test-isolation.ps1')
Assert-TestInstallerIsolated $legacySetup
Assert-TestInstallerIsolated $currentSetup
$userShortcuts = Get-UserShortcutSnapshot

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempRoot ('CodexSwitcherLegacyUpgradeTest-' + [Guid]::NewGuid().ToString('N'))
if (-not $testRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Test root escaped the system temporary directory.' }
$installRoot = Join-Path $testRoot 'installed application'
$launcherRoot = Join-Path $testRoot 'fixed launcher'
$uninstaller = Join-Path $installRoot 'unins000.exe'
[void][IO.Directory]::CreateDirectory($installRoot)
[void][IO.Directory]::CreateDirectory($launcherRoot)
$uninstalled = $false
$testInstallId = [Guid]::NewGuid().ToString('N')

function Quote-WindowsArgument([string]$Value) {
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"$', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Invoke-IsolatedInstall([string]$SetupPath) {
    $arguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /TASKS=desktopicon /DIR=' + (Quote-WindowsArgument $installRoot) +
        ' /SWITCHERLAUNCHERDIR=' + (Quote-WindowsArgument $launcherRoot) + ' /SWITCHERTESTID=' + $testInstallId
    $process = Start-Process -FilePath $SetupPath -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
    try { if ($process.ExitCode -ne 0) { throw "Installer exited with code $($process.ExitCode)." } }
    finally { $process.Dispose() }
    Assert-UserShortcutsUnchanged $userShortcuts
}

function Get-InstalledPowerShellFiles {
    return @(Get-ChildItem -LiteralPath $installRoot -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1') } |
        ForEach-Object {
            [pscustomobject]@{
                Path = $_.FullName.Substring($installRoot.Length).TrimStart('\')
                Sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        })
}

try {
    Invoke-IsolatedInstall $legacySetup
    $beforeUpgrade = Get-InstalledPowerShellFiles
    if ($beforeUpgrade.Count -eq 0) { throw 'The legacy installer did not produce the expected PowerShell payload.' }
    if ($ModifyLegacyScript) {
        [IO.File]::AppendAllText((Join-Path $installRoot 'codex-profile-switcher.ps1'), "`r`n# isolated user modification")
    }

    Invoke-IsolatedInstall $currentSetup
    $afterUpgrade = Get-InstalledPowerShellFiles
    $warningFile = Join-Path $launcherRoot 'legacy-powershell-migration-warning.txt'
    if ($ModifyLegacyScript) {
        $preserved = @($afterUpgrade | Where-Object { $_.Path -eq 'codex-profile-switcher.ps1' })
        if ($preserved.Count -ne 1 -or -not [IO.File]::Exists($warningFile)) {
            throw 'The modified legacy PowerShell file was not preserved with a migration warning.'
        }
    }
    elseif ($afterUpgrade.Count -ne 0) {
        throw 'Known unmodified legacy PowerShell files remained after upgrade.'
    }

    if (-not [IO.File]::Exists($uninstaller)) { throw 'The upgraded installation did not create an uninstaller.' }
    $process = Start-Process -FilePath $uninstaller -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -WindowStyle Hidden -Wait -PassThru
    try { if ($process.ExitCode -ne 0) { throw "Uninstaller exited with code $($process.ExitCode)." } }
    finally { $process.Dispose() }
    $uninstalled = $true
    Assert-UserShortcutsUnchanged $userShortcuts

    [pscustomobject]@{
        LegacyPowerShellFileCount = $beforeUpgrade.Count
        RemainingPowerShellFileCount = $afterUpgrade.Count
        ModifiedLegacyFilePreserved = [bool]$ModifyLegacyScript
        MigrationWarningCreated = [IO.File]::Exists($warningFile)
        IsolatedUninstallSucceeded = $uninstalled
    } | ConvertTo-Json -Depth 3
}
finally {
    if (-not $uninstalled -and [IO.File]::Exists($uninstaller)) {
        try {
            $cleanup = Start-Process -FilePath $uninstaller -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -WindowStyle Hidden -Wait -PassThru
            $uninstalled = $cleanup.ExitCode -eq 0
            $cleanup.Dispose()
        } catch {}
    }
    if ($uninstalled -and [IO.Directory]::Exists($testRoot) -and
        $testRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($testRoot) -like 'CodexSwitcherLegacyUpgradeTest-*') {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
    elseif ([IO.Directory]::Exists($testRoot)) {
        Write-Warning "Temporary upgrade test files retained at $testRoot because validation or uninstall did not finish."
    }
    Assert-UserShortcutsUnchanged $userShortcuts
}
