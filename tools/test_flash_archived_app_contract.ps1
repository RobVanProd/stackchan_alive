$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$testRoot = Join-Path $repoRoot ("output\contract-tests\archived-app-flash-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null

try {
  $firmwarePath = Join-Path $testRoot "firmware.bin"
  $bytes = New-Object byte[] 100001
  $bytes[0] = 0xE9
  for ($i = 1; $i -lt $bytes.Length; $i += 4096) {
    $bytes[$i] = [byte]($i % 251)
  }
  [System.IO.File]::WriteAllBytes($firmwarePath, $bytes)
  $sha256 = (Get-FileHash -LiteralPath $firmwarePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $manifestPath = Join-Path $testRoot "manifest.json"
  [ordered]@{
    schema = "stackchan.firmware-candidate.v1"
    environment = "stackchan_release_forensics"
    firmware_file = "firmware.bin"
    firmware_bytes = $bytes.Length
    firmware_sha256 = $sha256
    deployment_status = "not_installed"
    requires_serial_recovery = $true
  } | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8

  $positive = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
    (Join-Path $PSScriptRoot "flash_archived_app.ps1") `
    -CandidateManifestPath $manifestPath `
    -Port COM4 `
    -ExpectedSha256 $sha256 `
    -ConfirmServoRisk `
    -DryRun 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "Positive archived-app dry run failed: $($positive -join [Environment]::NewLine)"
  }
  $positiveText = $positive -join [Environment]::NewLine
  foreach ($required in @("write_flash", "0xe000", "boot_app0.bin", "0x10000", $sha256)) {
    if ($positiveText -notmatch [regex]::Escape($required)) {
      throw "Positive archived-app dry run is missing: $required"
    }
  }

  $ErrorActionPreference = "Continue"
  $badHash = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
    (Join-Path $PSScriptRoot "flash_archived_app.ps1") `
    -CandidateManifestPath $manifestPath `
    -Port COM4 `
    -ExpectedSha256 ("0" * 64) `
    -ConfirmServoRisk `
    -DryRun 2>&1
  $badHashExit = $LASTEXITCODE
  $ErrorActionPreference = "Stop"
  if ($badHashExit -eq 0 -or (($badHash -join [Environment]::NewLine) -notmatch "ExpectedSha256")) {
    throw "Archived-app flasher did not reject an incorrect expected hash."
  }

  $ErrorActionPreference = "Continue"
  $missingSafety = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
    (Join-Path $PSScriptRoot "flash_archived_app.ps1") `
    -CandidateManifestPath $manifestPath `
    -Port COM4 `
    -ExpectedSha256 $sha256 `
    -DryRun 2>&1
  $missingSafetyExit = $LASTEXITCODE
  $ErrorActionPreference = "Stop"
  if ($missingSafetyExit -eq 0 -or (($missingSafety -join [Environment]::NewLine) -notmatch "ConfirmServoRisk")) {
    throw "Archived-app flasher did not enforce servo-risk confirmation."
  }

  $bytes[0] = 0x00
  [System.IO.File]::WriteAllBytes($firmwarePath, $bytes)
  $badMagicSha = (Get-FileHash -LiteralPath $firmwarePath -Algorithm SHA256).Hash.ToLowerInvariant()
  $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  $manifest.firmware_sha256 = $badMagicSha
  $manifest | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8
  $ErrorActionPreference = "Continue"
  $badMagic = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
    (Join-Path $PSScriptRoot "flash_archived_app.ps1") `
    -CandidateManifestPath $manifestPath `
    -Port COM4 `
    -ExpectedSha256 $badMagicSha `
    -ConfirmServoRisk `
    -DryRun 2>&1
  $badMagicExit = $LASTEXITCODE
  $ErrorActionPreference = "Stop"
  if ($badMagicExit -eq 0 -or (($badMagic -join [Environment]::NewLine) -notmatch "magic byte")) {
    throw "Archived-app flasher did not reject a non-ESP application image."
  }

  Write-Host "Archived application flash contract verified."
} finally {
  Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
