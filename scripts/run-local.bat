@echo off
setlocal EnableExtensions
title SecretPlay - local relay

echo ============================================================
echo   SecretPlay - starting the local (offline) relay
echo ============================================================
echo.

where node >nul 2>nul
if errorlevel 1 (
  echo [X] Node.js was not found on PATH.
  echo     Install Node.js 22.18 LTS+ from https://nodejs.org
  pause
  exit /b 1
)
for /f "delims=" %%v in ('node -p "process.versions.node"') do set NODE_VERSION=%%v
node -e "const [a,b]=process.versions.node.split('.').map(Number); process.exit(a>22 || (a===22 && b>=18) ? 0 : 1)"
if errorlevel 1 (
  echo [X] Node.js 22.18.0 or newer is required. Found %NODE_VERSION%.
  pause
  exit /b 1
)

pushd "%~dp0..\local_server"
if errorlevel 1 (
  echo [X] Cannot find the local_server folder next to scripts\.
  pause
  exit /b 1
)

if not exist "node_modules\fastify" (
  echo [X] Dependencies are missing.
  echo     Run scripts\install-local.bat ONCE while this laptop has Internet.
  echo     Nothing else in this window requires Internet.
  popd
  pause
  exit /b 1
)

if not exist "node_modules\ws" (
  echo [X] The ws package is missing. Run scripts\install-local.bat again.
  popd
  pause
  exit /b 1
)

if not exist "..\crypto_core\node_modules\@noble\curves" (
  echo [X] Shared cryptography dependencies are missing.
  echo     Run scripts\install-local.bat while Internet is available.
  popd
  pause
  exit /b 1
)

if not exist ".env" (
  if exist ".env.example" copy /y ".env.example" ".env" >nul
)

echo [i] Node.js:
node --version
echo.
echo [i] Local IPv4 addresses on this machine:
powershell -NoProfile -Command "Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' } | ForEach-Object { '     {0}  ({1})' -f $_.IPAddress, $_.InterfaceAlias }" 2>nul
echo.
echo [i] Firewall: if phones cannot connect, allow Node.js on PRIVATE networks only.
echo     netsh advfirewall firewall show rule name="Node.js" >nul 2>nul
echo.
echo [i] Starting relay. The QR code and admin token appear below.
echo     Press Ctrl+C or run scripts\stop-local.bat to stop.
echo.

node --env-file-if-exists=.env src/main.ts
set EXITCODE=%ERRORLEVEL%
popd

if not "%EXITCODE%"=="0" (
  echo.
  echo [X] The relay exited with code %EXITCODE%.
  echo     Troubleshooting:
  echo       - Port 8787 already in use? Set SECRETPLAY_PORT=8788 in local_server\.env
  echo       - Node.js 22.18+ required, found:
  node --version
  echo       - Run scripts\install-local.bat again if node_modules is incomplete.
  echo       - Nothing in offline mode needs Internet; a failure here is local.
  pause
)
endlocal
