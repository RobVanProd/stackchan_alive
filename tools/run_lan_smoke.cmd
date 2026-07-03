@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_lan_smoke.ps1" %*
exit /b %ERRORLEVEL%
