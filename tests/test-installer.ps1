#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SetupPath,
    [string]$PreviousDotNetLauncherPath
)

$ErrorActionPreference = 'Stop'
$setup = [IO.Path]::GetFullPath($SetupPath)
if (-not [IO.File]::Exists($setup)) { throw "Installer not found: $setup" }
$checksumFile = $setup + '.sha256'
if (-not [IO.File]::Exists($checksumFile)) { throw 'Installer checksum file is missing.' }
$checksumText = [IO.File]::ReadAllText($checksumFile)
if ($checksumText -notmatch '^(?<hash>[a-f0-9]{64})\s+') { throw 'Installer checksum file is invalid.' }
if ((Get-FileHash -LiteralPath $setup -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Matches.hash) { throw 'Installer SHA-256 does not match.' }

. (Join-Path $PSScriptRoot 'installer-test-isolation.ps1')
Assert-TestInstallerIsolated $setup
$userShortcuts = Get-UserShortcutSnapshot

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$testRoot = Join-Path $tempRoot ('CodexSwitcherInstallTest-' + [Guid]::NewGuid().ToString('N'))
if (-not $testRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Test root escaped the system temporary directory.' }
$installRoot = Join-Path $testRoot 'installed application 中文'
$launcherRoot = Join-Path $testRoot 'fixed launcher 中文'
$codexHome = Join-Path $testRoot 'codex home'
$dataRoot = Join-Path $testRoot 'switcher data'
$uninstaller = Join-Path $installRoot 'unins000.exe'
foreach ($directory in @($codexHome, $dataRoot)) { [void][IO.Directory]::CreateDirectory($directory) }
$retainedMarker = Join-Path $dataRoot 'retain-marker.txt'
[IO.File]::WriteAllText($retainedMarker, 'isolated data marker')
$uninstalled = $false
$testInstallId = [Guid]::NewGuid().ToString('N')
$testUninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\CPS-Test-' + $testInstallId + '_is1'

function Quote-WindowsArgument([string]$Value) {
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"$', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Invoke-IsolatedInstall {
    $arguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /TASKS=desktopicon /DIR=' + (Quote-WindowsArgument $installRoot) +
        ' /SWITCHERLAUNCHERDIR=' + (Quote-WindowsArgument $launcherRoot) + ' /SWITCHERTESTID=' + $testInstallId
    $process = Start-Process -FilePath $setup -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
    try { if ($process.ExitCode -ne 0) { throw "Installer exited with code $($process.ExitCode)." } }
    finally { $process.Dispose() }
    Assert-UserShortcutsUnchanged $userShortcuts
    Assert-IsolatedShortcuts
}

function Assert-IsolatedShortcuts {
    $shell = New-Object -ComObject WScript.Shell
    $expectedLauncher = '"' + (Join-Path $launcherRoot 'CodexProfileSwitcher.vbs') + '"'
    foreach ($kind in @('desktop', 'startmenu')) {
        $path = Join-Path $installRoot ('test-shortcuts\' + $kind + '\Codex 账号切换.lnk')
        if (-not [IO.File]::Exists($path)) { throw "Isolated $kind shortcut was not created." }
        $shortcut = $shell.CreateShortcut($path)
        if ($shortcut.TargetPath -ine (Join-Path $env:SystemRoot 'System32\wscript.exe') -or
            $shortcut.Arguments -cne $expectedLauncher -or $shortcut.WorkingDirectory -cne $launcherRoot) {
            throw "Isolated $kind shortcut does not target the temporary fixed launcher."
        }
    }
    $uninstallPath = Join-Path $installRoot 'test-shortcuts\startmenu\卸载 Codex 账号切换.lnk'
    if (-not [IO.File]::Exists($uninstallPath) -or $shell.CreateShortcut($uninstallPath).TargetPath -cne $uninstaller) {
        throw 'Isolated uninstall shortcut does not target the temporary uninstaller.'
    }
}

function Assert-InstalledManifest {
    $expectedVersion = ([IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\version.txt'))).Trim()
    if ((Get-ItemProperty -LiteralPath $testUninstallKey).DisplayVersion -cne $expectedVersion) { throw 'Installed registration did not record the current version.' }
    $manifestPath = Join-Path $installRoot 'SHA256.json'
    if (-not [IO.File]::Exists($manifestPath)) { throw 'Installed SHA256.json is missing.' }
    $manifest = @([IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8) | ConvertFrom-Json | ForEach-Object { $_ })
    $seen = @{}
    foreach ($entry in $manifest) {
        $relative = ([string]$entry.path).Replace('/', '\')
        if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|\\)\.\.($|\\)') { throw "Manifest path escapes install root: $relative" }
        if ($seen.ContainsKey($relative)) { throw "Duplicate manifest path: $relative" }
        $seen[$relative] = $true
        if ($relative -match '\.(ps1|psm1|psd1)$') { throw "PowerShell runtime was distributed: $relative" }
        $path = Join-Path $installRoot $relative
        if (-not [IO.File]::Exists($path)) { throw "Installed payload is missing: $relative" }
        $actual = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne [string]$entry.sha256) { throw "Installed payload hash does not match: $relative" }
        if ($relative -match '(^|\\)[^\\]+\.resources\.dll$' -and $relative -notmatch '^zh-Hans\\[^\\]+\.resources\.dll$') {
            throw "Unexpected satellite language in the Simplified Chinese payload: $relative"
        }
    }
    foreach ($required in @('CodexProfileSwitcher.exe', 'Switcher.Cli.exe', 'CodexProfileSwitcher.vbs', 'codex-switcher.cmd', 'README.md',
        'hostfxr.dll', 'hostpolicy.dll', 'coreclr.dll', 'clrjit.dll', 'System.Private.CoreLib.dll',
        'PresentationFramework.dll', 'PresentationCore.dll', 'WindowsBase.dll', 'e_sqlite3.dll',
        'zh-Hans\PresentationFramework.resources.dll')) {
        if (-not $seen.ContainsKey($required)) { throw "Required installed file is absent from manifest: $required" }
    }
}

function Invoke-IsolatedCli {
    $cli = Join-Path $installRoot 'Switcher.Cli.exe'
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $cli
    $start.Arguments = 'status --json --codex-home ' + (Quote-WindowsArgument $codexHome) + ' --data-dir ' + (Quote-WindowsArgument $dataRoot)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['CODEX_HOME'] = $codexHome
    $start.EnvironmentVariables['DOTNET_ROOT'] = Join-Path $testRoot 'missing-dotnet-runtime'
    $start.EnvironmentVariables['DOTNET_ROOT_X64'] = $start.EnvironmentVariables['DOTNET_ROOT']
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'Installed CLI timed out.' }
        $output = $stdout.GetAwaiter().GetResult()
        $errorOutput = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Installed CLI returned $($process.ExitCode): $output $errorOutput" }
        $result = $output | ConvertFrom-Json
    }
    finally { $process.Dispose() }
    if ([IO.Path]::GetFullPath($result.codex_home) -cne [IO.Path]::GetFullPath($codexHome)) { throw 'Installed CLI ignored the temporary CODEX_HOME.' }
    if ([IO.Path]::GetFullPath($result.data_directory) -cne [IO.Path]::GetFullPath($dataRoot)) { throw 'Installed CLI ignored the temporary data directory.' }
    if ([IO.File]::Exists((Join-Path $codexHome 'auth.json')) -or [IO.File]::Exists((Join-Path $codexHome 'config.toml'))) { throw 'CLI status unexpectedly created or changed live Codex files.' }
}

function Invoke-IsolatedGui([bool]$ViaLauncher = $false) {
    $mockPath = Join-Path $testRoot 'mock-codex-must-not-be-called.exe'
    [IO.File]::WriteAllText($mockPath, 'Synthetic sentinel; never execute a real Codex command.')
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $installRoot 'CodexProfileSwitcher.exe'
    $start.Arguments = '--codex-home ' + (Quote-WindowsArgument $codexHome) + ' --data-dir ' + (Quote-WindowsArgument $dataRoot) + ' --codex-exe ' + (Quote-WindowsArgument $mockPath)
    if ($ViaLauncher) {
        $start.FileName = Join-Path $env:SystemRoot 'System32\cscript.exe'
        $start.Arguments = '//Nologo ' + (Quote-WindowsArgument (Join-Path $launcherRoot 'CodexProfileSwitcher.vbs')) + ' ' + $start.Arguments
        $start.CreateNoWindow = $true
    }
    $start.UseShellExecute = $false
    $start.EnvironmentVariables['CODEX_SWITCHER_DISABLE_UPDATE_CHECK'] = '1'
    $start.EnvironmentVariables['CODEX_HOME'] = $codexHome
    $start.EnvironmentVariables['DOTNET_ROOT'] = Join-Path $testRoot 'missing-dotnet-runtime'
    $start.EnvironmentVariables['DOTNET_ROOT_X64'] = $start.EnvironmentVariables['DOTNET_ROOT']
    $process = [Diagnostics.Process]::Start($start)
    try {
        $ready = $false
        $windowProcess = $process
        for ($attempt = 0; $attempt -lt 50; $attempt++) {
            if ($process.HasExited) { throw 'Installed WPF exited before displaying its window.' }
            if ($ViaLauncher) {
                $children = @(Get-CimInstance Win32_Process -Filter ("ParentProcessId=" + $process.Id + " AND Name='CodexProfileSwitcher.exe'"))
                if ($children.Length -eq 1) { $windowProcess = [Diagnostics.Process]::GetProcessById($children[0].ProcessId) }
            }
            $windowProcess.Refresh()
            if ($windowProcess.MainWindowHandle -ne [IntPtr]::Zero -and $windowProcess.MainWindowTitle -eq 'Codex 切换助手') { $ready = $true; break }
            Start-Sleep -Milliseconds 200
        }
        if (-not $ready) { throw ('Installed WPF did not show its expected window: ' + $process.MainWindowTitle) }
        if (-not $windowProcess.CloseMainWindow() -or -not $process.WaitForExit(5000)) { throw 'Installed WPF did not close normally.' }
        if ($process.ExitCode -ne 0) { throw ('Installed WPF exited with code ' + $process.ExitCode) }
        if ([IO.File]::Exists((Join-Path $codexHome 'auth.json')) -or [IO.File]::Exists((Join-Path $codexHome 'config.toml'))) { throw 'GUI startup unexpectedly wrote authentication or Codex configuration.' }
    }
    finally {
        if ($windowProcess -and $windowProcess.Id -ne $process.Id) { if (-not $windowProcess.HasExited) { $windowProcess.Kill() }; $windowProcess.Dispose() }
        if (-not $process.HasExited) { $process.Kill() }; $process.Dispose()
    }
}

try {
    $launcherBytes = [Convert]::FromBase64String('T3B0aW9uIEV4cGxpY2l0CkRpbSBmcywgc2hlbGwsIHJvb3QsIHNjcmlwdCwgZGF0YVJvb3QsIHBvaW50ZXIsIHN0cmVhbSwgY29tbWFuZCwgbWlzc2luZ01lc3NhZ2UKU2V0IGZzID0gQ3JlYXRlT2JqZWN0KCJTY3JpcHRpbmcuRmlsZVN5c3RlbU9iamVjdCIpClNldCBzaGVsbCA9IENyZWF0ZU9iamVjdCgiV1NjcmlwdC5TaGVsbCIpCnJvb3QgPSBmcy5HZXRQYXJlbnRGb2xkZXJOYW1lKFdTY3JpcHQuU2NyaXB0RnVsbE5hbWUpCnNjcmlwdCA9IGZzLkJ1aWxkUGF0aChyb290LCAic3RhcnQtZ3VpLnBzMSIpCgpJZiBOb3QgZnMuRmlsZUV4aXN0cyhzY3JpcHQpIFRoZW4KICAgIGRhdGFSb290ID0gc2hlbGwuRXhwYW5kRW52aXJvbm1lbnRTdHJpbmdzKCIlTE9DQUxBUFBEQVRBJSIpCiAgICBwb2ludGVyID0gZnMuQnVpbGRQYXRoKGZzLkdldFBhcmVudEZvbGRlck5hbWUoV1NjcmlwdC5TY3JpcHRGdWxsTmFtZSksICJpbnN0YWxsLXBhdGgudHh0IikKICAgIElmIE5vdCBmcy5GaWxlRXhpc3RzKHBvaW50ZXIpIFRoZW4gcG9pbnRlciA9IGZzLkJ1aWxkUGF0aChkYXRhUm9vdCwgIkNvZGV4UHJvZmlsZVN3aXRjaGVyXExhdW5jaGVyXGluc3RhbGwtcGF0aC50eHQiKQogICAgSWYgZnMuRmlsZUV4aXN0cyhwb2ludGVyKSBUaGVuCiAgICAgICAgU2V0IHN0cmVhbSA9IGZzLk9wZW5UZXh0RmlsZShwb2ludGVyLCAxLCBGYWxzZSwgMCkKICAgICAgICByb290ID0gVHJpbShzdHJlYW0uUmVhZEFsbCkKICAgICAgICBzdHJlYW0uQ2xvc2UKICAgICAgICBJZiBMZW4ocm9vdCkgPiAwIFRoZW4gc2NyaXB0ID0gZnMuQnVpbGRQYXRoKHJvb3QsICJzdGFydC1ndWkucHMxIikKICAgIEVuZCBJZgpFbmQgSWYKCklmIE5vdCBmcy5GaWxlRXhpc3RzKHNjcmlwdCkgVGhlbgogICAgbWlzc2luZ01lc3NhZ2UgPSBDaHJXKCZINjI3RSkgJiBDaHJXKCZINEUwRCkgJiBDaHJXKCZINTIzMCkgJiBDaHJXKCZINTIwNykgJiBDaHJXKCZINjM2MikgJiBDaHJXKCZINTY2OCkgJiBDaHJXKCZIN0EwQikgJiBDaHJXKCZINUU4RikgJiBDaHJXKCZIRkYwQykgJiBDaHJXKCZI O E JGNykgJiBDaHJXKCZIOTFDRCkgJiBDaHJXKCZINjVCMCkgJiBDaHJXKCZIOEZEMCkgJiBDaHJXKCZIODg0QykgJiBDaHJXKCZINUI4OSkgJiBDaHJXKCZIODhDNSkgJiBDaHJXKCZINTMwNSkgJiBDaHJXKCZIMzAwMikKICAgIE1zZ0JveCBtaXNzaW5nTWVzc2FnZSwgdmJFeGNsYW1hdGlvbiwgIkNvZGV4ICIgJiBDaHJXKCZIOEQyNikgJiBDaHJXKCZINTNGNykgJiBDaHJXKCZINTIwNykgJiBDaHJXKCZINjM2MikKICAgIFdTY3JpcHQuUXVpdCAxCkVuZCBJZgoKY29tbWFuZCA9ICJwb3dlcnNoZWxsLmV4ZSAtTm9Mb2dvIC1Ob1Byb2ZpbGUgLUV4ZWN1dGlvblBvbGljeSBCeXBhc3MgLVNUQSAtV2luZG93U3R5bGUgSGlkZGVuIC1GaWxlICIgJiBDaHIoMzQpICYgc2NyaXB0ICYgQ2hyKDM0KQpzaGVsbC5SdW4gY29tbWFuZCwgMCwgRmFsc2UK');
    $expectedLegacyHash = 'c76301c7fa887265fbc97dd3fca0dbf5efa6c15d95ecb6583d6b25c297b09413'
    [void][IO.Directory]::CreateDirectory($launcherRoot)
    $launcher = Join-Path $launcherRoot 'CodexProfileSwitcher.vbs'
    [IO.File]::WriteAllBytes($launcher, $launcherBytes)
    if ((Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedLegacyHash) { throw 'The embedded legacy launcher fixture does not match the installer migration signature.' }
    $notesDirectory = Join-Path $installRoot 'docs\zh-CN\releases'
    [void][IO.Directory]::CreateDirectory($notesDirectory)
    $oldNote = Join-Path $notesDirectory '0.3.14.md'
    $modifiedNote = Join-Path $notesDirectory '0.3.13.md'
    $unknownNote = Join-Path $notesDirectory '99.0.0.md'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\docs\zh-CN\releases\0.3.14.md') -Destination $oldNote
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\docs\zh-CN\releases\0.3.13.md') -Destination $modifiedNote
    [IO.File]::AppendAllText($modifiedNote, 'user custom note')
    [IO.File]::WriteAllText($unknownNote, 'unknown user file')
    $modifiedNoteHash = (Get-FileHash -LiteralPath $modifiedNote).Hash
    Invoke-IsolatedInstall
    if (-not (Test-Path -LiteralPath $testUninstallKey)) { throw 'The test installation did not use its own uninstall registration.' }
    Assert-InstalledManifest
    Invoke-IsolatedCli
    Invoke-IsolatedGui
    Invoke-IsolatedGui $true
    if ([IO.File]::Exists($oldNote)) { throw 'Known retired release note was not removed.' }
    if ((Get-FileHash -LiteralPath $modifiedNote).Hash -cne $modifiedNoteHash -or [IO.File]::ReadAllText($unknownNote) -cne 'unknown user file') { throw 'Release note cleanup changed user content.' }

    $legacyBackup = $launcher + '.legacy-0.2.9.bak'
    $pointer = Join-Path $launcherRoot 'install-path.txt'
    if (-not [IO.File]::Exists($launcher) -or -not [IO.File]::Exists($pointer)) { throw 'Fixed launcher or install path pointer is missing.' }
    if (-not [IO.File]::Exists($legacyBackup)) { throw 'Known legacy fixed launcher was not backed up before migration.' }
    if ((Get-FileHash -LiteralPath $legacyBackup -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expectedLegacyHash) { throw 'Legacy fixed launcher backup does not match the original bytes.' }
    if ([IO.File]::ReadAllText($pointer).Trim() -cne $installRoot) { throw 'Fixed launcher points outside the temporary installation.' }
    if ((Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath (Join-Path $installRoot 'CodexProfileSwitcher.vbs') -Algorithm SHA256).Hash) { throw 'New installation did not create the fixed launcher from the published launcher.' }
    $installerSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\installer\CodexProfileSwitcher.iss'))
    if (-not $installerSource.Contains('Name: "chinesesimplified"; MessagesFile: "Languages\ChineseSimplified.isl"')) {
        throw 'Installer does not configure Simplified Chinese.'
    }
    if ($PreviousDotNetLauncherPath) {
        $previousHash = '5c3d1fdf6ad3c61eb348cd5af6747f43e8f13a6e604b2575d060e9b315cb8339'
        if ((Get-FileHash -LiteralPath $PreviousDotNetLauncherPath -Algorithm SHA256).Hash.ToLowerInvariant() -cne $previousHash) {
            throw 'Previous .NET launcher fixture does not match the migration signature.'
        }
        Copy-Item -LiteralPath $PreviousDotNetLauncherPath -Destination $launcher -Force
        Invoke-IsolatedInstall
        $previousBackup = $launcher + '.legacy-0.3.6.bak'
        if (-not [IO.File]::Exists($previousBackup) -or
            (Get-FileHash -LiteralPath $previousBackup -Algorithm SHA256).Hash.ToLowerInvariant() -cne $previousHash) {
            throw 'Previous .NET launcher was not backed up before migration.'
        }
        if ((Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath (Join-Path $installRoot 'CodexProfileSwitcher.vbs') -Algorithm SHA256).Hash) {
            throw 'Previous .NET launcher was not upgraded to the current launcher.'
        }
    }

    $whitespaceFixture = Join-Path $PSScriptRoot 'fixtures\launcher-0.3.15.vbs'
    $whitespaceHash = 'dee96d24623c981d6da0fa9da363c05126b866981f3226f741c67f546adb974e'
    if ((Get-FileHash -LiteralPath $whitespaceFixture).Hash.ToLowerInvariant() -cne $whitespaceHash) { throw 'Previous whitespace launcher fixture changed.' }
    Copy-Item -LiteralPath $whitespaceFixture -Destination $launcher -Force
    Invoke-IsolatedInstall
    Assert-InstalledManifest
    if ((Get-FileHash -LiteralPath ($launcher + '.legacy-0.3.15.bak')).Hash.ToLowerInvariant() -cne $whitespaceHash) { throw 'Whitespace launcher was not backed up.' }
    if ((Get-FileHash -LiteralPath $launcher).Hash -cne (Get-FileHash -LiteralPath (Join-Path $installRoot 'CodexProfileSwitcher.vbs')).Hash) { throw 'Whitespace launcher was not upgraded.' }
    Invoke-IsolatedGui $true

    [IO.File]::AppendAllText($launcher, "`r`n'custom launch marker")
    $changedHash = (Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash
    Invoke-IsolatedInstall
    if ((Get-FileHash -LiteralPath $launcher -Algorithm SHA256).Hash -ne $changedHash) { throw 'Upgrade overwrote a user-modified fixed launcher.' }
    if ([IO.File]::ReadAllText((Join-Path $launcherRoot 'install-path.txt')).Trim() -cne $installRoot) { throw "Upgrade did not refresh the fixed launcher's install path." }

    if (-not [IO.File]::Exists($uninstaller)) { throw 'Inno Setup uninstaller was not created.' }
    $process = Start-Process -FilePath $uninstaller -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -WindowStyle Hidden -Wait -PassThru
    try { if ($process.ExitCode -ne 0) { throw "Uninstaller exited with code $($process.ExitCode)." } }
    finally { $process.Dispose() }
    $uninstalled = $true
    if (Test-Path -LiteralPath $testUninstallKey) { throw 'The isolated uninstall registration was not removed.' }
    if (-not [IO.File]::Exists($retainedMarker)) { throw 'Uninstall removed the temporary app data marker.' }
    if (-not [IO.Directory]::Exists($codexHome)) { throw 'Uninstall removed the temporary CODEX_HOME.' }
    if (-not [IO.File]::Exists((Join-Path $launcherRoot 'CodexProfileSwitcher.vbs'))) { throw 'Uninstall removed the fixed launcher.' }
    foreach ($kind in @('desktop', 'startmenu')) {
        if ([IO.File]::Exists((Join-Path $installRoot ('test-shortcuts\' + $kind + '\Codex 账号切换.lnk')))) {
            throw 'Uninstall left an isolated application shortcut behind.'
        }
    }
    Assert-UserShortcutsUnchanged $userShortcuts

    Write-Output 'Installer integration passed: checksum, isolated install and shortcuts, real desktop/Start Menu unchanged, self-contained payload, CLI, WPF startup/close, fixed launcher, upgrade preservation, uninstall, and data retention.'
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
        [IO.Path]::GetFileName($testRoot) -like 'CodexSwitcherInstallTest-*') {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
    elseif ([IO.Directory]::Exists($testRoot)) {
        Write-Warning "Temporary installation test files retained at $testRoot because validation or uninstall did not finish."
    }
    Assert-UserShortcutsUnchanged $userShortcuts
}
