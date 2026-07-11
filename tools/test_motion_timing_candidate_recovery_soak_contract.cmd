@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0test_motion_timing_candidate_recovery_soak_contract.ps1" %*
exit /b %ERRORLEVEL%
