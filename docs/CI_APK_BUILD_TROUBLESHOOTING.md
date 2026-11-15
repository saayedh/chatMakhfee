# GitHub Actions APK build: fixes for the first CI run

This repository uses GitHub Actions only to build and upload the Android APK.
It does not deploy Cloudflare, run the laptop server, run backend workflows,
or publish GitHub Releases.

## Rust cache error: missing Cargo.toml at repository root

The Flutter `flutter_vodozemac` dependency compiles Rust through Cargokit, but
this repository is not a Cargo workspace and has no root `Cargo.toml`. The
`actions-rust-lang/setup-rust-toolchain` action previously enabled its
`Swatinem/rust-cache` integration, which tried `cargo metadata` in the repository
root and failed. The workflow now sets `cache: false` and `rustflags: ''`. Rust and the Android
targets are still installed; only the optional Cargo cache is disabled, and the
action does not inject `-D warnings` into third-party crate builds.

## Dart prerelease mismatch

The previous CI run used a Flutter 3.38 build that supplied a Dart 3.10
pre-release (`3.10.0-290.4.beta`). A pre-release SDK does not satisfy the
project's stable `sdk: ^3.10.0` constraint. The workflow now pins Flutter
3.50.0 stable, which ships stable Dart 3.14, and verifies the SDK reports
Dart 3.14.x `(stable)` before running `flutter pub get`.

Flutter 3.50 was announced on 11 November 2026 and ships Dart 3.14:
https://flutter.dev/blog/whats-new-in-flutter-3-50

## What to do after applying this fix

1. Replace `.github/workflows/android-apk.yml` in the GitHub repository.
2. Commit and push the workflow change to `main`.
3. Open the repository's Actions tab and inspect the new `Build SecretPlay Android APK` run.
4. Download `SecretPlay-Android-APK` only after the run completes successfully.

If a later step fails, use the first actual build error in the log; warnings
about Node's deprecated `punycode` module are not the cause of either failure above.
