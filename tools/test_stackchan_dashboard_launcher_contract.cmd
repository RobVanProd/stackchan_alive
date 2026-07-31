@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0test_stackchan_dashboard_launcher_contract.ps1"
exit /b %ERRORLEVEL%
