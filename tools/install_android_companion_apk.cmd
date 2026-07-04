@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_android_companion_apk.ps1" %*
exit /b %ERRORLEVEL%
