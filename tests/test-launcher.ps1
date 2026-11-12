#requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$root = Join-Path $tempBase ('CodexSwitcherLauncherTest-' + [Guid]::NewGuid().ToString('N'))
if (-not $root.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) { throw 'Test root escaped the temporary directory.' }
$launcherRoot = Join-Path $root 'fixed launcher'
$sourceRoot = Join-Path $root '源码 中文'
$publishRoot = Join-Path $sourceRoot 'artifacts\publish\当前发布 中文'
$localAppData = Join-Path $root 'isolated local app data'
$output = Join-Path $root 'probe-output.txt'
foreach ($directory in @($launcherRoot, $publishRoot, $localAppData)) { [void][IO.Directory]::CreateDirectory($directory) }
$utf8 = New-Object Text.UTF8Encoding($false)
$originalInputEncoding = [Console]::InputEncoding

function Quote-WindowsArgument([string]$Value) {
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Invoke-Launcher([string]$Name, [string[]]$Arguments, [int]$ExpectedExit = 23) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $env:SystemRoot 'System32\cscript.exe'
    $start.Arguments = '//Nologo ' + (Quote-WindowsArgument (Join-Path $launcherRoot $Name)) + ' ' +
        ((@($output) + $Arguments | ForEach-Object { Quote-WindowsArgument $_ }) -join ' ')
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['LOCALAPPDATA'] = $localAppData
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'Launcher timed out.' }
        $text = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne $ExpectedExit) { throw "Launcher returned $($process.ExitCode), expected ${ExpectedExit}: $text" }
        if ($ExpectedExit -eq 23) {
            if (-not [IO.File]::Exists($output)) { throw 'Launcher did not execute the probe.' }
            $lines = [IO.File]::ReadAllLines($output, [Text.Encoding]::UTF8)
            if ($lines[0] -cne $publishRoot) { throw 'Launcher did not set the executable working directory.' }
            if ($lines.Length -ne $Arguments.Length + 1) { throw ('Launcher changed the argument count: ' + (ConvertTo-Json -InputObject $lines -Compress)) }
            for ($index = 0; $index -lt $Arguments.Length; $index++) {
                if ($lines[$index + 1] -cne $Arguments[$index]) { throw "Launcher changed argument $index." }
            }
            [IO.File]::Delete($output)
        }
        else {
            if ($text -match 'runtime error|compilation error') { throw "Launcher script failed: $text" }
            if ([IO.File]::Exists($output)) { throw 'Missing-target launch unexpectedly executed an app.' }
        }
    }
    finally { $process.Dispose() }
}

function Invoke-CmdLauncher([string]$Name, [string[]]$Arguments, [int]$ExpectedExit, [bool]$NoPause = $false) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $start.Arguments = '/d /s /c ""' + (Join-Path $launcherRoot $Name) + '" ' +
        (($Arguments | ForEach-Object { Quote-WindowsArgument $_ }) -join ' ') + '"'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['LOCALAPPDATA'] = $localAppData
    $start.EnvironmentVariables['LAUNCHER_PROBE_OUTPUT'] = $output
    $start.EnvironmentVariables['LAUNCHER_PROBE_EXIT'] = [string]$ExpectedExit
    $start.EnvironmentVariables['CODEX_SWITCHER_NO_PAUSE'] = $(if ($NoPause) { '1' } else { '0' })
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stderr = $process.StandardError.ReadToEndAsync()
        $ready = $process.StandardOutput.ReadLineAsync()
        if (-not $ready.Wait(5000) -or $ready.Result -cne 'CMD_ENGINE_READY') { throw 'CMD did not launch the EXE probe.' }
        $stdout = $process.StandardOutput.ReadToEndAsync()
        if (-not $NoPause) {
            if ($process.WaitForExit(200)) {
                $earlyOutput = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
                throw "CMD $Name exited before waiting for a key (exit $($process.ExitCode), no-pause $NoPause): $earlyOutput"
            }
            $process.StandardInput.WriteLine('x')
        }
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(5000)) { throw 'CMD launcher timed out.' }
        $text = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne $ExpectedExit) { throw "CMD returned $($process.ExitCode), expected ${ExpectedExit}: $text" }
        $pauseCount = [regex]::Matches($text, '\. \. \.').Count
        if ($pauseCount -ne $(if ($NoPause) { 0 } else { 1 })) { throw 'CMD pause count is incorrect.' }
        $expected = @($Arguments)
        if ($Name -eq 'switch-api.cmd') { $expected = @('api') + $expected }
        if ($Name -eq 'switch-official.cmd') { $expected = @('official') + $expected }
        $actual = @([IO.File]::ReadAllLines($output, [Text.Encoding]::UTF8))
        if ($actual.Length -ne $expected.Length) { throw 'CMD changed the argument count.' }
        for ($index = 0; $index -lt $expected.Length; $index++) {
            if ($actual[$index] -cne $expected[$index]) { throw "CMD changed argument $index." }
        }
        [IO.File]::Delete($output)
    }
    finally {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit() }
        $process.Dispose()
    }
}

