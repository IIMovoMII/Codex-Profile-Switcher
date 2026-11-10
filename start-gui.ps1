#requires -Version 5.1
[CmdletBinding()]
param([string]$CodexHome,[string]$DataDir,[string]$CodexExecutable,[string]$MonitorDataDir,[switch]$NoShow)
$ErrorActionPreference='Stop'
try {
    & (Join-Path $PSScriptRoot 'codex-switcher-gui.ps1') @PSBoundParameters
} catch {
    Add-Type -AssemblyName System.Windows.Forms
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'Codex 账号切换：启动未完成','OK','Error')
    exit 1
}
