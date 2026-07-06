@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0collect_pc_brain_deploy_evidence.ps1" %*
exit /b %ERRORLEVEL%
