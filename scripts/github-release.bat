@echo off
setlocal
set "ROOT=%~dp0.."
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0github-release.ps1" -ProjectRoot "%ROOT%"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" echo [X] Release tag was not pushed. See the errors above.
pause
exit /b %RC%
