@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_bridge_reference_tests.ps1" %*
