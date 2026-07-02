@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify_release_asset_contract.ps1" %*
