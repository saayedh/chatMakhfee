@echo off
setlocal
set "ROOT=%~dp0.."
set "APKARG="
if /I "%~1"=="--include-apk" set "APKARG=-IncludeDownloadedApk"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0package-project.ps1" -ProjectRoot "%ROOT%" %APKARG%
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" echo [X] ZIP packaging failed. Check the output above.
pause
exit /b %RC%
