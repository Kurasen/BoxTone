[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (& git rev-parse --show-toplevel).Trim()
if (-not $repoRoot) {
  throw 'Not inside a Git repository.'
}
Set-Location $repoRoot

$stagedFiles = @(& git diff --cached --name-only --diff-filter=ACMR)
if ($stagedFiles.Count -eq 0) {
  exit 0
}

$violations = New-Object System.Collections.Generic.List[string]
$blockedPathPatterns = @(
  '(?i)(^|/)\.env($|\.)',
  '(?i)(^|/)signing/',
  '(?i)\.(p12|jks|keystore|cer|p7b|csr|pem)$',
  '(?i)(^|/)keystore-password\.txt$',
  '(?i)(^|/)server\.zip$',
  '(?i)(^|/)local\.properties$'
)

$configExtensions = @('.env', '.json', '.json5', '.yaml', '.yml', '.properties', '.toml', '.ini')
$placeholderPattern = '(?i)^(change-me|your-|example|placeholder|xxx|dummy|<.*>|\$\{.*\})$'

foreach ($file in $stagedFiles) {
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

  $contentLines = @(& git show ":$file" 2>$null)
  if ($LASTEXITCODE -ne 0 -or $contentLines.Count -eq 0) {
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

  $extension = [IO.Path]::GetExtension($normalized).ToLowerInvariant()
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
  Write-Host 'Pre-commit secret check failed:' -ForegroundColor Red
  $violations | Sort-Object -Unique | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
  Write-Host ''
  Write-Host 'Remove the file/value from the index, or rotate the credential if it was ever pushed.' -ForegroundColor Yellow
  exit 1
}

Write-Host "Pre-commit secret check passed ($($stagedFiles.Count) staged files)." -ForegroundColor Green
exit 0
