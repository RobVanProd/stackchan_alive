@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0test_pc_brain_runtime_check_contract.ps1" %*
exit /b %ERRORLEVEL%
