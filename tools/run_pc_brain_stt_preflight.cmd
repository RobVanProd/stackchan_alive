@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_pc_brain_stt_preflight.ps1" %*
exit /b %ERRORLEVEL%
