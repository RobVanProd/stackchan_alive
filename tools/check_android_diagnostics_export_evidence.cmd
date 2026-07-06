@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_android_diagnostics_export_evidence.ps1" %*
