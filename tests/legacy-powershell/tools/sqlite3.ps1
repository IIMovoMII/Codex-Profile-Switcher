#requires -Version 5.1
# Compatible with the small SQLite command surface used by the switcher.
# Uses the Windows SQLite DLL in the current process, without downloads.
$ErrorActionPreference='Stop'
if($null -eq ('WindowsSqlite' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'WindowsSqlite.cs') }
$sqlInput=($input | ForEach-Object {[string]$_}) -join [Environment]::NewLine
$outputWriter=New-Object IO.StringWriter([Globalization.CultureInfo]::InvariantCulture)
$errorWriter=New-Object IO.StringWriter([Globalization.CultureInfo]::InvariantCulture)
$previousOutput=[Console]::Out;$previousError=[Console]::Error
try {
    [Console]::SetOut($outputWriter);[Console]::SetError($errorWriter)
    $nativeExit=[WindowsSqlite]::Execute([string[]]$args,$sqlInput)
} finally { [Console]::SetOut($previousOutput);[Console]::SetError($previousError) }
$result=$outputWriter.ToString().TrimEnd([char[]]@("`r","`n"))
if($result.Length -gt 0){[regex]::Split($result,'\r?\n') | Write-Output}
if($errorWriter.ToString().Length -gt 0){Write-Error -Message $errorWriter.ToString().Trim() -ErrorAction Continue}
$outputWriter.Dispose();$errorWriter.Dispose()
exit $nativeExit
