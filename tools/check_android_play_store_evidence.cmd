@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_android_play_store_evidence.ps1" %*
exit /b %ERRORLEVEL%
