@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0check_android_v1_evidence_bundle.ps1" %*
