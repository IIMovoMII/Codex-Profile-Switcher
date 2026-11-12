# Explicit source files for the installer. Runtime files come only from dotnet publish.
$script:DistributionFiles = @(
    'CodexProfileSwitcher.vbs',
    'Codex切换.vbs',
    'start.vbs',
    'codex-switcher.cmd',
    'switch-api.cmd',
    'switch-official.cmd',
    'README.md',
    'CONTRIBUTING.md',
    'CHANGELOG.md',
    'LICENSE.txt',
    'THIRD-PARTY-NOTICES.txt',
    'docs\zh-CN\INSTALL.md',
    'docs\images\accounts.jpg',
    ('docs\zh-CN\releases\' + ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'version.txt')).Trim()) + '.md')
)

function Get-PublishedDistributionFiles {
    param([Parameter(Mandatory = $true)][string]$PublishDirectory)

    $fullDirectory = [IO.Path]::GetFullPath($PublishDirectory)
    if (-not [IO.Directory]::Exists($fullDirectory)) { throw "发布目录不存在：$fullDirectory" }
    $allowedExtensions = @('.exe', '.dll', '.json', '.dat', '.bin', '.pri', '.xml')
    $files = @(Get-ChildItem -LiteralPath $fullDirectory -File -Recurse | Sort-Object FullName)
    if ($files.Count -eq 0) { throw 'dotnet publish 没有生成任何文件。' }

    foreach ($file in $files) {
        $relative = $file.FullName.Substring($fullDirectory.TrimEnd('\').Length).TrimStart('\')
        if ([IO.Path]::IsPathRooted($relative) -or $relative -match '(^|[\\/])\.\.([\\/]|$)') {
            throw "发布输出包含越界路径：$relative"
        }
        if ([IO.Path]::GetExtension($file.Name).ToLowerInvariant() -notin $allowedExtensions) {
            throw "发布输出包含未批准的文件类型：$relative"
        }
        if ($file.Extension -in @('.pdb', '.ps1', '.psm1', '.psd1', '.vbs', '.cmd')) {
            throw "发布输出包含禁止分发的文件：$relative"
        }
        [pscustomobject]@{ Path = $relative; Source = $file.FullName }
    }
}
