#requires -Version 5.1
# Shared guards for installer tests. Never use /NOICONS as a shell-folder sandbox.

function Assert-TestInstallerIsolated([string]$SetupPath) {
    $hash = (Get-FileHash -LiteralPath $SetupPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $proofPath = Join-Path $PSScriptRoot ('..\artifacts\installer-test-proofs\' + $hash + '.json')
    if (-not [IO.File]::Exists($proofPath)) {
        throw 'Installer has no shortcut-isolation build proof. Build it from the current source before testing; run historical installers only in a disposable VM.'
    }
    $proof = [IO.File]::ReadAllText($proofPath) | ConvertFrom-Json
    $sourceHash = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot '..\installer\CodexProfileSwitcher.iss') -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($proof.schemaVersion -ne 1 -or $proof.capability -cne 'isolated-shortcuts-v1' -or
        $proof.installerSha256 -cne $hash -or $proof.installerSourceSha256 -cne $sourceHash) {
        throw 'Installer shortcut-isolation build proof does not match the executable and current installer source.'
    }
}

function Get-UserShortcutSnapshot {
    $directories = @(
        [Environment]::GetFolderPath('Desktop'),
        [Environment]::GetFolderPath('CommonDesktopDirectory'),
        (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'),
        (Join-Path ([Environment]::GetFolderPath('CommonStartMenu')) 'Programs')
    ) | Select-Object -Unique
    $snapshot = @{}
    foreach ($directory in $directories) {
        foreach ($name in @('Codex 账号切换.lnk', 'Codex切换.lnk', '卸载 Codex 账号切换.lnk')) {
            $path = Join-Path $directory $name
            $snapshot[$path] = if ([IO.File]::Exists($path)) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash } else { $null }
        }
    }
    return $snapshot
}

function Assert-UserShortcutsUnchanged([hashtable]$Snapshot) {
    foreach ($path in $Snapshot.Keys) {
        $actual = if ([IO.File]::Exists($path)) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash } else { $null }
        if ($actual -cne $Snapshot[$path]) { throw "Installer test changed a real shell shortcut: $path" }
    }
}
