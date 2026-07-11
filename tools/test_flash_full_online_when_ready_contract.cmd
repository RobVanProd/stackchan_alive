@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0test_flash_full_online_when_ready_contract.ps1" %*
exit /b %ERRORLEVEL%
