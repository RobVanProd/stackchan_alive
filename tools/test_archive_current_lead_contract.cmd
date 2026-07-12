@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0test_archive_current_lead_contract.ps1" %*
exit /b %ERRORLEVEL%
