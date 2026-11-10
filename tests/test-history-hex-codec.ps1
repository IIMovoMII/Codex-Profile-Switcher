#requires -Version 5.1
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-hex-test-' + [Guid]::NewGuid().ToString('N'))
try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    . (Join-Path $script:ProjectRoot 'codex-history-compat.ps1') -Command scan -CodexHome $testRoot -BackupRoot (Join-Path $testRoot 'backup') | Out-Null
    $samples = @('', 'ASCII', (([char]0x4E2D).ToString() + [char]0x6587 + [char]0 + [char]0xD83D + [char]0xDE00), ('large-value-' * 100000))
    foreach ($sample in $samples) {
        $hex = [BitConverter]::ToString([Text.Encoding]::UTF8.GetBytes($sample)).Replace('-','')
        if ((ConvertFrom-HexUtf8 $hex) -cne $sample) { throw 'Upper-case hex round trip failed.' }
        if ((ConvertFrom-HexUtf8 $hex.ToLowerInvariant()) -cne $sample) { throw 'Lower-case hex round trip failed.' }
    }
    foreach ($bad in @('0','GG','0x','-1',' 1')) {
        $rejected = $false
        try { [void](ConvertFrom-HexUtf8 $bad) } catch { $rejected = $true }
        if (-not $rejected) { throw 'Malformed hex was accepted.' }
    }
    # Preserve the previous UTF-8 replacement fallback for malformed byte input.
    if ((ConvertFrom-HexUtf8 'FF') -cne [Text.Encoding]::UTF8.GetString([byte[]]@(255))) { throw 'UTF-8 behavior changed.' }
    Write-Host 'Hex codec tests passed (empty, Unicode, NUL, large value, invalid input).'
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notlike 'codex-hex-test-*') { throw 'Unsafe cleanup path.' }
    if ([IO.Directory]::Exists($resolved)) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
