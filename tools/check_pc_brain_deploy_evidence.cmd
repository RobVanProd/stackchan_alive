@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_pc_brain_deploy_evidence.ps1" %*
exit /b %ERRORLEVEL%
