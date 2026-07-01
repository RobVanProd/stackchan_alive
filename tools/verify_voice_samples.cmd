@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify_voice_samples.ps1" %*
exit /b %ERRORLEVEL%
