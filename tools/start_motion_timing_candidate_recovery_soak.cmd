@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0start_motion_timing_candidate_recovery_soak.ps1" %*
exit /b %ERRORLEVEL%
