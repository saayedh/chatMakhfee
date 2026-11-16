# Android build

## Pinned toolchain

| Component | Version / requirement | Why |
|---|---|---|
| Flutter | 3.50.0 stable (CI) | Stable SDK pinned by GitHub Actions |
| Dart | 3.14.x stable (CI) | Ships with Flutter 3.50.0 and satisfies `sdk: ^3.10.0` |
| JDK | 17 | Required by the Android Gradle toolchain |
| Android SDK | Platform 36, Build Tools 36.0.0 | Matches the app's `compileSdk` / `targetSdk` |
| Android NDK | 28.2.13676358 | Installed for the native Vodozemac/Cargokit build |
| Android Gradle Plugin | 9.3.1 | Meets Flutter 3.50's AGP minimum and matches its current Android template |
| Gradle | 9.5.0 | Matches the Flutter 3.50 Android toolchain baseline and AGP 9.3.1 |
| Kotlin Gradle Plugin | 2.4.20 | Fully compatible with Gradle 9.5.0 and AGP 9.3.1 |

The project uses AGP 9.3.1 with Kotlin Gradle Plugin 2.4.20. The app module
configures Android through the public `ApplicationExtension` DSL and Kotlin
through the typed `kotlin.compilerOptions` DSL. Temporary flags
`android.builtInKotlin=false` and `android.newDsl=false` remain in
`android_app/android/gradle.properties` to retain compatibility with Flutter
and native plugins that may still depend on the legacy plugin mode.

The app build script avoids the deprecated AGP/Kotlin APIs that caused the
first AGP 9 compile-script failure: it uses `ApplicationExtension` instead of
the legacy `android { }` accessor, `compilerOptions` instead of
`kotlinOptions`, and `androidResources.localeFilters` instead of
`resourceConfigurations`.

Keep the temporary compatibility flags until every Android plugin resolved by
this app has been verified with AGP built-in Kotlin and the new DSL.

## Rust targets

Run in an elevated or normal terminal after installing rustup:

```bat
rustup target add aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android
```

The native Vodozemac plugin is built through its Rust/Cargokit integration.
The GitHub workflow installs the Android Rust targets but disables the Rust
cache action because the repository has no root `Cargo.toml` for `cargo
metadata` to inspect. A Flutter dependency resolution alone does not prove
that the native Android library was built successfully.

## Generate the Gradle Wrapper

The source archive includes the pinned `gradle-wrapper.properties` and
bootstrap scripts. The wrapper launchers and JAR are generated from the
official Gradle 9.5.0 distribution. Both the distribution ZIP and generated
wrapper JAR are checked against their official SHA-256 values before use.

On Windows, run:

```bat
scripts\ensure-gradle-wrapper.bat
```

The helper downloads Gradle 9.5.0, verifies the official distribution checksum,
generates `gradlew`, `gradlew.bat`, and `gradle-wrapper.jar` in a temporary
minimal project, copies them into `android_app\android`, and pins the wrapper
properties. It does not need to resolve the app's Flutter/Android plugins just
to generate the wrapper.

The GitHub Actions workflow runs the equivalent Bash helper,
`scripts/ensure-gradle-wrapper.sh`, **before** invoking the Flutter APK build.

## Debug build

```bat
scripts\build-android.bat
```

The script runs dependency resolution, creates/verifies the Gradle wrapper,
Flutter analyzer and tests, then builds:

`android_app\build\app\outputs\flutter-apk\app-debug.apk`

A debug APK is signed with Android's debug key and is only for development.
Do not distribute it as a production release.

## GitHub APK build

GitHub Actions builds one debug APK and uploads it as the
`SecretPlay-Android-APK` artifact. It runs on pushes to `main` and manual
dispatch. The workflow installs JDK 17, Android SDK 36 / Build Tools 36.0.0 /
NDK 28.2.13676358, Flutter 3.50.0 stable, and Rust Android targets needed by
the native Vodozemac build. It disables optional Rust caching because this
repository has no root `Cargo.toml`.

The workflow resolves Flutter dependencies, generates and verifies the
Gradle 9.5.0 wrapper, runs `flutter build apk --debug`, and uploads
`android_app/build/app/outputs/flutter-apk/app-debug.apk`. It does not run
Node/TypeScript backend checks, Wrangler, Cloudflare deployment, local server
tasks, signing, or GitHub Release publishing. See `GITHUB_SETUP.md`.

## Verification limits

The source-editing environment used for this update does not have Flutter,
Dart, Android SDK, Rust, or Gradle installed. Therefore a full Flutter APK
build, Dart analyzer run, Flutter tests, and Windows PowerShell execution
cannot be claimed from this environment. The updated workflow and build
configuration can be statically checked here; the first real APK build must
be confirmed by the GitHub Actions run after the changes are pushed.

Physical-device voice, pairing, biometrics, and offline LAN tests remain
mandatory before using the app for sensitive communication.
