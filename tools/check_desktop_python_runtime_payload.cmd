@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_desktop_python_runtime_payload.ps1" %*
exit /b %ERRORLEVEL%
