[CmdletBinding()]
param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path $ProjectRoot).Path
$ExpectedRepo = 'saayedh/chatMakhfee'
$ExpectedRemote = 'https://github.com/saayedh/chatMakhfee.git'

function Invoke-Git([string[]]$Arguments) {
    & git -C $ProjectRoot @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}
function Invoke-Gh([string[]]$Arguments) {
    & gh @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "gh $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Install Git for Windows first.' }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'Install GitHub CLI first: https://cli.github.com/' }
if (-not (Test-Path (Join-Path $ProjectRoot 'android_app\pubspec.yaml'))) { throw 'Not a SecretPlay project root.' }
if (-not (Test-Path (Join-Path $ProjectRoot '.git'))) { throw 'Run this helper from an existing Git clone; it will not initialize a new repository.' }

$env:GIT_PAGER = 'cat'
$env:PAGER = 'cat'
$env:GH_PAGER = 'cat'

& gh auth status 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Starting browser-based GitHub login.'
    Invoke-Gh @('auth', 'login', '--hostname', 'github.com', '--git-protocol', 'https', '--web')
}

$repoJson = & gh repo view $ExpectedRepo --json nameWithOwner 2>$null
if ($LASTEXITCODE -ne 0) { throw "Cannot access $ExpectedRepo with the authenticated GitHub account." }
$repoInfo = ($repoJson | Out-String | ConvertFrom-Json)
if ($repoInfo.nameWithOwner -ne $ExpectedRepo) { throw "Unexpected repository: $($repoInfo.nameWithOwner)" }

$branch = (& git -C $ProjectRoot branch --show-current).Trim()
if ($LASTEXITCODE -ne 0 -or $branch -ne 'main') {
    throw "Switch to the existing main branch before running this helper. Current branch: '$branch'."
}

$remoteNames = @(& git -C $ProjectRoot remote)
if ($LASTEXITCODE -ne 0) { throw 'Could not inspect Git remotes.' }
if ($remoteNames -notcontains 'origin') {
    Invoke-Git @('remote', 'add', 'origin', $ExpectedRemote)
} else {
    $origin = (& git -C $ProjectRoot remote get-url origin).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Could not read origin URL.' }
    if ($origin -notmatch '(?:github\.com[:/])([^/]+/[^/]+?)(?:\.git)?$') {
        throw "Origin is not a recognizable GitHub URL: $origin"
    }
    if ($matches[1] -ne $ExpectedRepo) {
        throw "Expected origin $ExpectedRepo but found $($matches[1]). Refusing to push to another repository."
    }
}

Write-Host 'Fetching the current remote main branch...'
Invoke-Git @('fetch', 'origin', 'main')
& git -C $ProjectRoot merge-base --is-ancestor origin/main HEAD
if ($LASTEXITCODE -ne 0) {
    throw 'Local main does not contain remote main. Update/rebase first; this helper will never force-push.'
}

Write-Host 'Staging project changes...'
Invoke-Git @('add', '-A')
$scanScript = Join-Path $PSScriptRoot 'git-secret-scan.ps1'
if (Test-Path $scanScript) {
    $scanResult = & $scanScript -ProjectRoot $ProjectRoot -StagedOnly
    if ($LASTEXITCODE -ne 0 -or $scanResult -contains $false) {
        throw 'Secret scan failed. Review staged files before continuing.'
    }
}

Write-Host ''
Write-Host 'Staged change summary:'
Invoke-Git @('diff', '--cached', '--stat')
$confirmation = Read-Host "Commit and push these changes to $ExpectedRepo on main? (Y/N)"
if ($confirmation -notmatch '^(?i)y(es)?$') { throw 'Push cancelled by user.' }

& git -C $ProjectRoot diff --cached --quiet
if ($LASTEXITCODE -eq 1) {
    $message = Read-Host 'Commit message (Enter for default)'
    if ([string]::IsNullOrWhiteSpace($message)) { $message = 'Fix Android APK Gradle toolchain and CI workflow' }
    Invoke-Git @('commit', '-m', $message)
} elseif ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect staged changes.'
} else {
    Write-Host 'No staged changes to commit.'
}

Invoke-Git @('push', '-u', 'origin', 'main')
Write-Host "[SUCCESS] Changes pushed to https://github.com/$ExpectedRepo/tree/main" -ForegroundColor Green
Write-Host "Actions: https://github.com/$ExpectedRepo/actions"
