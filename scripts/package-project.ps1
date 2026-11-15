[CmdletBinding()]
param(
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$OutputDirectory = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'SecretPlay_Deliveries'),
    [switch]$IncludeDownloadedApk
)
$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path $ProjectRoot).Path
$scanScript = Join-Path $PSScriptRoot 'git-secret-scan.ps1'
if (Test-Path $scanScript) { $scanPassed = & $scanScript -ProjectRoot $ProjectRoot; if ($scanPassed -ne $true) { throw 'Secret scan failed; refusing to package the project.' } }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$timestamp = Get-Date -Format 'yyyyMMdd_HHmm'
$zipPath = Join-Path $OutputDirectory "SecretPlay_Final_Source_$timestamp.zip"
$tempRoot = Join-Path $env:TEMP ("SecretPlay-Package-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

$excludedDirs = @('.git','node_modules','.dart_tool','.gradle','.wrangler','.idea','.vscode','build','coverage','Pods','DerivedData','__pycache__','.pytest_cache','.mypy_cache','.venv','venv','target')
$excludedNames = @('.env','.dev.vars','local.properties','key.properties','.npmrc')
$included = New-Object System.Collections.Generic.List[string]
try {
    $files = Get-ChildItem -LiteralPath $ProjectRoot -File -Recurse -Force
    foreach ($file in $files) {
        $relative = $file.FullName.Substring($ProjectRoot.Length + 1)
        $parts = $relative -split '[\\/]'
        $skipDirectory = $false
        foreach ($part in $parts) { if ($excludedDirs -contains $part) { $skipDirectory = $true; break } }
        if ($skipDirectory) { continue }
        if ($file.Name -in $excludedNames) { continue }
        if ($file.Name -like '.env.*' -and $file.Name -ne '.env.example') { continue }
        if ($file.Name -match '(?i)\.(?:jks|keystore|p12|pfx|p7b|p7c|key|pem|p8|asc|gpg|mobileprovision|provisionprofile)$') { continue }
        if ($file.Name -match '(?i)^(?:id_rsa|id_ed25519|.*private.*\.pem|.*recovery-secret.*)$') { continue }
        if ($relative -match '^voice_harness[\/]probe\d*\.ts$') { continue }
        if ($relative -match '(?i)(?:^|[\\/])(?:secrets|private_keys|recovery_exports)(?:[\\/]|$)') { continue }
        if ($file.Extension -eq '.zip') { continue }
        if (-not $IncludeDownloadedApk -and $relative -match '^artifacts[\\/]') { continue }
        if ($relative -match '^artifacts[\\/]' -and $file.Extension -ne '.apk' -and $file.Name -notin @('SHA256SUMS.txt','build-metadata.json')) { continue }

        $destination = Join-Path $tempRoot $relative
        $destinationDir = Split-Path -Parent $destination
        New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
        $included.Add($relative)
    }

    if ($included.Count -eq 0) { throw 'No project files were selected for packaging.' }
    $manifest = @(
        'SecretPlay source package',
        "Created UTC: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))",
        "Files: $($included.Count)",
        '',
        'This archive excludes Git metadata, dependency/build caches, .env files, signing keys, local.properties and private credentials.',
        'It does not imply an APK is included unless an APK is present in the artifacts folder and IncludeDownloadedApk was selected.'
    )
    $manifest | Set-Content -Path (Join-Path $tempRoot 'PACKAGE_MANIFEST.txt') -Encoding UTF8
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    [IO.Compression.ZipFile]::CreateFromDirectory($tempRoot, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $false)

    $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $entryCount = $archive.Entries.Count
        if ($entryCount -lt ($included.Count + 1)) { throw 'ZIP verification failed: the archive contains fewer entries than expected.' }
        foreach ($entry in $archive.Entries) {
            if ([string]::IsNullOrWhiteSpace($entry.FullName)) { throw 'ZIP contains an invalid entry.' }
            if (-not $entry.FullName.EndsWith('/')) {
                $stream = $entry.Open()
                try {
                    $buffer = New-Object byte[] 65536
                    while ($stream.Read($buffer, 0, $buffer.Length) -gt 0) { }
                } finally { $stream.Dispose() }
            }
        }
    } finally { $archive.Dispose() }
    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $checksumPath = "$zipPath.sha256"
    "$hash  $(Split-Path -Leaf $zipPath)" | Set-Content -Path $checksumPath -Encoding ASCII
    $zipInfo = Get-Item -LiteralPath $zipPath
    Write-Host '[OK] SecretPlay source ZIP created and verified.' -ForegroundColor Green
    Write-Host "ZIP: $($zipInfo.FullName)"
    Write-Host "Size: $([math]::Round($zipInfo.Length / 1MB, 2)) MB"
    Write-Host "Entries: $entryCount"
    Write-Host "SHA-256: $hash"
    Write-Host "Checksum: $checksumPath"
} finally {
    if (Test-Path $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
