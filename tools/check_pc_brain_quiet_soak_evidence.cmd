@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_pc_brain_quiet_soak_evidence.ps1" %*
exit /b %ERRORLEVEL%
