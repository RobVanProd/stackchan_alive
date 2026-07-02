@echo off
setlocal
cd /d "%~dp0\.."
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0export_rollout_status.ps1" %*
exit /b %ERRORLEVEL%
