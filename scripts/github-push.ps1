[CmdletBinding()]
param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path $ProjectRoot).Path

function Invoke-Git([string[]]$Arguments) {
    & git -C $ProjectRoot @Arguments
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

# Inspect configured remotes without intentionally running a command that
# exits non-zero when 'origin' does not exist. Under PowerShell with
# $ErrorActionPreference='Stop', native stderr can otherwise become a
# terminating NativeCommandError before the no-origin flow is reached.
$remoteNames = @(& git -C $ProjectRoot remote)
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect Git remotes.' }
$hasOrigin = ($remoteNames -contains 'origin')
$origin = $null
if ($hasOrigin) {
    $originOutput = & git -C $ProjectRoot remote get-url origin
    if ($LASTEXITCODE -ne 0) { throw 'Git remote origin exists, but its URL could not be read.' }
    $origin = ($originOutput | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($origin)) { throw 'Git remote origin has an empty URL.' }
}
if (-not $hasOrigin) {
    Write-Host ''
    Write-Host 'Choose repository setup:'
    Write-Host '  1) Create a NEW private GitHub repository'
    Write-Host '  2) Use an EXISTING GitHub repository'
    $choice = Read-Host 'Select 1 or 2'
    if ($choice -eq '1') {
        $repoName = Read-Host 'New repository name (e.g. SecretPlay)'
        if ($repoName -notmatch '^[A-Za-z0-9._-]{1,100}$') { throw 'Repository name contains invalid characters.' }
        $owner = Read-Host 'GitHub owner or organization (leave blank for your account)'
        if ([string]::IsNullOrWhiteSpace($owner)) { Invoke-Gh @('repo', 'create', $repoName, '--private', '--source', $ProjectRoot, '--remote', 'origin') }
        else { Invoke-Gh @('repo', 'create', "$owner/$repoName", '--private', '--source', $ProjectRoot, '--remote', 'origin') }
    } elseif ($choice -eq '2') {
        $remoteUrl = Read-Host 'Existing repository HTTPS or SSH URL'
        if ($remoteUrl -notmatch '^(https://github\.com/|git@github\.com:)') { throw 'Only a GitHub HTTPS or SSH remote is accepted.' }
        Invoke-Git @('remote', 'add', 'origin', $remoteUrl)
    } else { throw 'Invalid selection; no remote was configured.' }
} else {
    Write-Host "Using existing origin: $(($origin | Out-String).Trim())"
}

$remoteUrl = (& git -C $ProjectRoot remote get-url origin).Trim()
if ($remoteUrl -notmatch '(?:github\.com[:/])([^/]+/[^/]+?)(?:\.git)?$') { throw 'Origin is not a recognizable GitHub repository URL.' }
$repoSlug = $matches[1]
$repoInfo = (& gh repo view $repoSlug --json visibility,nameWithOwner | ConvertFrom-Json)
if ($repoInfo.visibility -ne 'PRIVATE') { throw "Repository $repoSlug is not PRIVATE. Refusing to push SecretPlay source into a public repository." }

Write-Host 'Staging project files...'
Invoke-Git @('add', '-A')
$scanPassed = & (Join-Path $PSScriptRoot 'git-secret-scan.ps1') -ProjectRoot $ProjectRoot -StagedOnly
if ($scanPassed -ne $true) { throw 'Secret scan blocked the push. Review staged files before continuing.' }

Write-Host ''
Write-Host 'Staged file summary:'
Invoke-Git @('diff', '--cached', '--stat')
$confirm = Read-Host 'Commit and push these files to the PRIVATE repository? (Y/N)'
if ($confirm -notmatch '^(?i)y(es)?$') { throw 'Push cancelled by user.' }

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
Write-Host "Repository: https://github.com/$repoSlug"
Write-Host "Actions:    https://github.com/$repoSlug/actions"
Write-Host 'The Android CI workflow should now start. Download the APK only after a successful run.'
