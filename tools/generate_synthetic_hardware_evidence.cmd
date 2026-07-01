@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0generate_synthetic_hardware_evidence.ps1" %*