try {
    $probeSource = Join-Path $root 'LauncherProbe.cs'
    $probeExe = Join-Path $publishRoot 'CodexProfileSwitcher.exe'
    [IO.File]::WriteAllText($probeSource, @'
using System;
using System.IO;
using System.Text;
internal static class LauncherProbe {
    static int Main(string[] args) {
        if (args.Length == 0) return 99;
        var lines = new string[args.Length];
        lines[0] = Environment.CurrentDirectory;
        Array.Copy(args, 1, lines, 1, args.Length - 1);
        File.WriteAllLines(args[0], lines, new UTF8Encoding(false));
        return 23;
    }
}
'@, $utf8)
    $compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $compiler /nologo /target:exe ("/out:$probeExe") $probeSource
    if ($LASTEXITCODE -ne 0) { throw 'Launcher probe compilation failed.' }
    foreach ($name in @('CodexProfileSwitcher.vbs', 'Codex切换.vbs', 'start.vbs')) {
        Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination (Join-Path $launcherRoot $name)
    }
    $pointer = Join-Path $launcherRoot 'install-path.txt'
    [IO.File]::WriteAllText((Join-Path $sourceRoot 'artifacts\publish\current-path.txt'), $publishRoot, $utf8)
    $arguments = @('--codex-home', '中文 path & symbols', '--data-dir', 'subdir (test)', '--codex-exe', 'C:\isolated path\fake.exe')

    [IO.File]::WriteAllText($pointer, $sourceRoot, $utf8)
    Invoke-Launcher 'CodexProfileSwitcher.vbs' $arguments
    Invoke-Launcher 'Codex切换.vbs' $arguments
    Invoke-Launcher 'start.vbs' $arguments

    [IO.File]::WriteAllText($pointer, $publishRoot, $utf8)
    Invoke-Launcher 'CodexProfileSwitcher.vbs' $arguments
    [IO.File]::WriteAllText($pointer, $publishRoot, [Text.Encoding]::Unicode)
    Invoke-Launcher 'CodexProfileSwitcher.vbs' $arguments
    [IO.File]::Delete($pointer)
    Copy-Item -LiteralPath $probeExe -Destination (Join-Path $launcherRoot 'CodexProfileSwitcher.exe')
    $originalPublishRoot = $publishRoot
    $publishRoot = $launcherRoot
    Invoke-Launcher 'CodexProfileSwitcher.vbs' $arguments
    $publishRoot = $originalPublishRoot
    [IO.File]::Delete((Join-Path $launcherRoot 'CodexProfileSwitcher.exe'))
    Invoke-Launcher 'CodexProfileSwitcher.vbs' @() 1
    Write-Output 'Launcher tests passed: real WSH, Chinese UTF-8/UTF-16 paths, source publish pointer, adjacent EXE, compatibility entries, argument quoting and exit codes.'

    # A BOM in redirected stdin must not act as a user key press for PAUSE.
    [Console]::InputEncoding = $utf8
    $cmdProbe = Join-Path $root 'CmdProbe.cs'
    [IO.File]::WriteAllText($cmdProbe, @'
using System;
using System.IO;
using System.Text;
internal static class CmdProbe {
    static int Main(string[] args) {
        File.WriteAllLines(Environment.GetEnvironmentVariable("LAUNCHER_PROBE_OUTPUT"), args, new UTF8Encoding(false));
        Console.WriteLine("CMD_ENGINE_READY");
        return int.Parse(Environment.GetEnvironmentVariable("LAUNCHER_PROBE_EXIT"));
    }
}
'@, $utf8)
    & $compiler /nologo /target:exe ('/out:' + (Join-Path $launcherRoot 'Switcher.Cli.exe')) $cmdProbe
    if ($LASTEXITCODE -ne 0) { throw 'CMD probe compilation failed.' }
    foreach ($name in @('codex-switcher.cmd', 'switch-api.cmd', 'switch-official.cmd')) {
        Copy-Item -LiteralPath (Join-Path $projectRoot $name) -Destination (Join-Path $launcherRoot $name)
    }
    foreach ($exitCode in @(0, 7)) {
        Invoke-CmdLauncher 'codex-switcher.cmd' @() $exitCode
        Invoke-CmdLauncher 'codex-switcher.cmd' @('status', '中文 path & symbols', 'subdir (test)', 'literal!value') $exitCode
        Invoke-CmdLauncher 'switch-api.cmd' @('中文 path & symbols') $exitCode
        Invoke-CmdLauncher 'switch-official.cmd' @('subdir (test)') $exitCode
    }
    Invoke-CmdLauncher 'codex-switcher.cmd' @('status') 7 $true
    Write-Output 'CMD launcher tests passed: 9 EXE cases, argument forwarding, one key wait, exit codes and no-pause automation.'
}
finally {
    [Console]::InputEncoding = $originalInputEncoding
    $resolved = [IO.Path]::GetFullPath($root)
    if ($resolved.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -like 'CodexSwitcherLauncherTest-*' -and [IO.Directory]::Exists($resolved)) {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
