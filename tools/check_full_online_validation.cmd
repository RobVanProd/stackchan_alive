@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_full_online_validation.ps1" %*
exit /b %ERRORLEVEL%
