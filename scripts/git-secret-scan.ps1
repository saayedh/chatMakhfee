[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ProjectRoot = (Split-Path -Parent $PSScriptRoot),
    [switch]$StagedOnly
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path $ProjectRoot).Path
$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) { throw 'Git is not installed or not on PATH.' }

if ($StagedOnly) {
    $paths = & git -C $ProjectRoot diff --cached --name-only
} else {
    $paths = Get-ChildItem -LiteralPath $ProjectRoot -File -Recurse -Force |
        Where-Object {
            $_.FullName -notmatch '[\\/]\.git[\\/]' -and
            $_.FullName -notmatch '[\\/]node_modules[\\/]' -and
            $_.FullName -notmatch '[\\/]build[\\/]' -and
            $_.FullName -notmatch '[\\/]\.dart_tool[\\/]' -and
            $_.FullName -notmatch '[\\/]\.gradle[\\/]' -and
            $_.FullName -notmatch '[\\/]\.wrangler[\\/]' -and
            $_.FullName -notmatch '[\\/]artifacts[\\/]'
        } | ForEach-Object { $_.FullName.Substring($ProjectRoot.Length + 1) }
}

$blocked = New-Object System.Collections.Generic.List[string]
$secretPatterns = @(
    @{ Name = 'PEM private key'; Pattern = ('-----BEGIN ' + '(?:(?:RSA|EC|OPENSSH|DSA) )?(?:ENCRYPTED )?PRIVATE KEY-----') },
    @{ Name = 'PGP private key'; Pattern = ('-----BEGIN ' + 'PGP PRIVATE KEY BLOCK-----') },
    @{ Name = 'GitHub token'; Pattern = '\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,})\b' },
    @{ Name = 'AWS access key'; Pattern = '\bAKIA[0-9A-Z]{16}\b' },
    @{ Name = 'Cloudflare API token assignment'; Pattern = '(?i)CLOUDFLARE_API_TOKEN\s*=\s*(?!\$\{|\$env:|YOUR_|CHANGEME|REPLACE_ME|<)[A-Za-z0-9_-]{20,}' },
    @{ Name = 'npm registry credential'; Pattern = '(?i)(?:_authToken|_password)\s*=\s*(?!\$\{|\$env:|\$|YOUR_|CHANGEME|REPLACE_ME|<)[^\s#]{12,}' }
)

foreach ($relative in $paths) {
    if ([string]::IsNullOrWhiteSpace($relative)) { continue }
    $normalized = $relative.Replace('/', '\')
    $name = [IO.Path]::GetFileName($normalized)
    $full = Join-Path $ProjectRoot $relative

    if (($name -match '^(?:\.env(?:\..+)?|key\.properties|local\.properties|\.dev\.vars)$' -and $name -ne '.env.example') -or $name -eq '.npmrc') {
        $blocked.Add("$relative (environment or local credential file)")
        continue
    }
    if ($name -match '(?i)\.(?:jks|keystore|p12|pfx|p7b|p7c|key|pem|p8|asc|gpg|mobileprovision|provisionprofile)$') {
        $blocked.Add("$relative (signing/certificate container)")
        continue
    }
    if ($normalized -match '(?i)(?:^|\\)(?:secrets|private_keys|recovery_exports)(?:\\|$)') {
        $blocked.Add("$relative (sensitive directory)")
        continue
    }

    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    $item = Get-Item -LiteralPath $full
    if ($item.Length -gt 5MB) { continue }
    try {
        $bytes = [IO.File]::ReadAllBytes($full)
        if ($bytes -contains 0) { continue }
        $content = [Text.Encoding]::UTF8.GetString($bytes)
    } catch { continue }

    foreach ($rule in $secretPatterns) {
        if ($content -match $rule.Pattern) {
            $blocked.Add("$relative ($($rule.Name))")
            break
        }
    }
}

if ($blocked.Count -gt 0) {
    Write-Host '[BLOCKED] Potential secret material was found. No push should be performed.' -ForegroundColor Red
    $blocked | Sort-Object -Unique | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    return $false
}

Write-Host '[OK] Secret scan found no blocked secret files or known token patterns.' -ForegroundColor Green
return $true
