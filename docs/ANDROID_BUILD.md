# Android build and signing

## Toolchain pinned by CI

| Component | Version / requirement | Why |
|---|---|---|
| Flutter | 3.38.0 | Project Dart SDK constraint and pinned CI toolchain |
| Dart | 3.10.x | Required by `pubspec.yaml` |
| Node.js | 22.18.0 | Minimum runtime for TypeScript tests and tooling |
| JDK | 17 | Compatible Android Gradle / Kotlin toolchain |
| Android SDK | Platform 36, Build Tools 36.0.0 | Project `compileSdk` / `targetSdk` |
| Android NDK | 28.2.13676358 (CI) | Native Rust/vodozemac build |
| Rust | Stable | `flutter_vodozemac` native build |
| Android Gradle Plugin | 8.11.1 | Flutter 3.38 supported Android toolchain |
| Kotlin Gradle Plugin | 2.2.20 | Flutter 3.38 supported Android toolchain |
| Gradle | 8.14.3 | Compatible with AGP 8.11.1 |

Flutter's 3.38-era Android compatibility matrix should be checked before
changing these values. Keep the versions in the workflow and Gradle files aligned.

## Rust targets

Run in an elevated or normal terminal after installing rustup:

```bat
rustup target add aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android
```

The native vodozemac plugin is built through its Rust/cargokit integration. A
Flutter dependency resolution alone does not prove the native Android library
was built successfully.

## Generate the Gradle Wrapper

The source archive includes the pinned `gradle-wrapper.properties` and a
bootstrapper. The Gradle wrapper JAR and launchers are generated from the
official Gradle distribution on the target machine, then the distribution
checksum is pinned.

Run after installing Flutter, JDK and Android SDK:

```bat
scripts\ensure-gradle-wrapper.bat
```

The helper downloads Gradle 8.14.3 and verifies the official SHA-256 before
using it to generate `gradlew`, `gradlew.bat`, and `gradle-wrapper.jar`. The
expected distribution checksum is also committed in
`android_app\android\gradle\wrapper\gradle-wrapper.properties`.

## Debug build

```bat
scripts\build-android.bat
```

The script runs dependency resolution, creates/verifies the Gradle wrapper,
Flutter analyzer and tests, then builds:

`android_app\build\app\outputs\flutter-apk\app-debug.apk`

A debug APK is signed with Android's debug key and is only for development.
Do not distribute it as a production release.

## Signed release build

The release build intentionally refuses to fall back to the debug signing key.
Set these environment variables locally, or configure the matching GitHub
Actions Secrets:

- `SECRETPLAY_UPLOAD_KEYSTORE`
- `SECRETPLAY_STORE_PASSWORD`
- `SECRETPLAY_KEY_ALIAS`
- `SECRETPLAY_KEY_PASSWORD`

The keystore must be a JKS file. Do not commit the keystore or `key.properties`.
For GitHub secret configuration, use `scripts\setup-android-signing.bat` and
follow `GITHUB_SETUP.md`.

When all values are set, run from `android_app`:

```bat
flutter build apk --release
```

The result is:

`android_app\build\app\outputs\flutter-apk\app-release.apk`

## GitHub Actions

`.github/workflows/android-apk.yml` builds a debug APK on pushes to `main`, pull
requests to `main`, and manual runs. Pushing a tag such as `v1.0.0` triggers the
signed release workflow, provided all four Android signing secrets are set.
See [GITHUB_SETUP.md](GITHUB_SETUP.md).

## What remains unverified in this delivery environment

The current authoring environment does not have Flutter, Dart, Android SDK,
Rust, Gradle or Windows PowerShell. Therefore no local APK has been generated,
Flutter analyzer/test execution is not claimed, and the BAT/PowerShell scripts
have not been executed on Windows. GitHub Actions must perform the first clean
CI build after the repository is pushed. Physical-device voice, pairing,
biometrics and offline LAN tests remain mandatory before sensitive use.
