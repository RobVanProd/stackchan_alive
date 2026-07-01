@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_voice_tools.ps1" %*
exit /b %ERRORLEVEL%
