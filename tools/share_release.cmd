@echo off
setlocal
set "STACKCHAN_SHARE_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%STACKCHAN_SHARE_POWERSHELL%" (
  echo Exact Windows PowerShell executable not found. 1>&2
  exit /b 1
)
"%STACKCHAN_SHARE_POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0share_release.ps1" %*
