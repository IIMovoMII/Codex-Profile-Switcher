@echo off
call "%~dp0codex-switcher.cmd" api %*
exit /b %ERRORLEVEL%
