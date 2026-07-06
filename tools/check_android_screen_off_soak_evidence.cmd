@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_android_screen_off_soak_evidence.ps1" %*
exit /b %ERRORLEVEL%
