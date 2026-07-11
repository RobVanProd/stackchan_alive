@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0collect_full_online_validation_evidence.ps1" %*
exit /b %ERRORLEVEL%
