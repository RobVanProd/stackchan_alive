@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_privacy_policy_deployment.ps1" %*
exit /b %ERRORLEVEL%
