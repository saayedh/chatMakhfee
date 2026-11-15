@echo off
setlocal EnableExtensions
title SecretPlay - stop local relay

set PIDFILE=%~dp0..\local_server\.secretplay.pid

echo ============================================================
echo   SecretPlay - stopping the local relay
echo ============================================================
echo.

if not exist "%PIDFILE%" (
  echo [i] No PID file found. The relay may already be stopped.
  echo     If a Node window is still running, close it or end it in Task Manager.
  echo.
  pause
  exit /b 0
)

set /p SP_PID=<"%PIDFILE%"
if "%SP_PID%"=="" (
  echo [i] PID file is empty. Removing it.
  del /q "%PIDFILE%" >nul 2>nul
  pause
  exit /b 0
)

echo [i] Stopping process %SP_PID%...
tasklist /FI "PID eq %SP_PID%" | find /I "%SP_PID%" >nul
if errorlevel 1 (
  echo [i] That process is no longer running. Removing the stale PID file.
  del /q "%PIDFILE%" >nul 2>nul
  pause
  exit /b 0
)

taskkill /PID %SP_PID% /T /F >nul 2>nul
if errorlevel 1 (
  echo [!] Could not stop PID %SP_PID%. Close its console window manually.
) else (
  echo [OK] Relay stopped. Sessions are gone: nothing was persisted.
)

del /q "%PIDFILE%" >nul 2>nul
echo.
pause
endlocal
