[CmdletBinding()]
param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path $ProjectRoot).Path
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git is required.' }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI is required.' }
& gh auth status 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Authenticate using gh auth login first.' }
$origin = (& git -C $ProjectRoot remote get-url origin 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $origin -notmatch '(?:github\.com[:/])([^/]+/[^/]+?)(?:\.git)?$') { throw 'A valid GitHub origin is required.' }
$repo = $matches[1]
$repoInfo = (& gh repo view $repo --json visibility | ConvertFrom-Json)
if ($repoInfo.visibility -ne 'PRIVATE') { throw 'Release helper requires a PRIVATE repository.' }
$branch = (& git -C $ProjectRoot branch --show-current | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $branch -ne 'main') { throw 'Create release tags only from the main branch.' }
& git -C $ProjectRoot fetch origin main --prune
if ($LASTEXITCODE -ne 0) { throw 'Could not fetch origin/main; refusing to create a release tag.' }
$localHead = (& git -C $ProjectRoot rev-parse HEAD).Trim()
$remoteMain = (& git -C $ProjectRoot rev-parse origin/main).Trim()
if ($LASTEXITCODE -ne 0 -or $localHead -ne $remoteMain) { throw 'Local HEAD is not exactly the current origin/main commit. Push and verify main before tagging a release.' }

$status = & git -C $ProjectRoot status --porcelain
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect Git working tree.' }
if (-not [string]::IsNullOrWhiteSpace(($status | Out-String).Trim())) { throw 'Git working tree is not clean. Commit or discard changes first.' }

$version = Read-Host 'Release version (e.g. 1.0.0)'
if ($version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') { throw 'Version must follow semantic version syntax, e.g. 1.0.0.' }
$tag = "v$version"
& git -C $ProjectRoot rev-parse --verify "refs/tags/$tag" *> $null
if ($LASTEXITCODE -eq 0) { throw "Tag $tag already exists. Choose a new version; existing tags are never replaced." }

$required = @('ANDROID_KEYSTORE_BASE64','ANDROID_KEYSTORE_PASSWORD','ANDROID_KEY_ALIAS','ANDROID_KEY_PASSWORD')
$secretJson = & gh secret list --repo $repo --json name
if ($LASTEXITCODE -ne 0) { throw 'Could not list repository secret names.' }
$secrets = @($secretJson | ConvertFrom-Json | ForEach-Object { $_.name })
$missing = @($required | Where-Object { $_ -notin $secrets })
if ($missing.Count -gt 0) {
    throw "Missing Android signing GitHub Secrets: $($missing -join ', '). Run scripts\setup-android-signing.bat first. No tag was created."
}

$scan = Join-Path $PSScriptRoot 'git-secret-scan.ps1'
$scanPassed = & $scan -ProjectRoot $ProjectRoot
if ($scanPassed -ne $true) { throw 'Secret scan failed. Release tag was not created.' }
$confirm = Read-Host "Create and push annotated tag $tag? The GitHub workflow will build and publish the signed APK. (Y/N)"
if ($confirm -notmatch '^(?i)y(es)?$') { throw 'Release cancelled.' }
& git -C $ProjectRoot tag -a $tag -m "SecretPlay $tag"
if ($LASTEXITCODE -ne 0) { throw 'Could not create annotated tag.' }
& git -C $ProjectRoot push origin $tag
if ($LASTEXITCODE -ne 0) { throw 'Tag push failed. The tag remains local; inspect Git before retrying.' }
Write-Host '[OK] Tag pushed. GitHub Actions will validate and build the signed release.' -ForegroundColor Green
Write-Host "Workflow: https://github.com/$repo/actions/workflows/android-apk.yml"
Write-Host "Releases: https://github.com/$repo/releases"
Write-Host 'The release is not ready until the GitHub Actions run succeeds.'
