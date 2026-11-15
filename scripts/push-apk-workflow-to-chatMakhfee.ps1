[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
$ExpectedRepo = 'saayedh/chatMakhfee'
$ExpectedRemote = 'https://github.com/saayedh/chatMakhfee.git'
$WorkflowRelativePath = '.github/workflows/android-apk.yml'

# Prevent Git/gh from opening interactive pagers in Windows consoles.
$env:GIT_PAGER = 'cat'
$env:PAGER = 'cat'
$env:GH_PAGER = 'cat'
$env:GIT_TERMINAL_PROMPT = '0'
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Invoke-Git {
    param([Parameter(Mandatory=$true)][string[]]$Arguments)
    $output = & git --no-pager -C $ProjectRoot @Arguments 2>&1
    $code = $LASTEXITCODE
    if ($output) { $output | ForEach-Object { Write-Host $_ } }
    if ($code -ne 0) { throw "git $($Arguments -join ' ') failed with exit code $code." }
    return $output
}

function Invoke-Gh {
    param([Parameter(Mandatory=$true)][string[]]$Arguments)
    $output = & gh @Arguments 2>&1
    $code = $LASTEXITCODE
    if ($output) { $output | ForEach-Object { Write-Host $_ } }
    if ($code -ne 0) { throw "gh $($Arguments -join ' ') failed with exit code $code." }
    return $output
}

function Get-GitOutput {
    param([Parameter(Mandatory=$true)][string[]]$Arguments)
    $output = & git -C $ProjectRoot @Arguments 2>$null
    $code = $LASTEXITCODE
    if ($code -ne 0) { return $null }
    return (($output | Out-String).Trim())
}

Write-Host ''
Write-Host 'SecretPlay APK workflow publisher' -ForegroundColor Cyan
Write-Host "Target repository: https://github.com/$ExpectedRepo"
Write-Host "Project folder:    $ProjectRoot"
Write-Host ''

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git for Windows is not installed.' }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI is not installed. Install it from https://cli.github.com/.' }
if (-not (Test-Path (Join-Path $ProjectRoot '.git'))) { throw 'No .git folder was found. Run this script from the existing SecretPlay repository; do not initialize a different repository.' }
if (-not (Test-Path (Join-Path $ProjectRoot 'android_app/pubspec.yaml'))) { throw 'The selected folder is not the SecretPlay project root (android_app/pubspec.yaml is missing).' }

$workflowPath = Join-Path $ProjectRoot $WorkflowRelativePath
if (-not (Test-Path $workflowPath)) { throw "Workflow file is missing: $WorkflowRelativePath. Extract the supplied patch ZIP over the project root first." }
$workflowText = Get-Content -LiteralPath $workflowPath -Raw
if ($workflowText -notmatch '(?m)^\s*run:\s*flutter build apk --debug\s*$') { throw 'The workflow does not contain the expected debug APK build step. Refusing to push an unexpected workflow.' }
if ($workflowText -notmatch 'name:\s*SecretPlay-Android-APK') { throw 'The expected APK artifact name was not found in the workflow.' }
if ($workflowText -match '(?im)^\s*run:.*(wrangler|npm\s+(ci|run)|cloudflare|deploy|release)') { throw 'The workflow appears to contain backend deployment or release commands. Refusing to push.' }

Write-Host 'Checking GitHub CLI authentication...'
$authOutput = & gh auth status 2>&1
$authCode = $LASTEXITCODE
if ($authOutput) { $authOutput | ForEach-Object { Write-Host $_ } }
if ($authCode -ne 0) { throw 'GitHub CLI is not authenticated. Run: gh auth login --hostname github.com --git-protocol https --web' }

$userJsonText = & gh api user 2>&1
if ($LASTEXITCODE -ne 0) { throw 'Could not read the authenticated GitHub account profile.' }
$user = ($userJsonText | Out-String | ConvertFrom-Json)
if ($user.login -ne 'saayedh') {
    throw "The authenticated account is '$($user.login)', but the requested target owner is 'saayedh'. Run 'gh auth switch --user saayedh' and retry."
}

