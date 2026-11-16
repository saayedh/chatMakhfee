# SecretPlay — Android APK CI build report

**Repository:** https://github.com/saayedh/chatMakhfee  
**Workflow:** `.github/workflows/android-apk.yml`  
**Workflow responsibility:** build one Android debug APK and upload it as a GitHub Actions artifact.

## Pinned Android build toolchain

- Flutter 3.50.0 stable / Dart 3.14.x stable
- JDK 17
- Android SDK Platform 36 / Build Tools 36.0.0
- Android NDK 28.2.13676358
- Android Gradle Plugin 9.3.1
- Gradle 9.5.0
- Kotlin Gradle Plugin 2.4.20

The project keeps `android.builtInKotlin=false` and `android.newDsl=false`
until every Android dependency has been confirmed to support AGP built-in
Kotlin and the new DSL. This is the Flutter-documented compatibility route
for AGP 9 projects that still apply the Kotlin Gradle Plugin.

## Workflow behavior

- Runs on pushes to `main` and manual `workflow_dispatch` only.
- Installs JDK 17, Android SDK 36 / Build Tools 36.0.0 / NDK 28.2.13676358,
  Flutter 3.50.0 stable, and Rust Android targets required by the native
  Vodozemac/Cargokit build.
- Verifies that the installed Dart SDK is stable Dart 3.14.x.
- Runs `flutter pub get`.
- Generates the Gradle 9.5.0 wrapper **before** the Android build. The
  bootstrap helper verifies the official Gradle distribution SHA-256 and the
  official wrapper JAR SHA-256.
- Runs `flutter build apk --debug`.
- Uploads `android_app/build/app/outputs/flutter-apk/app-debug.apk` as
  `SecretPlay-Android-APK` with 30-day retention.

The Rust cache is explicitly disabled because the repository has no root
`Cargo.toml`; Rust and the Android targets remain installed.

## Fixes included for the reported CI failure

1. Upgraded AGP from 8.11.1 to 9.3.1 to satisfy Flutter 3.50's AGP minimum.
2. Upgraded Gradle from 9.3.1 to 9.5.0 to match the current Flutter/AGP
   toolchain and remove the Gradle compatibility warning.
3. Upgraded KGP from 2.2.20 to 2.4.20, whose published compatibility range
   includes AGP 9.3.1 and Gradle 9.5.0.
4. Added the Flutter-documented legacy compatibility flags for KGP and the
   old AGP DSL while third-party plugins are still being migrated.
5. Updated both Windows and CI Gradle wrapper bootstrappers to use a
   temporary minimal project and verify checksums.
6. Moved wrapper generation in GitHub Actions to occur before
   `flutter build apk`; removed the old empty step that was after artifact
   upload.
7. Raised the declared minimum Flutter SDK from 3.38.0 to 3.44.0, the first
   stable line with AGP 9 legacy-KGP compatibility support.

## Static checks actually run on this source update

- Parsed the GitHub Actions workflow as YAML.
- Parsed every embedded Bash run block with `bash -n`.
- Parsed the Gradle wrapper bootstrap script with `bash -n`.
- Confirmed wrapper generation and wrapper verification occur before
  `flutter build apk`, and artifact upload occurs only after the build step.
- Checked that the AGP, Gradle, KGP, Flutter, and minimum Flutter SDK versions
  agree across the project configuration, workflow, helper scripts, and docs.
- Checked that both wrapper bootstrap scripts use the official Gradle 9.5.0
  distribution SHA-256 and official Gradle 9.5.0 wrapper JAR SHA-256.
- Confirmed the workflow trigger remains push to `main` plus manual dispatch,
  and the artifact output path matches the Flutter APK output path.

## Not yet verified

The editing environment does not have Flutter, Dart, Android SDK, Rust,
Gradle, or Windows PowerShell installed. Therefore no local APK build,
`flutter analyze`, Flutter test run, or PowerShell execution is claimed.
The only valid confirmation of a successful APK build will be a green
GitHub Actions run after the update is pushed to `main`.

The output is a debug-signed APK for testing. A successful build does not
constitute a mobile security audit or prove that messaging, voice calls,
pairing, biometrics, or offline LAN behavior passed real-device tests.
