@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0test_stackchan_full_online_status_contract.ps1" %*
exit /b %ERRORLEVEL%
