@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_android_companion_soak.ps1" %*
exit /b %ERRORLEVEL%
