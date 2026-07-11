@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0watch_stackchan_wake_test.ps1" %*
exit /b %ERRORLEVEL%
