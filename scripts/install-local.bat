@echo off
setlocal EnableExtensions
title SecretPlay - install local server

echo ============================================================
echo   SecretPlay - local relay dependency install
echo ============================================================
echo.
echo   Run this ONCE while this laptop has Internet access.
echo   After it succeeds, run-local.bat works fully offline.
echo.

where node >nul 2>nul
if errorlevel 1 (
  echo [X] Node.js was not found on PATH.
  echo     Install Node.js 22.18 LTS or newer from https://nodejs.org
  echo     Then close this window and run this script again.
  pause
  exit /b 1
)

for /f "delims=" %%v in ('node -p "process.versions.node"') do set NODE_VERSION=%%v
echo [i] Node.js %NODE_VERSION% found.
node -e "const [a,b]=process.versions.node.split('.').map(Number); process.exit(a>22 || (a===22 && b>=18) ? 0 : 1)"
if errorlevel 1 (
  echo [X] Node.js 22.18.0 or newer is required. Found %NODE_VERSION%.
  pause
  exit /b 1
)

where npm >nul 2>nul
if errorlevel 1 (
  echo [X] npm was not found. Reinstall Node.js with npm included.
  pause
  exit /b 1
)

pushd "%~dp0..\crypto_core"
if errorlevel 1 (
  echo [X] Cannot find the crypto_core folder next to scripts\.
  pause
  exit /b 1
)
echo.
echo [i] Installing shared cryptography dependencies...
call npm ci --no-audit --no-fund
if errorlevel 1 (
  echo [X] Shared crypto_core dependency installation failed.
  popd
  pause
  exit /b 1
)
popd

pushd "%~dp0..\local_server"
if errorlevel 1 (
  echo [X] Cannot find the local_server folder next to scripts\.
  pause
  exit /b 1
)

if not exist ".env" (
  if exist ".env.example" (
    copy /y ".env.example" ".env" >nul
    echo [i] Created local_server\.env from .env.example
  )
)

echo.
echo [i] Installing dependencies (needs Internet for this step only)...
if exist "package-lock.json" (
  call npm ci --no-audit --no-fund
) else (
  call npm install --no-audit --no-fund
)
if errorlevel 1 (
  echo.
  echo [X] Dependency install failed. Check the error above and your connection.
  popd
  pause
  exit /b 1
)

echo.
echo [i] Running the relay test suite...
call npm test
if errorlevel 1 (
  echo.
  echo [!] Tests failed. The server may still start, but do not trust it until this is fixed.
) else (
  echo [OK] Relay tests passed.
)

popd
echo.
echo ============================================================
echo   Installed. Shared crypto and local relay dependencies are ready.
  echo   No further Internet access is required for Local Mode.
echo   Next: run scripts\run-local.bat
echo ============================================================
pause
endlocal
