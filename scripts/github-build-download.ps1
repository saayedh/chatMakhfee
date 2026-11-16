[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$Wait,
    [ValidateRange(1, 240)][int]$WaitTimeoutMinutes = 45
)
$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path $ProjectRoot).Path
$RepoSlug = 'saayedh/chatMakhfee'
$WorkflowFile = 'android-apk.yml'
$ArtifactName = 'SecretPlay-Android-APK'

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI is required: https://cli.github.com/' }
& gh auth status 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Authenticate first with: gh auth login' }

# If origin exists, ensure it is the configured repository. Otherwise use the fixed repository.
$remoteNames = @(& git -C $ProjectRoot remote 2>$null)
if ($LASTEXITCODE -eq 0 -and ($remoteNames -contains 'origin')) {
    $origin = (& git -C $ProjectRoot remote get-url origin 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $origin -notmatch '(?:github\.com[:/])([^/]+/[^/]+?)(?:\.git)?$') {
        throw 'The configured Git origin is not a valid GitHub repository URL.'
    }
    if ($matches[1] -ne $RepoSlug) { throw "Expected origin $RepoSlug but found $($matches[1]). Refusing to download from another repository." }
}

$repoInfoJson = & gh repo view $RepoSlug --json nameWithOwner 2>$null
if ($LASTEXITCODE -ne 0) { throw "Cannot access $RepoSlug. Check GitHub CLI authentication and repository access." }
$repoInfo = ($repoInfoJson | Out-String | ConvertFrom-Json)
if ($repoInfo.nameWithOwner -ne $RepoSlug) { throw "Expected repository $RepoSlug." }
$actionsUrl = "https://github.com/$RepoSlug/actions/workflows/$WorkflowFile"

Write-Host "Looking for the latest successful APK build in $RepoSlug ..."
$run = $null
$waitStarted = [DateTime]::UtcNow
while ($true) {
    $json = & gh run list --repo $RepoSlug --workflow $WorkflowFile --branch main --status success --limit 1 --json databaseId,headSha,url,createdAt,event
    if ($LASTEXITCODE -ne 0) { throw 'Could not query GitHub Actions runs.' }
    $runs = @($json | ConvertFrom-Json)
    if ($runs.Count -gt 0 -and $runs[0].databaseId) { $run = $runs[0]; break }
    if (-not $Wait) { break }
    if (([DateTime]::UtcNow - $waitStarted).TotalMinutes -ge $WaitTimeoutMinutes) {
        Write-Host $actionsUrl
        throw "No successful APK build appeared within $WaitTimeoutMinutes minutes."
    }
    Write-Host "No successful run yet. Waiting 20 seconds... (timeout: $WaitTimeoutMinutes minutes)"
    Start-Sleep -Seconds 20
}
if (-not $run) {
    Write-Warning 'No successful APK build found. Open the Actions page and inspect the latest run.'
    Write-Host $actionsUrl
    exit 3
}
Write-Host "Run ID:  $($run.databaseId)"
Write-Host "Commit:  $($run.headSha)"
Write-Host "Run URL: $($run.url)"

$downloadRoot = Join-Path $env:TEMP ("SecretPlayArtifact-" + $run.databaseId)
if (Test-Path $downloadRoot) { Remove-Item -LiteralPath $downloadRoot -Recurse -Force }
New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
& gh run download $run.databaseId --repo $RepoSlug --name $ArtifactName --dir $downloadRoot
if ($LASTEXITCODE -ne 0) { throw "The successful workflow run did not contain artifact '$ArtifactName'." }
$apk = Get-ChildItem -LiteralPath $downloadRoot -Filter '*.apk' -File -Recurse | Select-Object -First 1
if (-not $apk -or $apk.Length -le 0) { throw 'Downloaded artifact contains no valid APK file.' }

$artifactDir = Join-Path $ProjectRoot 'artifacts\github-apk'
New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
$destination = Join-Path $artifactDir 'SecretPlay-Android.apk'
Copy-Item -LiteralPath $apk.FullName -Destination $destination -Force
$hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host '[OK] APK downloaded.' -ForegroundColor Green
Write-Host "APK: $destination"
Write-Host "Size: $((Get-Item -LiteralPath $destination).Length) bytes"
Write-Host "SHA-256 (local): $hash"
Write-Host 'Note: this is a debug APK. Its runner-generated debug certificate may differ between builds.'
