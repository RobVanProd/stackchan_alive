@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_android_pairing_evidence.ps1" %*
exit /b %ERRORLEVEL%
