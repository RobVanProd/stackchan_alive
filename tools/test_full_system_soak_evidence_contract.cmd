@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0test_full_system_soak_evidence_contract.ps1" %*
exit /b %ERRORLEVEL%
