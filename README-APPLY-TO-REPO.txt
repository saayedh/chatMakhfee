SECRETPLAY — PUSH APK WORKFLOW TO THE EXACT GITHUB REPOSITORY

Target repository:
https://github.com/saayedh/chatMakhfee

This patch contains:
- .github/workflows/android-apk.yml
- scripts/push-apk-workflow-to-chatMakhfee.bat
- scripts/push-apk-workflow-to-chatMakhfee.ps1

HOW TO APPLY
1. Extract this ZIP directly OVER your existing local SecretPlay repository folder.
   The folder must contain .git and android_app/pubspec.yaml.
   Preserve the existing .git folder. Do not delete it.
2. Ensure Git for Windows and GitHub CLI (gh) are installed.
3. Authenticate the intended account if needed:
   gh auth login --hostname github.com --git-protocol https --web
4. Confirm that `gh auth status` shows account `saayedh` and that the private
   repository `saayedh/chatMakhfee` exists and is accessible with write access.
5. Run:
   scripts\push-apk-workflow-to-chatMakhfee.bat
6. Review the staged summary and answer Y when asked.
7. Open:
   https://github.com/saayedh/chatMakhfee/actions

SAFETY
- The script never creates a repository.
- It checks that the target repository is exactly saayedh/chatMakhfee and PRIVATE.
- It refuses to run under a different GitHub login.
- It configures Git author identity only in this local repository using the
  GitHub noreply address if missing.
- It commits only .github/workflows/android-apk.yml.
- It does not deploy Cloudflare, create Workers, run Wrangler, or publish releases.
- It does not place GitHub tokens in source files.

IMPORTANT
This script pushes the workflow file to the existing repository. It does not
perform the push until you execute it locally and confirm Y. The actual APK is
built by GitHub Actions only after the push succeeds.
