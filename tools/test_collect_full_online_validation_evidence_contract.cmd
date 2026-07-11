@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0test_collect_full_online_validation_evidence_contract.ps1" %*
exit /b %ERRORLEVEL%
