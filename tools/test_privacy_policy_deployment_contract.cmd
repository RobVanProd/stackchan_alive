@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0test_privacy_policy_deployment_contract.ps1" %*
exit /b %ERRORLEVEL%
