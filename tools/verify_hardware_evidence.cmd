@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify_hardware_evidence.ps1" %*
