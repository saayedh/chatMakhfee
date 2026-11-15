@echo off
setlocal
set "ROOT=%~dp0.."
set "WAITARG="
if /I "%~1"=="--wait" set "WAITARG=-Wait"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0github-build-download.ps1" -ProjectRoot "%ROOT%" %WAITARG%
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" echo [!] APK download did not complete. Check GitHub Actions and the report above.
pause
exit /b %RC%
