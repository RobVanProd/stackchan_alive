@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_pc_brain_quiet_soak.ps1" %*
exit /b %ERRORLEVEL%
