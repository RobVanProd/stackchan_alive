@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0test_android_diagnostics_export_evidence_contract.ps1" %*
