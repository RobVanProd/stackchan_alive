@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_android_udp_beacon_probe.ps1" %*
exit /b %ERRORLEVEL%
