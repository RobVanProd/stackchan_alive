@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_selected_voice_once.ps1" %*
exit /b %ERRORLEVEL%
