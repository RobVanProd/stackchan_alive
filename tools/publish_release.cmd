@echo off
setlocal
set "STACKCHAN_PUBLISH_POWERSHELL=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%STACKCHAN_PUBLISH_POWERSHELL%" (
  echo Exact Windows PowerShell executable not found. 1>&2
  exit /b 1
)
"%STACKCHAN_PUBLISH_POWERSHELL%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0publish_release.ps1" %*
