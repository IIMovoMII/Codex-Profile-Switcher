@echo off
setlocal EnableExtensions EnableDelayedExpansion
for /f "tokens=2 delims=:" %%C in ('chcp') do set "_CODEX_OLD_CP=%%C"
set "_CODEX_OLD_CP=!_CODEX_OLD_CP: =!"
chcp 65001 >nul
where pwsh.exe >nul 2>nul
if !errorlevel! equ 0 (
  pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-profile-switcher.ps1" %*
) else (
  powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-profile-switcher.ps1" %*
)
set "_CODEX_SWITCH_EXIT=!errorlevel!"
if not "%CODEX_SWITCHER_NO_PAUSE%"=="1" (
  echo.
  echo 按任意键退出 . . .
  pause >nul
)
if defined _CODEX_OLD_CP chcp !_CODEX_OLD_CP! >nul
exit /b !_CODEX_SWITCH_EXIT!
