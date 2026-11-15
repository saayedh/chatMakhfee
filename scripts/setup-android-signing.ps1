[CmdletBinding()]
param([string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path $ProjectRoot).Path
if (-not (Get-Command keytool -ErrorAction SilentlyContinue)) { throw 'keytool was not found. Install JDK 17+ and add its bin directory to PATH.' }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI is required to configure Actions Secrets.' }
& gh auth status 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Authenticate with gh auth login first.' }
$origin = (& git -C $ProjectRoot remote get-url origin 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $origin -notmatch '(?:github\.com[:/])([^/]+/[^/]+?)(?:\.git)?$') { throw 'Configure a GitHub origin first by running github-push.bat.' }
$repo = $matches[1]
$repoInfo = (& gh repo view $repo --json visibility | ConvertFrom-Json)
if ($repoInfo.visibility -ne 'PRIVATE') { throw 'Signing secrets may only be configured for a PRIVATE repository.' }

$signingDir = Join-Path $env:USERPROFILE '.secretplay\signing'
New-Item -ItemType Directory -Path $signingDir -Force | Out-Null
$keystore = Join-Path $signingDir 'secretplay-upload.jks'
if (Test-Path $keystore) { throw "Keystore already exists: $keystore. Never overwrite an existing release key." }
$alias = Read-Host 'Key alias (default: secretplay-upload)'
if ([string]::IsNullOrWhiteSpace($alias)) { $alias = 'secretplay-upload' }
$storeSecure = Read-Host 'Create a strong keystore password' -AsSecureString
$keySecure = Read-Host 'Create a strong key password (may be the same, but do not use a weak password)' -AsSecureString
if ($storeSecure.Length -lt 16 -or $keySecure.Length -lt 16) { throw 'Use passwords of at least 16 characters.' }
$bstrStore = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($storeSecure)
$bstrKey = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($keySecure)
$storePassword = $null; $keyPassword = $null
try {
    $storePassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstrStore)
    $keyPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstrKey)
    $env:SECRETPLAY_STORE_TMP = $storePassword
    $env:SECRETPLAY_KEY_TMP = $keyPassword
    & keytool -genkeypair -v -keystore $keystore -storetype JKS -storepass:env SECRETPLAY_STORE_TMP -keypass:env SECRETPLAY_KEY_TMP -alias $alias -keyalg RSA -keysize 3072 -validity 10000 -dname 'CN=SecretPlay Android Upload, OU=Release, O=SecretPlay, C=DE'
    if ($LASTEXITCODE -ne 0) { throw 'keytool failed to create the upload keystore.' }

    $bytes = [IO.File]::ReadAllBytes($keystore)
    $base64 = [Convert]::ToBase64String($bytes)
    $secretMap = @{
        ANDROID_KEYSTORE_BASE64 = $base64
        ANDROID_KEYSTORE_PASSWORD = $storePassword
        ANDROID_KEY_ALIAS = $alias
        ANDROID_KEY_PASSWORD = $keyPassword
    }
    foreach ($name in $secretMap.Keys) {
        Write-Host "Uploading Actions Secret name: $name"
        # Write the exact value to gh stdin without adding a newline. In
        # particular, a trailing newline would corrupt Android passwords.
        $ghCommand = (Get-Command gh -ErrorAction Stop).Source
        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = New-Object System.Diagnostics.ProcessStartInfo
        $process.StartInfo.FileName = $ghCommand
        $process.StartInfo.Arguments = "secret set $name --repo $repo"
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.RedirectStandardInput = $true
        $process.StartInfo.CreateNoWindow = $true
        if (-not $process.Start()) { throw "Could not start GitHub CLI for secret $name." }
        $process.StandardInput.Write([string]$secretMap[$name])
        $process.StandardInput.Close()
        $process.WaitForExit()
        $secretExitCode = $process.ExitCode
        $process.Dispose()
        if ($secretExitCode -ne 0) { throw "Failed to configure GitHub Actions Secret $name (exit $secretExitCode)." }
    }
    Write-Host '[OK] Upload signing key created and GitHub Actions secrets configured.' -ForegroundColor Green
    Write-Host "Local keystore: $keystore"
    Write-Host 'Back up this keystore and its passwords offline in a secure place. Never commit it or include it in the source ZIP.'
    Write-Host 'GitHub Actions Secrets configured for repository:' $repo
} finally {
    Remove-Item Env:SECRETPLAY_STORE_TMP -ErrorAction SilentlyContinue
    Remove-Item Env:SECRETPLAY_KEY_TMP -ErrorAction SilentlyContinue
    if ($bstrStore -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrStore) }
    if ($bstrKey -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstrKey) }
    $storePassword = $null; $keyPassword = $null; $base64 = $null; $bytes = $null; $secretMap = $null
}
