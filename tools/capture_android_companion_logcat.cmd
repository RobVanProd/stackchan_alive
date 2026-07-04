@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0capture_android_companion_logcat.ps1" %*
exit /b %ERRORLEVEL%
