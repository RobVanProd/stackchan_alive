@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0write_body_clear_attestation.ps1" %*
exit /b %ERRORLEVEL%
