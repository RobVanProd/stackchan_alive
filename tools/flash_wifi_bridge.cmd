@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0flash_wifi_bridge.ps1" %*
exit /b %ERRORLEVEL%
