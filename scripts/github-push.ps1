[CmdletBinding()]
param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path $ProjectRoot).Path
$ExpectedRepoSlug = 'saayedh/chatMakhfee'
$ExpectedRemoteUrl = 'https://github.com/saayedh/chatMakhfee.git'

# Prevent Git/GitHub CLI from opening an interactive pager (for example less).
# This is important when the script is launched from a Windows BAT/PowerShell console.
$env:GIT_PAGER = 'cat'
$env:PAGER = 'cat'
$env:GH_PAGER = 'cat'

function Invoke-Git([string[]]$Arguments) {
    & git --no-pager -C $ProjectRoot @Arguments
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE." }
}
function Invoke-Gh([string[]]$Arguments) {
    & gh @Arguments
    if ($LASTEXITCODE -ne 0) { throw "gh $($Arguments -join ' ') failed with exit code $LASTEXITCODE." }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Install Git for Windows first.' }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'Install GitHub CLI (gh) first: https://cli.github.com/' }
if (-not (Test-Path (Join-Path $ProjectRoot 'android_app\pubspec.yaml'))) { throw 'This folder does not look like the SecretPlay project root.' }
if (-not (Test-Path (Join-Path $ProjectRoot '.gitignore'))) { throw '.gitignore is missing; refusing to initialize a repository.' }

Write-Host 'Checking GitHub CLI authentication...'
& gh auth status 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Starting browser-based GitHub login. No token will be written to source files.'
    Invoke-Gh @('auth', 'login', '--hostname', 'github.com', '--git-protocol', 'https', '--web')
}

if (-not (Test-Path (Join-Path $ProjectRoot '.git'))) {
    Invoke-Git @('init')
}
$branch = (& git -C $ProjectRoot branch --show-current).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Could not determine the current Git branch.' }
if ([string]::IsNullOrWhiteSpace($branch)) {
    Invoke-Git @('switch', '-c', 'main')
} elseif ($branch -ne 'main') {
    $choice = Read-Host "Current branch is '$branch'. Rename it to 'main'? (Y/N)"
    if ($choice -notmatch '^(?i)y(es)?$') { throw 'Push cancelled; the current branch was not changed.' }
    Invoke-Git @('branch', '-M', 'main')
}

# This project is configured for one existing private repository.
# Do not offer to create a different repository or push to an accidental remote.
$remoteNames = @(& git -C $ProjectRoot remote)
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect Git remotes.' }
$hasOrigin = ($remoteNames -contains 'origin')
if (-not $hasOrigin) {
    Write-Host "No origin is configured. Connecting to the configured repository: $ExpectedRepoSlug"
    $repoJson = & gh repo view $ExpectedRepoSlug --json visibility,nameWithOwner 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Repository $ExpectedRepoSlug was not found or is not accessible to the authenticated GitHub account. Create/access it first, then rerun this script."
    }
    $repoInfo = ($repoJson | Out-String | ConvertFrom-Json)
    if ($repoInfo.visibility -ne 'PRIVATE') {
        throw "Repository $ExpectedRepoSlug is not PRIVATE. Refusing to push SecretPlay source into a public repository."
    }
    Invoke-Git @('remote', 'add', 'origin', $ExpectedRemoteUrl)
} else {
    $originOutput = & git -C $ProjectRoot remote get-url origin
    if ($LASTEXITCODE -ne 0) { throw 'Git remote origin exists, but its URL could not be read.' }
    $origin = ($originOutput | Out-String).Trim()
    if ($origin -notmatch '(?:github\.com[:/])([^/]+/[^/]+?)(?:\.git)?$') {
        throw "Origin is not a recognizable GitHub repository URL: $origin"
    }
    if ($matches[1] -ne $ExpectedRepoSlug) {
        throw "This project is configured for $ExpectedRepoSlug, but origin points to $($matches[1]). Refusing to push to the wrong repository."
    }
    Write-Host "Using configured repository: $ExpectedRepoSlug"
}

