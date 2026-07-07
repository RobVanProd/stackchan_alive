@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0test_android_pairing_evidence_contract.ps1" %*
exit /b %ERRORLEVEL%
