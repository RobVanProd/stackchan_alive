@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_android_play_release_readiness.ps1" %*
exit /b %ERRORLEVEL%
