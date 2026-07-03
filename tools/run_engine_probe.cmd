@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_engine_probe.ps1" %*
