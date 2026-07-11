@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0test_current_lead_reproducibility_contract.ps1" %*
exit /b %ERRORLEVEL%
