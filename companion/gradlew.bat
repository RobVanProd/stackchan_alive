@echo off
setlocal

set "APP_HOME=%~dp0"
set "GRADLE_VERSION=9.6.1"
set "DIST_NAME=gradle-%GRADLE_VERSION%-bin"
set "DIST_URL=https://services.gradle.org/distributions/%DIST_NAME%.zip"
set "DIST_ROOT=%APP_HOME%\.gradle\wrapper\dists"
set "GRADLE_HOME=%DIST_ROOT%\gradle-%GRADLE_VERSION%"

if not exist "%GRADLE_HOME%\bin\gradle.bat" (
  if not exist "%DIST_ROOT%" mkdir "%DIST_ROOT%"
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri '%DIST_URL%' -UseBasicParsing -OutFile '%DIST_ROOT%\%DIST_NAME%.zip'; Expand-Archive -Path '%DIST_ROOT%\%DIST_NAME%.zip' -DestinationPath '%DIST_ROOT%' -Force"
  if errorlevel 1 exit /b %errorlevel%
)

call "%GRADLE_HOME%\bin\gradle.bat" %*
exit /b %errorlevel%
