@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0export_companion_release_evidence.ps1" %*