$remoteUrl = (& git -C $ProjectRoot remote get-url origin).Trim()
$repoInfoJson = & gh repo view $ExpectedRepoSlug --json visibility,nameWithOwner 2>$null
if ($LASTEXITCODE -ne 0) { throw "Cannot access GitHub repository $ExpectedRepoSlug. Check gh auth status and repository access." }
$repoInfo = ($repoInfoJson | Out-String | ConvertFrom-Json)
if ($repoInfo.visibility -ne 'PRIVATE') { throw "Repository $ExpectedRepoSlug is not PRIVATE. Refusing to push SecretPlay source into a public repository." }

Write-Host 'Staging project files...'
Invoke-Git @('add', '-A')
$scanPassed = & (Join-Path $PSScriptRoot 'git-secret-scan.ps1') -ProjectRoot $ProjectRoot -StagedOnly
if ($scanPassed -ne $true) { throw 'Secret scan blocked the push. Review staged files before continuing.' }

Write-Host ''
Write-Host 'Staged file summary:'
Invoke-Git @('diff', '--cached', '--stat')
$confirm = Read-Host 'Commit and push these files to the PRIVATE repository? (Y/N)'
if ($confirm -notmatch '^(?i)y(es)?$') { throw 'Push cancelled by user.' }

# Configure a repository-local commit identity if Git has no identity yet.
# Use the authenticated GitHub account's noreply address by default.
$gitName = (& git -C $ProjectRoot config user.name 2>$null | Out-String).Trim()
$gitEmail = (& git -C $ProjectRoot config user.email 2>$null | Out-String).Trim()
if ([string]::IsNullOrWhiteSpace($gitName) -or [string]::IsNullOrWhiteSpace($gitEmail)) {
    $userJson = & gh api user 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the authenticated GitHub account profile to configure the local commit identity.' }
    $githubUser = ($userJson | Out-String | ConvertFrom-Json)
    $defaultName = if (-not [string]::IsNullOrWhiteSpace($githubUser.name)) { $githubUser.name } else { $githubUser.login }
    $defaultEmail = "$($githubUser.id)+$($githubUser.login)@users.noreply.github.com"
    if ([string]::IsNullOrWhiteSpace($gitName)) {
        $enteredName = Read-Host "Git commit author name (Enter for '$defaultName')"
        $gitName = if ([string]::IsNullOrWhiteSpace($enteredName)) { $defaultName } else { $enteredName.Trim() }
        Invoke-Git @('config', '--local', 'user.name', $gitName)
    }
    if ([string]::IsNullOrWhiteSpace($gitEmail)) {
        $enteredEmail = Read-Host "Git commit email (Enter for GitHub private noreply address '$defaultEmail')"
        $gitEmail = if ([string]::IsNullOrWhiteSpace($enteredEmail)) { $defaultEmail } else { $enteredEmail.Trim() }
        Invoke-Git @('config', '--local', 'user.email', $gitEmail)
    }
}

$staged = & git -C $ProjectRoot diff --cached --quiet
if ($LASTEXITCODE -eq 0) { Write-Host 'No staged changes. Checking whether main needs an initial push.' }
else {
    $message = Read-Host 'Commit message (Enter for default)'
    if ([string]::IsNullOrWhiteSpace($message)) { $message = 'Prepare SecretPlay source and CI pipeline' }
    Invoke-Git @('commit', '-m', $message)
}
Invoke-Git @('push', '-u', 'origin', 'main')
Write-Host ''
Write-Host '[SUCCESS] Source pushed to a PRIVATE GitHub repository.' -ForegroundColor Green
Write-Host "Repository: https://github.com/$ExpectedRepoSlug"
Write-Host "Actions:    https://github.com/$ExpectedRepoSlug/actions"
Write-Host 'The Android CI workflow should now start. Download the APK only after a successful run.'
