SECRETPLAY — APPLY THE ANDROID APK BUILD FIX

Target repository:
https://github.com/saayedh/chatMakhfee

This archive is a full source overlay containing the Android build configuration,
Gradle wrapper bootstrap scripts, GitHub Actions workflow, and matching build
documentation. The APK fix changes more than the workflow file, so do not use
the old workflow-only publishing procedure.

APPLY THE FILES
1. Make a backup of your local repository folder.
2. Extract the contents of this ZIP directly into the existing repository root.
   The destination folder must already contain `.git` and `android_app/pubspec.yaml`.
   Allow files to be overwritten. Do not delete, replace, or extract over `.git`.
3. Open a terminal in that repository root and run:
   `git status --short`
4. Review the changed files. Confirm that the changes are limited to the Android
   build configuration, wrapper bootstrap, CI workflow, and related documentation.

PUSH TO THE EXISTING MAIN BRANCH
1. Ensure Git for Windows and GitHub CLI (`gh`) are installed.
2. Authenticate with GitHub if needed:
   `gh auth login --hostname github.com --git-protocol https --web`
3. Check that `gh auth status` shows the intended account and that the
   repository `saayedh/chatMakhfee` is accessible with write permission.
4. Run:
   `scripts\github-push.bat`
5. Review the complete staged summary carefully. Confirm only after you are
   satisfied. The helper is configured to push to the existing
   `saayedh/chatMakhfee` repository and the `main` branch.
6. Open:
   https://github.com/saayedh/chatMakhfee/actions

SAFETY
- The helper does not create a new repository.
- It checks the configured origin and the target repository before pushing.
- It refuses to push to a different repository.
- It scans staged files for common secret material and asks for confirmation.
- It does not deploy Cloudflare, run Wrangler, or publish a GitHub Release.
- It does not store GitHub tokens in source files.

IMPORTANT
The ZIP does not contain an APK. GitHub Actions builds the debug APK only
after the updated source has been pushed successfully to `main`. A successful
local source-file check is not proof that the remote APK build has passed;
confirm the green GitHub Actions run and download the artifact from that run.
