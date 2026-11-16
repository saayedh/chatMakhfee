[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$publisher = Join-Path $PSScriptRoot 'github-push.ps1'
if (-not (Test-Path -LiteralPath $publisher)) {
    throw "The general repository publisher is missing: $publisher"
}

Write-Host 'This update changes multiple Android build files, not only the workflow.'
Write-Host 'Delegating to github-push.ps1 so all related source changes are reviewed together.'
& $publisher -ProjectRoot $ProjectRoot
if ($LASTEXITCODE -ne 0) {
    throw "Repository push helper failed with exit code $LASTEXITCODE."
}
