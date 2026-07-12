$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. (Join-Path $PSScriptRoot "platformio_resolver.ps1")

$python = (Get-Command python -ErrorAction Stop).Source
$script = @'
import os
import sys

assert os.environ.get("PYTHONUTF8") == "1"
assert os.environ.get("PYTHONIOENCODING") == "utf-8"
assert sys.stdout.encoding.lower().replace("-", "") == "utf8"
print("esptool progress: \u2588\u2591")
'@

$tempScript = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-utf8-" + [guid]::NewGuid().ToString("N") + ".py")
try {
  Set-Content -LiteralPath $tempScript -Value $script -Encoding UTF8
  $output = @(Invoke-StackchanUtf8Process -Command $python -Arguments @($tempScript))
  if ($LASTEXITCODE -ne 0) {
    throw "UTF-8 subprocess contract exited with code $LASTEXITCODE."
  }
} finally {
  Remove-Item -LiteralPath $tempScript -Force -ErrorAction SilentlyContinue
}
$text = $output -join [Environment]::NewLine
if ($text -notmatch "esptool progress:.*\u2588\u2591") {
  throw "UTF-8 subprocess contract did not preserve esptool progress characters."
}

$failureScript = @'
import sys
sys.exit(7)
'@
$tempFailureScript = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-utf8-fail-" + [guid]::NewGuid().ToString("N") + ".py")
try {
  Set-Content -LiteralPath $tempFailureScript -Value $failureScript -Encoding UTF8
  $failureRaised = $false
  try {
    Invoke-StackchanUtf8Process -Command $python -Arguments @($tempFailureScript)
  } catch {
    $failureRaised = $_.Exception.Message -match "exit code 7"
  }
  if (-not $failureRaised) {
    throw "UTF-8 subprocess wrapper did not propagate a failing native exit code."
  }
} finally {
  Remove-Item -LiteralPath $tempFailureScript -Force -ErrorAction SilentlyContinue
}

$resolverText = Get-Content -LiteralPath "tools\platformio_resolver.ps1" -Raw
foreach ($required in @("PYTHONIOENCODING", "PYTHONUTF8", "Console]::OutputEncoding", "Invoke-StackchanUtf8Process", "processExitCode")) {
  if ($resolverText -notmatch [regex]::Escape($required)) {
    throw "Shared PlatformIO resolver is missing UTF-8 guard: $required"
  }
}

$platformioText = Get-Content -LiteralPath "platformio.ini" -Raw
if ($platformioText -notmatch '(?ms)\[env:stackchan_release_forensics\].*?upload_speed\s*=\s*460800') {
  throw "Release-forensics environment must retain the conservative 460800 upload speed."
}

$packageText = Get-Content -LiteralPath "tools\package_release.ps1" -Raw
if ($packageText -match 'run\s+-e\s+stackchan\s+-e\s+stackchan_servo_calibration') {
  throw "Release packaging must not mix legacy and pioarduino environments in one PlatformIO process."
}
foreach ($environment in @("stackchan", "stackchan_servo_calibration", "stackchan_release_full")) {
  if ($packageText -notmatch [regex]::Escape($environment)) {
    throw "Release packaging is missing firmware environment: $environment"
  }
}
foreach ($required in @("firmware-build-cache", "Copy-BuildArtifacts", 'Join-Path $builtFirmwareCache $environment')) {
  if (-not $packageText.Contains($required)) {
    throw "Release packaging is missing mixed-toolchain artifact preservation: $required"
  }
}
foreach ($required in @("PLATFORMIO_CORE_DIR", "Get-ReleasePlatformioCoreDir", '"pioarduino"', "releaseLegacyPlatformioCore", '"spio"')) {
  if (-not $packageText.Contains($required)) {
    throw "Release packaging is missing mixed-toolchain package isolation: $required"
  }
}
if (-not $packageText.Contains('GetPathRoot($env:SystemRoot)')) {
  throw "Release packaging must anchor the short pioarduino core to the physical Windows system drive."
}
$staleCacheCleanupIndex = $packageText.IndexOf('Get-ChildItem -LiteralPath $releaseOutputRoot')
$currentCacheCreateIndex = $packageText.IndexOf('$builtFirmwareCache = Join-Path')
if ($staleCacheCleanupIndex -lt 0 -or $currentCacheCreateIndex -lt 0 -or $staleCacheCleanupIndex -gt $currentCacheCreateIndex) {
  throw "Release packaging must remove stale firmware caches before creating the current build cache."
}

$releaseVerifierText = Get-Content -LiteralPath "tools\verify_release_package.ps1" -Raw
foreach ($required in @(
  'pioarduino/platform-espressif32@55.03.36',
  '^55\.3\.36\+sha\.aa6e97c$',
  '^3\.3\.6$',
  'toolchain-xtensa-esp-elf',
  'knownFullOnlineM5Gfx',
  '0.2.24',
  '0.2.25'
)) {
  if (-not $releaseVerifierText.Contains($required)) {
    throw "Release verifier is missing mixed-toolchain lock coverage: $required"
  }
}
foreach ($required in @(
  'verify_release_package.ps1',
  'package-verify.log',
  'AllowDirtyPackage',
  'Release ZIP verification failed'
)) {
  if (-not $packageText.Contains($required)) {
    throw "Release packaging is missing mandatory post-build package verification: $required"
  }
}

foreach ($required in @(
  'third_party_licenses',
  'THIRD_PARTY_NOTICES.md',
  'Copy-LicenseEvidenceTree',
  'Copy-EnvironmentLicenseEvidence',
  'thirdPartyLicenseIndex',
  'bridge/models/LICENSE'
)) {
  if (-not $packageText.Contains($required)) {
    throw "Release packaging is missing third-party license evidence: $required"
  }
}
foreach ($required in @(
  'Third-party license index hash mismatch',
  'requiredThirdPartyPatterns',
  'LGPL-2.1-or-later',
  'models/opencv-zoo-yunet/LICENSE'
)) {
  if (-not $releaseVerifierText.Contains($required)) {
    throw "Release verifier is missing third-party license coverage: $required"
  }
}

foreach ($required in @(
  'VoiceSourceProvenanceDisplayPath',
  'TemplateDisplayPath',
  'data/voice_source_provenance.yaml',
  'docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md'
)) {
  if (-not $packageText.Contains($required) -and -not $releaseVerifierText.Contains($required)) {
    throw "Release package is missing portable voice-status path coverage: $required"
  }
}

$otaScript = Get-Content -LiteralPath "tools\platformio_apply_ota_env.py" -Raw
foreach ($required in @(
  'os.environ["PYTHONIOENCODING"] = "utf-8"',
  'os.environ["PYTHONUTF8"] = "1"',
  '"stackchan_release_forensics"',
  '"stackchan_camera_probe"',
  "requires STACKCHAN_OTA_TOKEN"
)) {
  if (-not $otaScript.Contains($required)) {
    throw "OTA production build guard is missing: $required"
  }
}

Write-Host "PlatformIO/esptool UTF-8 contract verified."
