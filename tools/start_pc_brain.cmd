@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start_pc_brain.ps1" %*
exit /b %ERRORLEVEL%
