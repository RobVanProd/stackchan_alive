@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0sanitize_public_archive.ps1" %*
