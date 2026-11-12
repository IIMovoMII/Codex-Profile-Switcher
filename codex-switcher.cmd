@echo off
setlocal EnableExtensions DisableDelayedExpansion
if not exist "%~dp0Switcher.Cli.exe" goto missing
"%~dp0Switcher.Cli.exe" %*
set "_CODEX_SWITCH_EXIT=%ERRORLEVEL%"
goto finish
:missing
echo Switcher.Cli.exe was not found. Run the installer or publish the solution.
set "_CODEX_SWITCH_EXIT=2"
:finish
if not "%CODEX_SWITCHER_NO_PAUSE%"=="1" (
  echo.
  pause
)
exit /b %_CODEX_SWITCH_EXIT%
