#requires -Version 5.1
[CmdletBinding()]
param([string]$RealStatePath)
$script:ProjectRoot = Split-Path -Parent $PSScriptRoot

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $script:ProjectRoot 'codex-desktop-state.ps1')
function Assert([bool]$Test, [string]$Message) { if (-not $Test) { throw $Message } }
$text = '{"path":"D:\\项目","n":7,"bool":true,"nil":null,"empty":[],"one":["D:\\项目"],"nested":[[],["one"],[true,7,null]],"date":"2026-11-07T15:26:20.2726981Z"}'
$root = Read-DesktopJson $text
$copy = Copy-DesktopValue $root
Assert ($copy['path'] -is [string] -and $copy['path'] -eq $root['path']) 'JSON string converted to an object.'
Assert ($copy['date'] -is [string] -and $copy['date'] -eq '2026-11-07T15:26:20.2726981Z') 'Date string changed type/value.'
foreach ($name in @('empty', 'one', 'nested')) {
    $separateCopy = Copy-DesktopValue $root[$name]
    Assert ($separateCopy -is [System.Collections.IList]) ('Array lost shape: ' + $name)
    Assert ((ConvertTo-Json -InputObject $separateCopy -Depth 100 -Compress) -ceq
        (ConvertTo-Json -InputObject $root[$name] -Depth 100 -Compress)) ('Array value changed: ' + $name)
}
Assert ($copy['nested'][0].Count -eq 0 -and $copy['nested'][1].Count -eq 1) 'Nested empty/singleton array changed.'
$copy['nested'][1][0] = 'changed'
Assert ($root['nested'][1][0] -ceq 'one') 'Copy shares mutable array references.'
$broken = Read-DesktopJson '{"active-workspace-roots":[{"Length":9}]}'
$failed = $false
try { Assert-DesktopGlobals $broken } catch { $failed = $true }
Assert $failed 'Corrupt path was not blocked.'
$failed = $false
try { Assert-DesktopGlobals (Read-DesktopJson '{"local-projects":{"p":{"name":"p","rootPaths":[null]}}}') } catch { $failed = $true }
Assert $failed 'Null root path was not blocked.'
if ($RealStatePath) {
    $before = (Get-FileHash -LiteralPath $RealStatePath).Hash
    $real = Read-DesktopJson ([IO.File]::ReadAllText($RealStatePath))
    $roundTrip = Read-DesktopJson (ConvertTo-Json -InputObject (Copy-DesktopValue $real) -Depth 100 -Compress)
    Assert ((ConvertTo-DesktopCanonicalJson $real) -ceq (ConvertTo-DesktopCanonicalJson $roundTrip)) 'Real JSON round-trip differs.'
    Assert-DesktopJsonShape $roundTrip
    Assert ((Get-FileHash -LiteralPath $RealStatePath).Hash -ceq $before) 'Read-only production test changed the source.'
    Write-Output 'Read-only real-state round trip: PASS'
}
Write-Output ('Desktop JSON scalars/arrays/guard regression: PASS (' + $PSVersionTable.PSVersion + ')')
