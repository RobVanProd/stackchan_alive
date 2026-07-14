@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0test_companion_ci_candidate_contract.ps1" %*
