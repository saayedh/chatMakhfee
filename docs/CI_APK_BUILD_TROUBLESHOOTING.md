# GitHub Actions Android APK build troubleshooting

This repository uses GitHub Actions only to build and upload the Android debug
APK. It does not deploy Cloudflare, run the laptop server, run backend
workflows, or publish GitHub Releases.

## Android Gradle Plugin / Gradle compatibility

Flutter 3.50 requires Android Gradle Plugin (AGP) 9.1.1 or later. The previous
project settings used AGP 8.11.1 and Gradle 9.3.1, so Flutter stopped while
applying `dev.flutter.flutter-gradle-plugin`, before Android sources compiled.

The project is now pinned to a mutually compatible toolchain:

- Android Gradle Plugin: `9.3.1`
- Gradle wrapper: `9.5.0`
- Kotlin Gradle Plugin: `2.4.20`
- Java: `17`

Kotlin 2.2.20 is not fully compatible with AGP 9.3.1 / Gradle 9.5.0, so the
Kotlin plugin version was upgraded too. Since not every third-party Android
plugin has been verified for AGP's built-in Kotlin migration, the project
explicitly sets `android.builtInKotlin=false` and `android.newDsl=false` in
`android_app/android/gradle.properties`. These preserve the legacy KGP / DSL
compatibility path while still using AGP 9.

Do not bypass dependency validation with
`--android-skip-build-dependency-validation`; the project should use a
supported toolchain instead.

## Gradle Wrapper bootstrap

The source package intentionally does not require a pre-generated Gradle
wrapper binary. Before building, CI runs `scripts/ensure-gradle-wrapper.sh`.
The helper:

1. Downloads the official Gradle 9.5.0 binary distribution.
2. Checks its SHA-256 against the value published by Gradle.
3. Generates the wrapper in a temporary minimal project.
4. Checks the generated wrapper JAR SHA-256.
5. Places the wrapper files in `android_app/android` with
   `distributionSha256Sum` pinned.

The Windows helper `scripts/ensure-gradle-wrapper.ps1` follows the same
process. The wrapper step runs **before** `flutter build apk`.

## Rust cache error: missing Cargo.toml at repository root

The `flutter_vodozemac` dependency compiles Rust through Cargokit, but this
repository is not a Cargo workspace and has no root `Cargo.toml`. The
`actions-rust-lang/setup-rust-toolchain` action therefore sets `cache: false`.
Rust and the Android targets are still installed; only the optional Cargo
cache is disabled.

## Dart prerelease mismatch

A previous CI run used a Flutter 3.38 build that supplied a Dart 3.10
pre-release (`3.10.0-290.4.beta`). A pre-release SDK does not satisfy the
project's stable `sdk: ^3.10.0` constraint. The workflow now pins Flutter
3.50.0 stable, which ships stable Dart 3.14, and checks the SDK version before
running `flutter pub get`.

## What to do after applying this fix

1. Apply the updated source files to the existing `saayedh/chatMakhfee`
   repository without deleting its `.git` directory.
2. Commit and push the changes to `main`.
3. Open the repository's Actions tab and inspect the new
   `Build SecretPlay Android APK` run.
4. Download `SecretPlay-Android-APK` only after the run completes successfully.

If a later step fails, diagnose the first actual build error in the log. A
warning about a deprecated Node module is not by itself an APK build failure.
