@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0test_full_online_flash_readiness_contract.ps1" %*
exit /b %ERRORLEVEL%
