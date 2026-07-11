@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_pc_brain_runtime.ps1" %*
exit /b %ERRORLEVEL%
