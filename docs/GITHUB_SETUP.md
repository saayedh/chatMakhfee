# GitHub Actions: build and download the Android APK

The only responsibility of GitHub Actions in this project is to build the Android APK and upload it as a downloadable workflow artifact.

**Repository:** https://github.com/saayedh/chatMakhfee  
**Workflow:** `.github/workflows/android-apk.yml`  
**Artifact:** `SecretPlay-Android-APK`

GitHub Actions does not deploy Cloudflare Workers, create Durable Objects, configure Cloudflare secrets, start the laptop server, deploy TURN, or publish GitHub Releases. Those tasks remain manual and are performed from your laptop using the project's local scripts and documentation.

## 1. What runs on GitHub

The workflow runs only for:

- a push to the `main` branch;
- a manual `workflow_dispatch` run from the Actions tab.

The single job performs only the steps required to produce an Android debug APK:

1. check out the repository;
2. install Java 17 and the Android SDK packages used by this project;
3. install Flutter 3.38.0;
4. install Rust and Android compilation targets needed by `flutter_vodozemac`;
5. resolve Flutter dependencies;
6. generate the Gradle wrapper from the checksum-pinned Gradle distribution;
7. run `flutter build apk --debug`;
8. upload `SecretPlay-Android.apk` as the `SecretPlay-Android-APK` artifact.

There are no backend test jobs, TypeScript checks, Wrangler commands, Cloudflare deployments, signing secrets, tag-based releases, or GitHub Release creation in the workflow.

## 2. Push source to the configured private repository

Install Git for Windows and GitHub CLI (`gh`), then authenticate:

```powershell
gh auth login --hostname github.com --git-protocol https --web
gh auth status
```

From the extracted project folder, run:

```bat
scripts\github-push.bat
```

The helper is configured for `saayedh/chatMakhfee`. If no `origin` exists, it adds:

```text
https://github.com/saayedh/chatMakhfee.git
```

It refuses to push to a different or public repository, scans staged files for common secret material, shows the staged summary, configures a repository-local Git author identity if needed, and asks before committing and pushing to `main`.

Repository URL: https://github.com/saayedh/chatMakhfee
Actions page: https://github.com/saayedh/chatMakhfee/actions

## 3. Download the APK from GitHub

After a successful run, download it from the website:

1. Open the repository's **Actions** tab.
2. Open the successful **Build SecretPlay Android APK** run.
3. Find the **Artifacts** section at the bottom.
4. Download `SecretPlay-Android-APK`.
5. Extract the artifact ZIP; it contains `SecretPlay-Android.apk`.

Or run this helper from the project folder:

```bat
scripts\github-build-download.bat
```

To wait for a successful run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\github-build-download.ps1 -Wait
```

The helper downloads the artifact from the configured repository, checks that an APK exists and is non-empty, and copies it to:

```text
artifacts\github-apk\SecretPlay-Android.apk
```

## 4. Important APK limitation

The workflow intentionally builds a **debug APK** because no release-signing keystore is stored in the repository or GitHub Actions. The APK can be installed for testing, but it is not a production-signed release. A new GitHub-hosted runner can generate a different debug certificate, so Android may require uninstalling the previous debug build before installing a later build. Back up any local test data first; the app's session-only design should not retain chat history.

## 5. Tasks that stay on your laptop

These operations are deliberately outside GitHub Actions:

```bat
scripts\deploy-cloudflare.bat
scripts\install-local.bat
scripts\run-local.bat
scripts\stop-local.bat
scripts\package-project.bat
```

Cloudflare deployment, Worker secrets, Durable Object configuration, local laptop relay setup, Windows Firewall, local TURN and other backend operations remain under your control on your own machine.

## 6. Troubleshooting

- If no run starts, confirm the push went to `main` and that Actions are enabled for the repository.
- If the workflow fails during Flutter dependency resolution, inspect the Flutter/pub error in the Actions log.
- If Rust compilation fails, inspect the `flutter_vodozemac`/Cargokit output and Android NDK setup.
- If Gradle fails, inspect wrapper generation, Java 17, Android Gradle Plugin compatibility and the pinned distribution checksum.
- A green APK workflow means the APK build completed. It does not mean Cloudflare is deployed, the laptop server is configured, WebRTC has been tested on two phones, or the app has passed an independent security audit.
