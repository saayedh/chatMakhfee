# SecretPlay final build and delivery report

**Report date:** 2026-11-14  
**Delivery type:** source package with GitHub Actions and Windows automation  
**Release status:** source/CI prepared; no GitHub run or APK produced in this environment

## Deliverables added or updated

- `.github/workflows/android-apk.yml`
  - Backend test/typecheck matrix for `crypto_core`, `local_server`, `cloudflare`,
    and `voice_harness`.
  - Flutter analysis and test job.
  - Android debug APK build and artifact upload on `main`, pull requests, and
    manual dispatch.
  - Signed APK release job on `v*` tags, with tag ancestry verification,
    four required Actions Secrets, APK signature verification, SHA-256, and
    GitHub Release assets.
- Gradle 8.14.3 distribution checksum pin and Windows bootstrap scripts for
  generating the Gradle wrapper on a machine with the required toolchain.
- Windows scripts for private GitHub repository setup/push, secret scanning,
  downloading and checksum-verifying a successful CI artifact, signing-key
  creation and Actions Secret configuration, release tagging, local APK build,
  and source ZIP packaging.
- Git ignore and package exclusions for environment files, npm credentials,
  certificates/private keys, signing material, build caches, local settings,
  and downloaded artifacts by default.
- GitHub setup, Android build, remediation plan, and final build documentation.
- Removed unused top-level WebRTC probe scripts; actual tests under
  `voice_harness/tests/` remain.

## Static verification performed

| Check | Result | Scope |
|---|---|---|
| GitHub Actions YAML parse | Passed | Parsed with PyYAML `BaseLoader`; all three jobs and event triggers found |
| JSON manifests/configs | Passed | 11 JSON files parsed |
| Android XML | Passed | 9 XML files parsed |
| TypeScript syntax parse | Passed | 38 `.ts` files parsed with Node's experimental TypeScript strip syntax check |
| Gradle wrapper distribution pin | Passed | Wrapper properties reference Gradle 8.14.3 and include a 64-character SHA-256 |
| Workflow permission structure | Passed | Empty global permissions; release write permission is job-scoped |
| Automation file presence | Passed | Required BAT/PowerShell files exist |
| Final ZIP integrity | Verified during packaging | Every archive entry was read and CRC validation completed |

The TypeScript operation above was a syntax parse only. It was not a typecheck,
unit-test run, dependency install, or runtime integration test.

## Not run: environment and authorization limits

The authoring container has Node.js `22.16.0`, below the project's required
`22.18.0`. It has Git and Java 21, but does not have Flutter, Dart, Rust/Cargo,
Gradle, Android SDK, Windows PowerShell, Docker Desktop, or GitHub CLI
authentication. Network package installation was unavailable.

Therefore this delivery does **not** claim success for:

- `npm ci`, backend test suites, TypeScript typechecks, or Wrangler dry-run;
- `flutter pub get`, `flutter analyze`, or `flutter test`;
- Gradle wrapper generation or Android APK compilation;
- APK signature verification;
- execution of Windows BAT/PowerShell scripts;
- Cloudflare deployment;
- GitHub push or GitHub Actions execution;
- GitHub Release creation;
- two-device WebRTC calls, Android audio routing, or offline LAN calls.

The final ZIP and its SHA-256 are provided as separate delivery files.

No APK is included because no APK could be built here. No GitHub repository was
created or modified because no GitHub account/repository was connected or
explicitly authorized for this task.

The first clean build must occur on GitHub Actions after the project is pushed
to a private repository. A failed CI run must be fixed before using the APK.

## Security limitations that remain open

The following remain release blockers for sensitive use:

1. Biometric success is not yet proven to gate access to the Olm identity through
   a per-use, authentication-required Android Keystore key.
2. Local laptop pairing still uses HTTP/WS; TLS certificate pinning has not been
   implemented or tested.
3. Complete WebRTC ICE restart and renegotiation recovery is not implemented
   as a verified path.
4. A local Coturn fallback is not bundled or tested. Client isolation or
   restrictive hotspot topologies may prevent direct peer-to-peer audio.
5. `FLAG_SECURE` is Activity-wide rather than scoped to the private interface.
6. Recovery remains Pair Membership Recovery; it does not restore the previous
   private Olm identity and intentionally does not restore chat history.
7. No two-device Android hardware test has been run.
8. No production Cloudflare Worker deployment has been performed.
9. No independent mobile/cryptographic security audit has been performed.

## First-run procedure on Windows

1. Install the toolchain listed in `docs/ANDROID_BUILD.md` and prerequisites in
   `docs/GITHUB_SETUP.md`.
2. Extract the source ZIP and run `scripts\\github-push.bat`.
3. Authenticate with GitHub CLI in the browser and select creation of a private
   repository (or select an existing private repository).
4. Inspect the first GitHub Actions run. The workflow must pass before the APK
   can be downloaded.
5. Run `scripts\\github-build-download.bat` to download and SHA-256-check the
   debug APK.
6. Only after security and two-device tests, run
   `scripts\\setup-android-signing.bat`, securely back up the upload keystore,
   and use `scripts\\github-release.bat` for a signed release tag.

A green CI build is not a security audit and does not replace testing on both
physical Android devices.
