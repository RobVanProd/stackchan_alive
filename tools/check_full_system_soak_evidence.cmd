@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_full_system_soak_evidence.ps1" %*
exit /b %ERRORLEVEL%
