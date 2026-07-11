@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0test_full_online_validation_contract.ps1" %*
exit /b %ERRORLEVEL%
