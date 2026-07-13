$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$uploaderPath = Join-Path $PSScriptRoot "upload_lan_ota.ps1"
$validatorPath = Join-Path $repoRoot "bridge\ota_channels.py"

$tokens = $null
$parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile(
  $uploaderPath,
  [ref]$tokens,
  [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
  throw "LAN OTA uploader has PowerShell parse errors: $($parseErrors.Message -join '; ')"
}

$uploader = Get-Content -LiteralPath $uploaderPath -Raw
foreach ($fragment in @(
  '[ValidateSet("", "stable", "beta")]',
  '[string]$ChannelManifest',
  'Channel and ChannelManifest must be supplied together.',
  'bridge\ota_channels.py',
  '--channel $Channel',
  '--firmware $firmwarePath',
  'channel_source_commit'
)) {
  if (-not $uploader.Contains($fragment)) {
    throw "LAN OTA channel contract missing fragment: $fragment"
  }
}

$python = Get-Command python -ErrorAction Stop
& $python.Source -m unittest discover -s (Join-Path $repoRoot "bridge") -p "test_ota_channels.py"
if ($LASTEXITCODE -ne 0) {
  throw "OTA channel Python contract tests failed."
}

Write-Output "LAN OTA stable/beta channel contract verified."
