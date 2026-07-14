@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_release_credential_hygiene.ps1" %*
