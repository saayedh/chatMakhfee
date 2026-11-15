@echo off
setlocal
set "ROOT=%~dp0.."
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-android-signing.ps1" -ProjectRoot "%ROOT%"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" echo [X] Android signing setup did not complete.
pause
exit /b %RC%
