@echo off
setlocal EnableExtensions
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0ensure-gradle-wrapper.ps1" -ProjectRoot "%~dp0.."
set RESULT=%ERRORLEVEL%
if not "%RESULT%"=="0" (
  echo [X] Could not prepare the Gradle Wrapper. See the error above.
  pause
)
exit /b %RESULT%
