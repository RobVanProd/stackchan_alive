@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0test_android_rollout_status_contract.ps1" %*
