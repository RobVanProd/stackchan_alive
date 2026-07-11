@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_full_online_preflight.ps1" %*
exit /b %ERRORLEVEL%