$repoJsonText = & gh repo view $ExpectedRepo --json visibility,nameWithOwner 2>&1
if ($LASTEXITCODE -ne 0) { throw "Cannot access $ExpectedRepo. Confirm that this repository exists and the authenticated account has write access." }
$repo = ($repoJsonText | Out-String | ConvertFrom-Json)
if ($repo.nameWithOwner -ne $ExpectedRepo) { throw "GitHub returned unexpected repository '$($repo.nameWithOwner)'. Expected '$ExpectedRepo'." }
if ($repo.visibility -ne 'PRIVATE') { throw "The target repository is not PRIVATE (visibility: $($repo.visibility)). Refusing to push source." }

# Make sure this exact repository is the origin. No repository creation is attempted.
$origin = Get-GitOutput @('remote', 'get-url', 'origin')
if ([string]::IsNullOrWhiteSpace($origin)) {
    Write-Host 'Adding the expected origin remote...'
    Invoke-Git @('remote', 'add', 'origin', $ExpectedRemote) | Out-Null
} elseif ($origin -ne $ExpectedRemote -and $origin -ne 'https://github.com/saayedh/chatMakhfee') {
    Write-Host "Updating origin from '$origin' to the explicitly requested repository."
    Invoke-Git @('remote', 'set-url', 'origin', $ExpectedRemote) | Out-Null
}

$branch = Get-GitOutput @('branch', '--show-current')
if ($branch -ne 'main') {
    $mainExists = (& git -C $ProjectRoot show-ref --verify --quiet refs/heads/main; $LASTEXITCODE -eq 0)
    if ($mainExists) {
        Invoke-Git @('switch', 'main') | Out-Null
    } else {
        Invoke-Git @('branch', '-M', 'main') | Out-Null
    }
}

# Set a repository-local commit identity from the authenticated GitHub profile.
$gitName = Get-GitOutput @('config', '--local', 'user.name')
$gitEmail = Get-GitOutput @('config', '--local', 'user.email')
$defaultName = if (-not [string]::IsNullOrWhiteSpace($user.name)) { $user.name } else { $user.login }
$defaultEmail = "$($user.id)+$($user.login)@users.noreply.github.com"
if ([string]::IsNullOrWhiteSpace($gitName)) { Invoke-Git @('config', '--local', 'user.name', $defaultName) | Out-Null }
if ([string]::IsNullOrWhiteSpace($gitEmail)) { Invoke-Git @('config', '--local', 'user.email', $defaultEmail) | Out-Null }

# Do not accidentally include unrelated staged files in this commit.
$stagedBefore = Get-GitOutput @('diff', '--cached', '--name-only')
if (-not [string]::IsNullOrWhiteSpace($stagedBefore)) {
    $other = @($stagedBefore -split "`r?`n" | Where-Object { $_ -and $_ -ne $WorkflowRelativePath })
    if ($other.Count -gt 0) {
        throw "Other files are already staged. Commit or unstage them separately first: $($other -join ', ')"
    }
}

Write-Host 'Staging only the APK workflow file...'
Invoke-Git @('add', '--', $WorkflowRelativePath) | Out-Null
$stagedNow = Get-GitOutput @('diff', '--cached', '--name-only')
if ([string]::IsNullOrWhiteSpace($stagedNow)) {
    Write-Host 'The workflow file has no new changes. The script will only push main if needed.' -ForegroundColor Yellow
} else {
    $stagedList = @($stagedNow -split "`r?`n" | Where-Object { $_ })
    if ($stagedList.Count -ne 1 -or $stagedList[0] -ne $WorkflowRelativePath) {
        throw "Unexpected staged files: $($stagedList -join ', '). Refusing to commit anything except $WorkflowRelativePath."
    }
    Write-Host 'Change to be committed:'
    Invoke-Git @('diff', '--cached', '--stat') | Out-Null
    $confirm = Read-Host "Push this APK-only workflow change to $ExpectedRepo on branch main? (Y/N)"
    if ($confirm -notmatch '^(?i)y(es)?$') { throw 'Cancelled by user. No push was performed.' }
    Invoke-Git @('commit', '-m', 'Configure GitHub Actions for APK-only builds') | Out-Null
}

Write-Host 'Pushing to the exact requested repository...'
Invoke-Git @('push', '-u', 'origin', 'main') | Out-Null
Write-Host ''
Write-Host '[SUCCESS] APK workflow pushed to the requested repository.' -ForegroundColor Green
Write-Host "Repository: https://github.com/$ExpectedRepo"
Write-Host "Actions:    https://github.com/$ExpectedRepo/actions"
Write-Host 'GitHub Actions will build the APK. No Cloudflare deployment is performed.'
