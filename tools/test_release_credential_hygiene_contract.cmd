@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0test_release_credential_hygiene_contract.ps1" %*
