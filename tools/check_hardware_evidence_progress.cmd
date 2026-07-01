@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_hardware_evidence_progress.ps1" %*
