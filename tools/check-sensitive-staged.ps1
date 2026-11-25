[CmdletBinding()]
param(
  # Scan every tracked file (used by CI). Default: staged files only (pre-commit).
  [switch]$All
)

$ErrorActionPreference = 'Stop'

# With core.quotepath=false git prints non-ASCII paths as raw UTF-8.
# Windows PowerShell decodes native output with the OEM code page (e.g. GBK)
# by default, which would garble those paths, so force UTF-8 both ways.
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

$repoRoot = (& git rev-parse --show-toplevel).Trim()
if (-not $repoRoot) {
  throw 'Not inside a Git repository.'
}
Set-Location $repoRoot

if ($All) {
  $scope = 'tracked'
  $files = @(& git -c core.quotepath=false ls-files)
  if ($files.Count -eq 0) {
    # A clean checkout always has tracked files; an empty list means the scan
    # itself is broken, so fail instead of silently passing.
    Write-Host 'Secret check failed: git ls-files returned no files.' -ForegroundColor Red
    exit 1
  }
} else {
  $scope = 'staged'
  $files = @(& git -c core.quotepath=false diff --cached --name-only --diff-filter=ACMR)
  if ($files.Count -eq 0) {
    exit 0
  }
}

$violations = New-Object System.Collections.Generic.List[string]
$blockedPathPatterns = @(
  '(?i)(^|/)\.env($|\.)',
  '(?i)(^|/)signing/',
  '(?i)\.(p12|jks|keystore|cer|p7b|csr|pem)$',
  '(?i)(^|/)keystore-password\.txt$',
  '(?i)(^|/)debug-password\.txt$',
  '(?i)(^|/)server\.zip$',
  '(?i)(^|/)local\.properties$'
)

$configExtensions = @('.env', '.json', '.json5', '.yaml', '.yml', '.properties', '.toml', '.ini')
# Binary assets: path rules still apply, content scan is skipped (slow and meaningless).
$binaryExtensions = @('.png', '.jpg', '.jpeg', '.gif', '.webp', '.ico', '.wav', '.mp3', '.m4a', '.flac', '.ogg', '.pcm', '.raw', '.so', '.har', '.hap', '.zip')
$placeholderPattern = '(?i)^(change-me|your-|example|placeholder|xxx|dummy|<.*>|\$\{.*\})'

foreach ($file in $files) {
  $normalized = $file -replace '\\', '/'

  if ($normalized -eq 'server/.env.example') {
    continue
  }

  foreach ($pattern in $blockedPathPatterns) {
    if ($normalized -match $pattern) {
      $violations.Add("Blocked sensitive filename/path: $normalized")
      break
    }
  }

  $extension = [IO.Path]::GetExtension($normalized).ToLowerInvariant()
  if ($binaryExtensions -contains $extension) {
    continue
  }

  # Read the index copy (what is actually committed). Stderr from a native
  # command must not become a terminating error under 'Stop'.
  $previousPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $contentLines = @(& git show ":$file" 2>$null)
  $showExit = $LASTEXITCODE
  $ErrorActionPreference = $previousPreference
  if ($showExit -ne 0 -or $contentLines.Count -eq 0) {
    continue
  }
  $content = $contentLines -join "`n"

  if ($content -match '-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----') {
    $violations.Add("Private key material detected: $normalized")
  }
  if ($content -match 'AKIA[0-9A-Z]{16}') {
    $violations.Add("Possible AWS access key detected: $normalized")
  }
  if ($content -match 'gh[pousr]_[A-Za-z0-9]{30,}') {
    $violations.Add("Possible GitHub token detected: $normalized")
  }
  if ($content -match 'AIza[0-9A-Za-z_-]{35}') {
    $violations.Add("Possible Google API key detected: $normalized")
  }
  if ($content -match 'xox[baprs]-[A-Za-z0-9-]{20,}') {
    $violations.Add("Possible Slack token detected: $normalized")
  }

  if ($configExtensions -contains $extension) {
    foreach ($line in ($content -split "`n")) {
      if ($line -match '(?i)^\s*(password|passwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|smtp[_-]?pass)\s*[:=]\s*[''"]?([^''"\s#]+)') {
        $value = $Matches[2]
        if ($value.Length -ge 12 -and $value -notmatch $placeholderPattern) {
          $violations.Add("Possible secret value in config: $normalized")
          break
        }
      }
    }
  }
}

if ($violations.Count -gt 0) {
  Write-Host ''
  Write-Host "Secret check failed ($scope files):" -ForegroundColor Red
  $violations | Sort-Object -Unique | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
  Write-Host ''
  Write-Host 'Remove the file/value from the index, or rotate the credential if it was ever pushed.' -ForegroundColor Yellow
  exit 1
}

Write-Host "Secret check passed ($($files.Count) $scope files)." -ForegroundColor Green
exit 0
