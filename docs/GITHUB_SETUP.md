# GitHub private repository and Android CI/CD

This project includes GitHub Actions workflows and Windows helper scripts. The
workflow can build a **debug APK** after a push to `main`, and can build a
**signed release APK** when a version tag such as `v1.0.0` is pushed.

A workflow file in a ZIP does not create a GitHub repository or run by itself.
The owner must authenticate GitHub CLI and push the source to a private repo.

## 1. Install prerequisites on Windows

Install:

- Git for Windows
- GitHub CLI (`gh`): https://cli.github.com/
- PowerShell 5.1 or PowerShell 7
- JDK 17 or newer (for upload-keystore setup and local Android builds)
- Flutter 3.38.0 or the exact version pinned in `.github/workflows/android-apk.yml`
- Android SDK 36
- Rust stable and the Android targets described in `ANDROID_BUILD.md`

Close and reopen the terminal after installation. Verify:

```powershell
git --version
gh --version
java -version
flutter --version
cargo --version
```

## 2. Authenticate using the browser

Run:

```powershell
gh auth login --hostname github.com --git-protocol https --web
gh auth status
```

Do not paste a personal access token into source code, a BAT file, chat, or a
committed `.env` file. The GitHub CLI manages its own authentication.

## 3. Create or select a private repository and push

From the extracted project, run:

```bat
scripts\github-push.bat
```

Choose either a new private repository or an existing GitHub repository. The
script refuses to push to a repository whose visibility is not `PRIVATE`. It
stages files, scans staged content for common credentials and private-key
markers, shows the staged summary, and asks before committing and pushing.

Never bypass a secret-scan warning without examining the named file. Remove
credentials from the repository history as well as the working tree if any
secret was previously committed; rotating the exposed credential may also be
necessary.

After a successful push to `main`, open the Actions page printed by the script.
The workflow runs backend checks, Flutter checks, and a debug APK build. The
workflow's green status is the authoritative indication that the CI job passed.

## 4. Download the latest successful debug APK

Run:

```bat
scripts\github-build-download.bat
```

To wait until a successful run appears:

```bat
scripts\github-build-download.bat --wait
```

The helper downloads the `SecretPlay-Android-Debug-APK` artifact from the latest
successful `android-apk.yml` run on `main`, checks its SHA-256 digest against
`SHA256SUMS.txt`, and places the APK under `artifacts\github-debug\`.

A debug APK is for testing. It is not the signed production release.

## 5. Create the Android upload key and configure GitHub Secrets

Run:

```bat
scripts\setup-android-signing.bat
```

The helper creates a JKS upload keystore outside the project, under:

`%USERPROFILE%\.secretplay\signing\secretplay-upload.jks`

It then configures these repository Actions Secrets through GitHub CLI:

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

The GitHub repository must be private. The script never commits or copies the
keystore into the repository. Back up the JKS file and its passwords offline in
at least one secure location. Loss of the upload key can interrupt future APK
updates; do not delete it after configuring GitHub.

Secrets are only sent to GitHub CLI's standard input. The script does not print
their values. Repository secret names can be listed, but GitHub does not reveal
stored secret values.

## 6. Publish a signed version

After all required secrets have been configured and `main` has a green CI run,
run:

```bat
scripts\github-release.bat
```

Enter a semantic version such as `1.0.0`. The helper verifies a clean working
tree, checks that the release tag does not already exist, verifies that the
four signing secrets are configured, runs a local source scan, then creates and
pushes an annotated tag such as `v1.0.0`.

The tag triggers the release job. The job builds a release APK, verifies its
signature with `apksigner`, computes SHA-256, and attaches the APK, checksum,
and build metadata to a GitHub Release. The workflow will fail rather than
silently use Android's public debug key when signing secrets are absent.

Do not force-push a release tag or replace an existing tag. Increment the
version instead.

## 7. Workflow behavior

| Event | Checks | APK result |
|---|---|---|
| Push to `main` | Backend, typecheck, Wrangler dry-run, Flutter analyze/test | Debug APK artifact |
| Pull request to `main` | Same validation and debug build | Debug artifact for the run |
| Manual `workflow_dispatch` | Same validation and debug build | Debug APK artifact |
| Push tag `v*` | Validation, debug build, signed release build | Signed APK + GitHub Release |

The workflow does not deploy Cloudflare. Cloudflare deployment remains a separate
explicit action using `scripts\deploy-cloudflare.bat`.

## 8. Local build and package scripts

```bat
scripts\build-android.bat
scripts\package-project.bat
```

`package-project.bat` creates a source ZIP outside the repository and a SHA-256
file. By default, build outputs and downloaded APKs are excluded. To include an
APK that was downloaded by `github-build-download.bat`, use:

```bat
scripts\package-project.bat --include-apk
```

The packaging script excludes `.git`, dependency caches, `.env` files, signing
keys, certificates/private keys, Android `local.properties`, and local recovery
secrets. Review the generated ZIP manifest and checksum after packaging.

## 9. Security and CI caveats

- A successful CI build means the selected automated checks passed; it is not a
  cryptographic or mobile application security audit.
- CI cannot replace testing on two physical Android devices.
- Debug APKs are not production-signed releases.
- GitHub-hosted runners require Internet access to download Flutter, Android,
  Rust, Node, Gradle and package dependencies.
- Do not expose signing secrets to pull requests from forks. The workflow only
  makes signing secrets available in the tag-triggered release job.
- Protect the `main` branch and require successful checks before merging changes.
- Review workflow changes carefully because a workflow can access repository
  Actions Secrets when explicitly provided.
