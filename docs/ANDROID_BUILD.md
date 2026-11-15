# Android build

## Toolchain used by the APK workflow

| Component | Version / requirement | Why |
|---|---|---|
| Flutter | 3.50.0 stable | Pinned CI toolchain; ships stable Dart 3.14.x |
| Dart | 3.14.x stable (from Flutter 3.50.0) | Satisfies the `^3.10.0` SDK constraint without pre-release resolution |
| JDK | 17 | Compatible Android Gradle / Kotlin toolchain |
| Android SDK | Platform 36, Build Tools 36.0.0 | Project `compileSdk` / `targetSdk` |
| Android NDK | 28.2.13676358 (CI) | Native Rust/vodozemac build |
| Rust | Stable, Android targets installed | `flutter_vodozemac` native build |
| Android Gradle Plugin | 8.11.1 | Existing project plugin line; kept below AGP 9 while dependencies are not migrated to built-in Kotlin |
| Kotlin Gradle Plugin | 2.2.20 | Existing Android app plugin configuration |
| Gradle | 8.14.3 | Compatible with AGP 8.11.1 |

Flutter 3.50.0 is the stable SDK pinned by CI. The application intentionally keeps
its existing AGP 8.11.1 / Kotlin 2.2.20 setup rather than opting into AGP 9,
because the app and every native plugin must be verified for AGP 9 / built-in
Kotlin compatibility before that migration. Keep the workflow and Gradle files aligned.

## Rust targets

Run in an elevated or normal terminal after installing rustup:

```bat
rustup target add aarch64-linux-android armv7-linux-androideabi i686-linux-android x86_64-linux-android
```

The native vodozemac plugin is built through its Rust/cargokit integration. The
GitHub workflow installs the Android Rust targets but disables the Rust cache
action because the repository has no root Cargo.toml for `cargo metadata` to
inspect. A Flutter dependency resolution alone does not prove the native
Android library was built successfully.

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

## GitHub APK build

GitHub Actions builds only one debug APK and uploads it as the `SecretPlay-Android-APK` artifact. It runs on pushes to `main` and manual dispatch. The workflow does not run Node/TypeScript backend checks, Wrangler, Cloudflare deployment, local server tasks, signing, or GitHub Release publishing. Rust is installed only because the Flutter Vodozemac plugin compiles native Android code through Cargokit; Rust dependency caching is disabled because this repository has no root Cargo.toml. See [GITHUB_SETUP.md](GITHUB_SETUP.md).

The APK is debug-signed and suitable for testing. Runner-generated debug certificates can differ between builds, so an older installation may need to be uninstalled before installing a new APK.

## What remains unverified in this delivery environment

The current authoring environment does not have Flutter, Dart, Android SDK,
Rust, Gradle or Windows PowerShell. Therefore no local APK has been generated,
Flutter analyzer/test execution is not claimed, and the BAT/PowerShell scripts
have not been executed on Windows. GitHub Actions must perform the first clean
CI build after the repository is pushed. Physical-device voice, pairing,
biometrics and offline LAN tests remain mandatory before sensitive use.
