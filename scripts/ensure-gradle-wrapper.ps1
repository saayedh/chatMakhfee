[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$GradleVersion = '8.14.3'
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path $ProjectRoot).Path
$AndroidDir = Join-Path $ProjectRoot 'android_app\android'
if (-not (Test-Path $AndroidDir)) { throw "Android project folder not found: $AndroidDir" }

$FlutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
if (-not $FlutterCommand) { throw 'Flutter was not found on PATH. Install Flutter 3.38+ first.' }
$FlutterBin = Split-Path -Parent $FlutterCommand.Source
$FlutterRoot = Split-Path -Parent $FlutterBin

$AndroidSdk = $env:ANDROID_HOME
if ([string]::IsNullOrWhiteSpace($AndroidSdk)) { $AndroidSdk = $env:ANDROID_SDK_ROOT }
if ([string]::IsNullOrWhiteSpace($AndroidSdk)) {
    $LocalProperties = Join-Path $AndroidDir 'local.properties'
    if (Test-Path $LocalProperties) {
        $line = Get-Content $LocalProperties | Where-Object { $_ -match '^sdk\.dir=' } | Select-Object -First 1
        if ($line) { $AndroidSdk = $line.Substring('sdk.dir='.Length) }
    }
}
if ([string]::IsNullOrWhiteSpace($AndroidSdk)) {
    throw 'ANDROID_HOME / ANDROID_SDK_ROOT is not set. Install Android Studio SDK and configure ANDROID_HOME.'
}

# Merge required local paths without discarding unrelated Android local settings.
$LocalPropertiesPath = Join-Path $AndroidDir 'local.properties'
$Properties = @{}
if (Test-Path $LocalPropertiesPath) {
    foreach ($line in Get-Content $LocalPropertiesPath) {
        if ($line -match '^([^#=]+)=(.*)$') { $Properties[$matches[1]] = $matches[2] }
    }
}
$Properties['flutter.sdk'] = $FlutterRoot.Replace('\', '\\')
$Properties['sdk.dir'] = $AndroidSdk.Replace('\', '\\')
$localLines = @()
foreach ($key in ($Properties.Keys | Sort-Object)) { $localLines += ('{0}={1}' -f $key, $Properties[$key]) }
$localLines | Set-Content -Path $LocalPropertiesPath -Encoding ASCII

$GradleWrapperDir = Join-Path $AndroidDir 'gradle\wrapper'
$WrapperJar = Join-Path $GradleWrapperDir 'gradle-wrapper.jar'
$WrapperBat = Join-Path $AndroidDir 'gradlew.bat'
$WrapperProperties = Join-Path $GradleWrapperDir 'gradle-wrapper.properties'
if ((Test-Path $WrapperJar) -and (Test-Path $WrapperBat) -and (Test-Path $WrapperProperties)) {
    $existing = Get-Content $WrapperProperties -Raw
    if ($existing -match "gradle-$([regex]::Escape($GradleVersion))-bin\.zip" -and $existing -match '(?m)^distributionSha256Sum=[a-fA-F0-9]{64}$') {
        Write-Host "[OK] Gradle Wrapper $GradleVersion already exists and has a pinned checksum."
        exit 0
    }
}

$BootstrapRoot = Join-Path $env:LOCALAPPDATA 'SecretPlay\GradleBootstrap'
New-Item -ItemType Directory -Force -Path $BootstrapRoot | Out-Null
$ZipPath = Join-Path $BootstrapRoot "gradle-$GradleVersion-bin.zip"
$ExtractDir = Join-Path $BootstrapRoot "gradle-$GradleVersion"
$DistributionUrl = "https://services.gradle.org/distributions/gradle-$GradleVersion-bin.zip"
if (-not (Test-Path $WrapperProperties)) { throw 'Pinned gradle-wrapper.properties is missing.' }
$wrapperConfig = Get-Content $WrapperProperties -Raw
if ($wrapperConfig -notmatch '(?m)^distributionSha256Sum=([a-fA-F0-9]{64})$') {
    throw 'gradle-wrapper.properties must contain a reviewed distributionSha256Sum before bootstrap.'
}
$ExpectedHash = $matches[1].ToLowerInvariant()
if ($wrapperConfig -notmatch "gradle-$([regex]::Escape($GradleVersion))-bin\.zip") {
    throw "Pinned wrapper properties do not reference Gradle $GradleVersion. Refusing to bootstrap a different distribution."
}

if (-not (Test-Path $ZipPath)) {
    Write-Host "[i] Downloading the official Gradle $GradleVersion distribution..."
    Invoke-WebRequest -Uri $DistributionUrl -OutFile $ZipPath -UseBasicParsing
}
$ActualHash = (Get-FileHash -Path $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($ActualHash -ne $ExpectedHash) {
    Remove-Item -Force $ZipPath -ErrorAction SilentlyContinue
    throw 'Gradle distribution SHA-256 mismatch. The downloaded archive was deleted.'
}

if (-not (Test-Path (Join-Path $ExtractDir 'bin\gradle.bat'))) {
    if (Test-Path $ExtractDir) { Remove-Item -Recurse -Force $ExtractDir }
    Expand-Archive -Path $ZipPath -DestinationPath $BootstrapRoot -Force
}
$GradleExe = Join-Path $ExtractDir 'bin\gradle.bat'
if (-not (Test-Path $GradleExe)) { throw "Gradle executable not found after extraction: $GradleExe" }

New-Item -ItemType Directory -Force -Path $GradleWrapperDir | Out-Null
Write-Host "[i] Generating Gradle Wrapper $GradleVersion for this Flutter project..."
Push-Location $AndroidDir
try {
    & $GradleExe wrapper --gradle-version $GradleVersion --distribution-type bin
    if ($LASTEXITCODE -ne 0) { throw "Gradle wrapper generation failed with exit code $LASTEXITCODE." }
} finally {
    Pop-Location
}

if (-not (Test-Path $WrapperJar) -or -not (Test-Path $WrapperBat)) {
    throw 'Gradle reported wrapper generation but the wrapper JAR or BAT file is missing.'
}

# Pin the downloaded distribution itself using its official checksum.
$wrapperText = Get-Content $WrapperProperties -Raw
if ($wrapperText -match '(?m)^distributionSha256Sum=') {
    $wrapperText = [regex]::Replace($wrapperText, '(?m)^distributionSha256Sum=.*$', "distributionSha256Sum=$ExpectedHash")
} else {
    $wrapperText = $wrapperText.TrimEnd() + "`r`ndistributionSha256Sum=$ExpectedHash`r`n"
}
Set-Content -Path $WrapperProperties -Value $wrapperText -Encoding ASCII

Write-Host "[OK] Gradle Wrapper $GradleVersion generated and distribution checksum pinned."
Write-Host "     $WrapperBat"
