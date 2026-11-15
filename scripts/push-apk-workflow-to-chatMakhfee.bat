@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..") do set "PROJECT_ROOT=%%~fI"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%push-apk-workflow-to-chatMakhfee.ps1" -ProjectRoot "%PROJECT_ROOT%"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo [ERROR] The APK workflow was not pushed. Read the error above.
) else (
  echo.
  echo [SUCCESS] Workflow pushed to https://github.com/saayedh/chatMakhfee
)
echo.
pause
exit /b %RC%
