@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0render_rvc_audition_mp3s.ps1" %*
exit /b %ERRORLEVEL%
