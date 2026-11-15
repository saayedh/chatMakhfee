[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$Wait,
    [ValidateRange(1, 240)][int]$WaitTimeoutMinutes = 45
)
$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path $ProjectRoot).Path
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI is required: https://cli.github.com/' }
& gh auth status 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Authenticate first with: gh auth login' }
$origin = & git -C $ProjectRoot remote get-url origin 2>$null
if ($LASTEXITCODE -ne 0) { throw 'No Git origin is configured. Run github-push.bat first.' }
$origin = ($origin | Out-String).Trim()
if ($origin -notmatch '(?:github\.com[:/])([^/]+/[^/]+?)(?:\.git)?$') { throw 'Origin is not a GitHub repository.' }
$repo = $matches[1]
$actionsUrl = "https://github.com/$repo/actions/workflows/android-apk.yml"

Write-Host "Looking for the latest successful Android CI run in $repo ..."
$run = $null
$waitStarted = [DateTime]::UtcNow
while ($true) {
    $json = & gh run list --repo $repo --workflow android-apk.yml --branch main --status success --limit 1 --json databaseId,headSha,url,createdAt,event
    if ($LASTEXITCODE -ne 0) { throw 'Could not query GitHub Actions runs.' }
    $runs = @($json | ConvertFrom-Json)
    if ($runs.Count -gt 0 -and $runs[0].databaseId) { $run = $runs[0]; break }
    if (-not $Wait) { break }
    if (([DateTime]::UtcNow - $waitStarted).TotalMinutes -ge $WaitTimeoutMinutes) {
        Write-Host $actionsUrl
        throw "No successful APK workflow run appeared within $WaitTimeoutMinutes minutes."
    }
    Write-Host "No successful run yet. Waiting 20 seconds... (timeout: $WaitTimeoutMinutes minutes)"
    Start-Sleep -Seconds 20
}
if (-not $run) {
    Write-Warning 'No successful run found. Open the workflow page, fix any failure, and rerun it.'
    Write-Host $actionsUrl
    exit 3
}
Write-Host "Run ID:  $($run.databaseId)"
Write-Host "Commit:  $($run.headSha)"
Write-Host "Run URL: $($run.url)"

$downloadRoot = Join-Path $env:TEMP ("SecretPlayArtifact-" + $run.databaseId)
if (Test-Path $downloadRoot) { Remove-Item -LiteralPath $downloadRoot -Recurse -Force }
New-Item -ItemType Directory -Path $downloadRoot -Force | Out-Null
& gh run download $run.databaseId --repo $repo --name SecretPlay-Android-Debug-APK --dir $downloadRoot
if ($LASTEXITCODE -ne 0) { throw 'The successful workflow run did not contain the expected debug APK artifact.' }
$apk = Get-ChildItem -LiteralPath $downloadRoot -Filter '*.apk' -File -Recurse | Select-Object -First 1
if (-not $apk) { throw 'Downloaded artifact contains no APK.' }
$checksumFile = Get-ChildItem -LiteralPath $downloadRoot -Filter 'SHA256SUMS.txt' -File -Recurse | Select-Object -First 1
if (-not $checksumFile) { throw 'Artifact is missing SHA256SUMS.txt; refusing to trust the APK.' }
$line = Get-Content -LiteralPath $checksumFile.FullName | Where-Object { $_ -match '^[A-Fa-f0-9]{64}\s+' } | Select-Object -First 1
if (-not $line) { throw 'Checksum file is malformed.' }
$expected = ($line -split '\s+')[0].ToLowerInvariant()
$actual = (Get-FileHash -LiteralPath $apk.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $expected) { throw 'APK SHA-256 mismatch. Downloaded file may be corrupted or altered.' }

$artifactDir = Join-Path $ProjectRoot 'artifacts\github-debug'
New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
$destination = Join-Path $artifactDir 'SecretPlay-Android-Debug.apk'
Copy-Item -LiteralPath $apk.FullName -Destination $destination -Force
Copy-Item -LiteralPath $checksumFile.FullName -Destination (Join-Path $artifactDir 'SHA256SUMS.txt') -Force
$metadata = Get-ChildItem -LiteralPath $downloadRoot -Filter 'build-metadata.json' -File -Recurse | Select-Object -First 1
if ($metadata) { Copy-Item $metadata.FullName (Join-Path $artifactDir 'build-metadata.json') -Force }
Write-Host '[OK] APK downloaded and SHA-256 verified.' -ForegroundColor Green
Write-Host "APK: $destination"
Write-Host "SHA256: $actual"
