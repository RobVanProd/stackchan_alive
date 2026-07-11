@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0test_full_online_preflight_contract.ps1" %*
exit /b %ERRORLEVEL%
