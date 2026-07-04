@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0test_android_logcat_capture_contract.ps1" %*
