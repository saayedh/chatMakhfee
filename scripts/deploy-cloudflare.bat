@echo off
setlocal EnableExtensions
title SecretPlay - deploy Cloudflare Worker

echo ============================================================
echo   SecretPlay - deploy the Cloudflare relay
echo ============================================================
echo.
echo   This deploys a Worker plus a SQLite-backed Durable Object.
echo   It never asks for, prints or stores an API token: authentication
echo   is your existing `wrangler login`, or CLOUDFLARE_API_TOKEN already
echo   set in this shell by you.
echo.

where node >nul 2>nul
if errorlevel 1 (
  echo [X] Node.js was not found on PATH. Install Node.js 22.18 LTS+.
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

pushd "%~dp0..\crypto_core"
if errorlevel 1 (
  echo [X] Cannot find the crypto_core folder next to scripts\.
  pause
  exit /b 1
)
echo [i] Installing shared cryptography dependencies...
call npm ci --no-audit --no-fund
if errorlevel 1 (
  echo [X] Shared crypto_core dependency installation failed.
  popd
  pause
  exit /b 1
)
popd

pushd "%~dp0..\cloudflare"
if errorlevel 1 (
  echo [X] Cannot find the cloudflare folder next to scripts\.
  pause
  exit /b 1
)

if not exist "node_modules\wrangler" (
  echo [i] Installing pinned dev dependencies...
  call npm ci --no-audit --no-fund
  if errorlevel 1 (
    echo [X] npm ci failed. Check your connection and retry.
    popd
    pause
    exit /b 1
  )
)

echo.
echo [i] Checking Cloudflare authentication (wrangler whoami)...
call npx wrangler whoami
if errorlevel 1 (
  echo.
  echo [!] Not authenticated. Run:  npx wrangler login
  echo     from the cloudflare folder, then run this script again.
  popd
  pause
  exit /b 1
)

echo.
echo [i] Type checking...
call npm run typecheck
if errorlevel 1 (
  echo [X] Type check failed. Fix the errors above before deploying.
  popd
  pause
  exit /b 1
)

echo.
echo [i] Running the relay test suite...
call npm test
if errorlevel 1 (
  echo [X] Tests failed. Not deploying.
  popd
  pause
  exit /b 1
)

echo.
echo [i] Bundling dry run (no upload) to catch Workers-incompatible code...
call npx wrangler deploy --dry-run --outdir=.wrangler\dry-run
if errorlevel 1 (
  echo [X] The Worker does not bundle for the Workers runtime. Not deploying.
  popd
  pause
  exit /b 1
)

echo.
echo [i] Deploying...
call npx wrangler deploy
if errorlevel 1 (
  echo [X] Deployment failed. See the error above.
  popd
  pause
  exit /b 1
)

echo.
echo ============================================================
echo   Deployed.
echo   Put the printed https://secretplay.YOUR-SUBDOMAIN.workers.dev
echo   URL into the app under Network and pairing -^> Cloud.
echo.
echo   Free plan notes:
echo     - SQLite Durable Objects only; no paid bindings created.
echo     - TURN stays DISABLED unless you set TURN_ENABLED=true AND the
echo       TURN_KEY_ID / TURN_KEY_API_TOKEN secrets. TURN bills per GB.
echo     - Optional TURN secrets:  npx wrangler secret put TURN_KEY_ID
echo                               npx wrangler secret put TURN_KEY_API_TOKEN
echo ============================================================
popd
pause
endlocal
