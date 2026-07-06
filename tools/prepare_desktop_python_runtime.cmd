@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0prepare_desktop_python_runtime.ps1" %*
exit /b %ERRORLEVEL%
