[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$GradleVersion = '9.5.0'
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path $ProjectRoot).Path
$AndroidDir = Join-Path $ProjectRoot 'android_app\android'
if (-not (Test-Path $AndroidDir)) { throw "Android project folder not found: $AndroidDir" }

$SupportedGradleVersion = '9.5.0'
if ($GradleVersion -ne $SupportedGradleVersion) {
    throw "This repository pins Gradle $SupportedGradleVersion. Refusing unsupported version $GradleVersion."
}

$ExpectedDistributionSha256 = '553c78f50dafcd54d65b9a444649057857469edf836431389695608536d6b746'
$ExpectedWrapperJarSha256 = '497c8c2a7e5031f6aa847f88104aa80a93532ec32ee17bdb8d1d2f67a194a9c7'

$FlutterCommand = Get-Command flutter -ErrorAction SilentlyContinue
if (-not $FlutterCommand) { throw 'Flutter was not found on PATH. Install Flutter 3.44+ first.' }
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

$WrapperDir = Join-Path $AndroidDir 'gradle\wrapper'
$WrapperJar = Join-Path $WrapperDir 'gradle-wrapper.jar'
$WrapperBat = Join-Path $AndroidDir 'gradlew.bat'
$WrapperUnix = Join-Path $AndroidDir 'gradlew'
$WrapperProperties = Join-Path $WrapperDir 'gradle-wrapper.properties'
$DistributionUrl = "https://services.gradle.org/distributions/gradle-$GradleVersion-bin.zip"

if ((Test-Path $WrapperJar) -and (Test-Path $WrapperBat) -and (Test-Path $WrapperUnix) -and (Test-Path $WrapperProperties)) {
    $existing = Get-Content $WrapperProperties -Raw
    $existingJarSha256 = (Get-FileHash -Path $WrapperJar -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($existing -match "gradle-$([regex]::Escape($GradleVersion))-bin\.zip" -and
        $existing -match "(?m)^distributionSha256Sum=$ExpectedDistributionSha256\s*$" -and
        $existingJarSha256 -eq $ExpectedWrapperJarSha256) {
        Write-Host "[OK] Gradle Wrapper $GradleVersion already exists and both official checksums match."
        exit 0
    }
}

$BootstrapRoot = Join-Path $env:TEMP 'SecretPlay\GradleBootstrap'
New-Item -ItemType Directory -Force -Path $BootstrapRoot | Out-Null
$ZipPath = Join-Path $BootstrapRoot "gradle-$GradleVersion-bin.zip"
$ExtractDir = Join-Path $BootstrapRoot "gradle-$GradleVersion"

if (-not (Test-Path $ZipPath)) {
    Write-Host "[i] Downloading the official Gradle $GradleVersion distribution..."
    Invoke-WebRequest -Uri $DistributionUrl -OutFile $ZipPath -UseBasicParsing
}
$ActualHash = (Get-FileHash -Path $ZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($ActualHash -ne $ExpectedDistributionSha256) {
    Remove-Item -Force $ZipPath -ErrorAction SilentlyContinue
    throw 'Gradle distribution SHA-256 mismatch. The downloaded archive was deleted.'
}

if (-not (Test-Path (Join-Path $ExtractDir 'bin\gradle.bat'))) {
    if (Test-Path $ExtractDir) { Remove-Item -Recurse -Force $ExtractDir }
    Expand-Archive -Path $ZipPath -DestinationPath $BootstrapRoot -Force
}
$GradleExe = Join-Path $ExtractDir 'bin\gradle.bat'
if (-not (Test-Path $GradleExe)) { throw "Gradle executable not found after extraction: $GradleExe" }

# Generate wrapper files in a temporary, minimal Gradle project. This avoids
# resolving the Android/Flutter plugins just to create the wrapper itself.
$BootstrapProject = Join-Path $BootstrapRoot ("wrapper-bootstrap-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $BootstrapProject | Out-Null
try {
    "rootProject.name = 'secretplay-wrapper-bootstrap'" |
        Set-Content -Path (Join-Path $BootstrapProject 'settings.gradle') -Encoding ASCII
    '' | Set-Content -Path (Join-Path $BootstrapProject 'build.gradle') -Encoding ASCII

    Write-Host "[i] Generating Gradle Wrapper $GradleVersion..."
    Push-Location $BootstrapProject
    try {
        & $GradleExe --no-daemon --console=plain wrapper --gradle-version $GradleVersion --distribution-type bin
        if ($LASTEXITCODE -ne 0) { throw "Gradle wrapper generation failed with exit code $LASTEXITCODE." }
    } finally {
        Pop-Location
    }

    $GeneratedWrapperDir = Join-Path $BootstrapProject 'gradle\wrapper'
    $GeneratedJar = Join-Path $GeneratedWrapperDir 'gradle-wrapper.jar'
    $GeneratedBat = Join-Path $BootstrapProject 'gradlew.bat'
    $GeneratedUnix = Join-Path $BootstrapProject 'gradlew'
    if (-not (Test-Path $GeneratedJar) -or -not (Test-Path $GeneratedBat) -or -not (Test-Path $GeneratedUnix)) {
        throw 'Gradle did not generate all expected wrapper files.'
    }

    $GeneratedJarSha256 = (Get-FileHash -Path $GeneratedJar -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($GeneratedJarSha256 -ne $ExpectedWrapperJarSha256) {
        throw 'Generated Gradle Wrapper JAR SHA-256 did not match the official checksum.'
    }

    New-Item -ItemType Directory -Force -Path $WrapperDir | Out-Null
    Copy-Item -LiteralPath $GeneratedJar -Destination $WrapperJar -Force
    Copy-Item -LiteralPath $GeneratedBat -Destination $WrapperBat -Force
    Copy-Item -LiteralPath $GeneratedUnix -Destination $WrapperUnix -Force

    $WrapperPropertiesText = @"
distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
distributionUrl=https\://services.gradle.org/distributions/gradle-$GradleVersion-bin.zip
distributionSha256Sum=$ExpectedDistributionSha256
networkTimeout=60000
validateDistributionUrl=true
zipStoreBase=GRADLE_USER_HOME
zipStorePath=wrapper/dists
"@
    Set-Content -Path $WrapperProperties -Value $WrapperPropertiesText -Encoding ASCII
} finally {
    if (Test-Path $BootstrapProject) {
        Remove-Item -LiteralPath $BootstrapProject -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$FinalJarSha256 = (Get-FileHash -Path $WrapperJar -Algorithm SHA256).Hash.ToLowerInvariant()
if ($FinalJarSha256 -ne $ExpectedWrapperJarSha256) {
    throw 'Final Gradle Wrapper JAR checksum verification failed.'
}

Write-Host "[OK] Gradle Wrapper $GradleVersion generated and official checksums verified."
Write-Host "     $WrapperBat"
