@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0flash_full_online_when_ready.ps1" %*
exit /b %ERRORLEVEL%
