@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start_stackchan_dashboard.ps1" %*
exit /b %ERRORLEVEL%
