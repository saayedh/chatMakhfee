@echo off
setlocal EnableExtensions
title SecretPlay - build Android APK

echo ============================================================
echo   SecretPlay - Android build
echo ============================================================
echo.

where flutter >nul 2>nul
if errorlevel 1 (
  echo [X] Flutter was not found on PATH.
  echo     Install Flutter 3.38+ and add its bin folder to PATH, then
  echo     reopen this window. https://docs.flutter.dev/get-started/install/windows
  pause
  exit /b 1
)

echo [i] Flutter:
call flutter --version
echo.
echo [i] Verifying Java and Rust toolchains...
where java >nul 2>nul
if errorlevel 1 echo [!] Java was not found on PATH. JDK 17 is required.
where cargo >nul 2>nul
if errorlevel 1 echo [!] Rust/Cargo was not found on PATH. flutter_vodozemac requires Rust for Android native builds.
echo.

flutter doctor --android-licenses >nul 2>nul
call flutter doctor
if errorlevel 1 (
  echo.
  echo [!] flutter doctor reported problems. Android builds need:
  echo       - Android SDK (platform 36, build-tools) and accepted licences
  echo       - JDK 17
  echo       - Rust toolchain: vodozemac is built from source by cargokit.
  echo         Install from https://rustup.rs and run:
  echo           rustup target add aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android
  echo         Without Rust the APK build fails at the flutter_vodozemac step.
  echo.
)

pushd "%~dp0..\android_app"
if errorlevel 1 (
  echo [X] Cannot find the android_app folder next to scripts\.
  pause
  exit /b 1
)

echo [i] Resolving dependencies...
call flutter pub get
if errorlevel 1 (
  echo [X] flutter pub get failed. Check the pinned versions in pubspec.yaml.
  popd
  pause
  exit /b 1
)

echo.
echo [i] Ensuring a Gradle Wrapper with a pinned distribution checksum...
call "%~dp0ensure-gradle-wrapper.bat"
if errorlevel 1 (
  echo [X] Gradle Wrapper setup failed.
  popd
  pause
  exit /b 1
)

echo.
echo [i] Analysing...
call flutter analyze
if errorlevel 1 (
  echo [X] Analysis failed. Fix the reported issues before building.
  popd
  pause
  exit /b 1
)

echo.
echo [i] Running tests...
call flutter test
if errorlevel 1 (
  echo [X] Tests failed. Not building a broken APK.
  popd
  pause
  exit /b 1
)

echo.
echo [i] Building the debug APK...
call flutter build apk --debug
if errorlevel 1 (
  echo [X] Build failed. See the error above.
  popd
  pause
  exit /b 1
)

set APK=%~dp0..\android_app\build\app\outputs\flutter-apk\app-debug.apk
echo.
echo ============================================================
if exist "%APK%" (
  echo   APK: %APK%
  for %%A in ("%APK%") do echo   Size: %%~zA bytes
  echo.
  echo   Install on a connected phone:
  echo     adb install -r "%APK%"
) else (
  echo   [!] Flutter reported success but the APK was not found at
  echo       %APK%
)
echo ============================================================
popd
pause
endlocal
