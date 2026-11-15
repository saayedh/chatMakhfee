# SecretPlay — APK-only GitHub Actions build report

**Repository:** https://github.com/saayedh/chatMakhfee  
**Workflow:** `.github/workflows/android-apk.yml`  
**Workflow responsibility:** build one Android debug APK and upload it as a GitHub Actions artifact.

## Current workflow behavior

- Runs on pushes to `main` and manual `workflow_dispatch` only.
- Installs JDK 17, Android SDK 36 / Build Tools 36.0.0 / NDK 28.2.13676358, Flutter 3.50.0 stable, and Rust Android targets required by the native Vodozemac/Cargokit build.
- Verifies the installed Dart SDK is stable Dart 3.14.x before dependency resolution.
- Disables the optional Rust cache action because this repository has no root `Cargo.toml`; that prevents the cache action from running `cargo metadata` at the repository root. Rust itself and the Android targets remain installed.
- Runs `flutter pub get`, generates the checksum-pinned Gradle 8.14.3 wrapper on the runner, builds `flutter build apk --debug`, and uploads `artifacts/SecretPlay-Android.apk`.
- Uploads the artifact as `SecretPlay-Android-APK` with 30-day retention.

## Fixes for the reported CI errors

### Rust cache / missing Cargo.toml

The earlier setup action enabled `Swatinem/rust-cache`. Its metadata scan ran `cargo metadata --all-features --format-version 1 --no-deps` at the repository root, where there is no `Cargo.toml`. The current workflow sets `cache: false`. This disables only optional Rust caching; it does not remove Rust or the Android Rust targets needed to compile Vodozemac.

### Dart pre-release / dependency solver

The reported runner supplied `Dart 3.10.0-290.4.beta`, which does not satisfy the project's stable `sdk: ^3.10.0` constraint. The current workflow pins Flutter 3.50.0 stable, whose release includes stable Dart 3.14, and checks that `dart --version` reports `3.14.x (stable)` before `flutter pub get`.

## Scope exclusions

The workflow does not:

- deploy Cloudflare Workers or configure Durable Objects;
- run Wrangler;
- install or start the laptop local server;
- run TypeScript/backend test suites;
- create GitHub Releases;
- access Cloudflare secrets or Android signing secrets.

Those operations remain on the user's laptop, as requested.

## Static validation performed for this update

- Parsed `.github/workflows/android-apk.yml` as YAML.
- Confirmed exactly one job (`build-apk`).
- Confirmed triggers are only push to `main` and manual dispatch.
- Confirmed Flutter is pinned to `3.50.0` and the Dart guard requires stable `3.14.x`.
- Confirmed Rust caching is explicitly disabled and warning flags are not forced on third-party Rust dependencies.
- Confirmed artifact name/path agree with the download helper.
- Confirmed there are no Wrangler, Cloudflare deployment, npm/backend test, or release-publishing commands in the workflow.
- Checked the shell syntax of embedded Bash steps.

## Not yet verified

This authoring environment does not have Flutter, Dart, Android SDK, Rust, or Gradle installed, and this environment has not pushed to the user's GitHub repository. Therefore no APK build or real GitHub Actions run is claimed. The next verification is to commit and push this workflow, then inspect the new Actions run. If it fails again, the first actual build error (not non-fatal Node deprecation warnings) should be used for the next fix.

The output is a debug-signed APK for testing. A successful build does not constitute a mobile security audit or prove that messaging, voice calls, pairing, biometrics, or offline LAN behavior passed real-device tests.
