@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0archive_current_lead.ps1" %*
exit /b %ERRORLEVEL%
