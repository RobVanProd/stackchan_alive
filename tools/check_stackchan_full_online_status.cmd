@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_stackchan_full_online_status.ps1" %*
exit /b %ERRORLEVEL%
