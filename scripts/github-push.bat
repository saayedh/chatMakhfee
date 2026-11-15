@echo off
setlocal
set "ROOT=%~dp0.."
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0github-push.ps1" -ProjectRoot "%ROOT%"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" echo [X] GitHub push did not complete. Review the message above.
pause
exit /b %RC%
