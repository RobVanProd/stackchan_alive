@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0open_voice_audition.ps1" %*
exit /b %ERRORLEVEL%
