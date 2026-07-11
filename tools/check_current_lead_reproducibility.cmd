@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_current_lead_reproducibility.ps1" %*
exit /b %ERRORLEVEL%
