@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0export_desktop_package_evidence.ps1" %*
