@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_desktop_target_install_evidence.ps1" %*
