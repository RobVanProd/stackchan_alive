$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. (Join-Path $PSScriptRoot "platformio_resolver.ps1")

$python = (Get-Command python -ErrorAction Stop).Source
$script = @'
import os
import sys
import time
from pathlib import Path

assert os.environ.get("PYTHONUTF8") == "1"
assert os.environ.get("PYTHONIOENCODING") == "utf-8"
assert sys.stdout.encoding.lower().replace("-", "") == "utf8"
print("stderr-before-success", file=sys.stderr, flush=True)
time.sleep(0.25)
Path(sys.argv[1]).write_text("success-child-complete", encoding="utf-8")
print("stderr-after-success", file=sys.stderr, flush=True)
print("esptool progress: \u2588\u2591")
'@

$tempScript = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-utf8-" + [guid]::NewGuid().ToString("N") + ".py")
$successSentinel = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-utf8-success-" + [guid]::NewGuid().ToString("N") + ".txt")
try {
  Set-Content -LiteralPath $tempScript -Value $script -Encoding UTF8
  $successTimer = [Diagnostics.Stopwatch]::StartNew()
  $output = @(Invoke-StackchanUtf8Process -Command $python `
      -Arguments @($tempScript, $successSentinel) 2>&1)
  $successTimer.Stop()
  if ($LASTEXITCODE -ne 0) {
    throw "UTF-8 subprocess contract exited with code $LASTEXITCODE."
  }
  if ($ErrorActionPreference -cne 'Stop') {
    throw 'UTF-8 subprocess wrapper did not restore the caller error-action policy after success.'
  }
  if (-not (Test-Path -LiteralPath $successSentinel -PathType Leaf) -or
      (Get-Content -LiteralPath $successSentinel -Raw) -cne 'success-child-complete' -or
      $successTimer.ElapsedMilliseconds -lt 150) {
    throw "UTF-8 subprocess wrapper returned before the stderr-producing native child completed."
  }
} finally {
  Remove-Item -LiteralPath $tempScript,$successSentinel -Force -ErrorAction SilentlyContinue
}
$text = $output -join [Environment]::NewLine
foreach ($expectedLine in @('stderr-before-success', 'stderr-after-success', "esptool progress: $([char]0x2588)$([char]0x2591)")) {
  if (-not $text.Contains($expectedLine)) {
    throw "UTF-8 subprocess contract lost native output: $expectedLine"
  }
}

$failureScript = @'
import sys
import time
from pathlib import Path

print("stderr-before-failure", file=sys.stderr, flush=True)
time.sleep(0.25)
Path(sys.argv[1]).write_text("failure-child-complete", encoding="utf-8")
print("stderr-after-failure", file=sys.stderr, flush=True)
sys.exit(7)
'@
$tempFailureScript = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-utf8-fail-" + [guid]::NewGuid().ToString("N") + ".py")
$failureSentinel = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-utf8-fail-" + [guid]::NewGuid().ToString("N") + ".txt")
try {
  Set-Content -LiteralPath $tempFailureScript -Value $failureScript -Encoding UTF8
  $failureRaised = $false
  $failureLines = [Collections.Generic.List[string]]::new()
  $failureTimer = [Diagnostics.Stopwatch]::StartNew()
  try {
    Invoke-StackchanUtf8Process -Command $python `
      -Arguments @($tempFailureScript, $failureSentinel) 2>&1 | ForEach-Object {
        $failureLines.Add([string]$_) | Out-Null
      }
  } catch {
    $failureLines.Add([string]$_) | Out-Null
    $failureRaised = $_.Exception.Message -match "exit code 7"
  } finally {
    $failureTimer.Stop()
  }
  if (-not $failureRaised) {
    throw "UTF-8 subprocess wrapper did not propagate a failing native exit code."
  }
  if ($ErrorActionPreference -cne 'Stop') {
    throw 'UTF-8 subprocess wrapper did not restore the caller error-action policy after failure.'
  }
  if (-not (Test-Path -LiteralPath $failureSentinel -PathType Leaf) -or
      (Get-Content -LiteralPath $failureSentinel -Raw) -cne 'failure-child-complete' -or
      $failureTimer.ElapsedMilliseconds -lt 150) {
    throw "UTF-8 subprocess wrapper classified failure before the native child completed."
  }
  $failureText = $failureLines -join [Environment]::NewLine
  foreach ($expectedLine in @('stderr-before-failure', 'stderr-after-failure')) {
    if (-not $failureText.Contains($expectedLine)) {
      throw "UTF-8 subprocess failure path lost native diagnostics: $expectedLine"
    }
  }
} finally {
  Remove-Item -LiteralPath $tempFailureScript,$failureSentinel -Force -ErrorAction SilentlyContinue
}

