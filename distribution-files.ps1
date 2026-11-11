# Explicit source allowlist. Never copy a working directory, credentials or user state.
$script:DistributionFiles = @(
    'Codex切换.vbs','CodexProfileSwitcher.vbs','start.vbs','start-gui.ps1','codex-switcher-gui.ps1','ui\MainWindow.xaml',
    'codex-updates.ps1','version.txt',
    'codex-profile-switcher.ps1','codex-profile-registry.ps1','codex-switcher-service.ps1',
    'codex-desktop-state.ps1','codex-project-projection.ps1','codex-history-compat.ps1',
    'codex-history-incremental.ps1','CodexPortableHistory.cs',
    'tools\sqlite3.ps1','tools\WindowsSqlite.cs',
    'codex-switcher.cmd','switch-api.cmd','switch-official.cmd',
    'README.md','docs\zh-CN\INSTALL.md','CHANGELOG.md','LICENSE.txt'
)