$missingLines = [Collections.Generic.List[string]]::new()
$missingRaised = $false
$missingCommand = Join-Path ([System.IO.Path]::GetTempPath()) (
  'stackchan-definitely-missing-' + [guid]::NewGuid().ToString('N') + '.exe')
try {
  Invoke-StackchanUtf8Process -Command $missingCommand 2>&1 | ForEach-Object {
    $missingLines.Add([string]$_) | Out-Null
  }
} catch {
  $missingLines.Add([string]$_) | Out-Null
  $missingRaised = $_.Exception.Message -match 'did not start its resolved native executable'
}
if (-not $missingRaised -or $ErrorActionPreference -cne 'Stop') {
  throw 'UTF-8 subprocess wrapper did not fail closed on a missing native executable.'
}

$resolverText = Get-Content -LiteralPath "tools\platformio_resolver.ps1" -Raw
foreach ($required in @(
    "PYTHONIOENCODING", "PYTHONUTF8", "Console]::OutputEncoding",
    "Invoke-StackchanUtf8Process", "processExitCode", "nativeExitSentinel",
    '$ErrorActionPreference = "Continue"')) {
  if ($resolverText -notmatch [regex]::Escape($required)) {
    throw "Shared PlatformIO resolver is missing UTF-8 guard: $required"
  }
}

$platformioText = Get-Content -LiteralPath "platformio.ini" -Raw
if ($platformioText -notmatch '(?ms)\[env:stackchan_release_forensics\].*?upload_speed\s*=\s*460800') {
  throw "Release-forensics environment must retain the conservative 460800 upload speed."
}

$packageText = Get-Content -LiteralPath "tools\package_release.ps1" -Raw
$failureHelperText = Get-Content -LiteralPath "tools\firmware_reproducibility_failure.ps1" -Raw
$failureGovernanceText = $packageText + "`n" + $failureHelperText
if ($packageText -match 'run\s+-e\s+stackchan\s+-e\s+stackchan_servo_calibration') {
  throw "Release packaging must not mix legacy and pioarduino environments in one PlatformIO process."
}
foreach ($environment in @("stackchan", "stackchan_servo_calibration", "stackchan_release_full")) {
  if ($packageText -notmatch [regex]::Escape($environment)) {
    throw "Release packaging is missing firmware environment: $environment"
  }
}
foreach ($required in @("firmware-build-cache", "Copy-BuildArtifacts", '$firmwareSourceRoot', 'cycle-b')) {
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
foreach ($required in @("[guid]::NewGuid()", "output/private/reproducibility-failures", "failed-full-worktree-preserved", 'Move-Item -LiteralPath $BuildCacheRoot')) {
  if (-not $failureGovernanceText.Contains($required)) {
    throw "Release packaging must preserve failed reproducibility artifacts without colliding with another run: $required"
  }
}
if ($packageText.Contains('.firmware-build-cache-*')) {
  throw "Release packaging must not wildcard-delete prior or concurrent firmware build evidence."
}

$releaseVerifierText = Get-Content -LiteralPath "tools\verify_release_package.ps1" -Raw
foreach ($required in @(
  'pioarduino/platform-espressif32@55.03.36',
  '^55\.3\.36\+sha\.aa6e97c$',
  '^3\.3\.6$',
  'toolchain-xtensa-esp-elf',
  'M5Stack/M5GFX@0.2.24',
  'Assert-StackchanSingleResolvedPackageVersion',
  '-Name "M5GFX" -ExpectedVersion "0.2.24"',
  '-Name "M5Unified" -ExpectedVersion "0.2.17"'
)) {
  if (-not $releaseVerifierText.Contains($required)) {
    throw "Release verifier is missing mixed-toolchain lock coverage: $required"
  }
}
if ($releaseVerifierText.Contains('knownPinnedM5GfxWithTransitiveCopy') -or
    $releaseVerifierText.Contains('$duplicateVersions[1] -eq "0.2.26"')) {
  throw 'Release verifier still permits the rejected duplicate M5GFX resolution.'
}
foreach ($required in @(
  'verify_release_package.ps1',
  'package-verify.log',
  'AllowDirtyPackage',
  'Package ZIP verification failed'
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
