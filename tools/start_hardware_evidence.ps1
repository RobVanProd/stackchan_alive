param(
  [string]$ReleaseTag = "",
  [string]$PackageZip = "",
  [string]$Port = "",
  [string]$Operator = "",
  [string]$DeviceId = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

if ([string]::IsNullOrWhiteSpace($ReleaseTag)) {
  $ReleaseTag = (git describe --tags --always --dirty).Trim()
}

$commit = (git rev-parse HEAD).Trim()
$branch = (git rev-parse --abbrev-ref HEAD).Trim()
$createdUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$safeTag = $ReleaseTag -replace '[^A-Za-z0-9_.-]', '_'
$outDir = Join-Path $repoRoot "output/hardware-evidence/$safeTag-$stamp"

$logsDir = Join-Path $outDir "logs"
$photosDir = Join-Path $outDir "photos"
$calibrationDir = Join-Path $outDir "calibration"
$packageDir = Join-Path $outDir "package"
New-Item -ItemType Directory -Force -Path $logsDir, $photosDir, $calibrationDir, $packageDir | Out-Null

$packageInfo = $null
$requiredLogs = @(
  "logs/display_only_serial.log",
  "logs/servo_calibration_serial.log",
  "logs/soak_serial.log"
)
if (-not [string]::IsNullOrWhiteSpace($PackageZip)) {
  if (-not (Test-Path -LiteralPath $PackageZip)) {
    throw "Missing package ZIP: $PackageZip"
  }
  $packageItem = Get-Item -LiteralPath $PackageZip
  $packageHash = Get-FileHash -Algorithm SHA256 -LiteralPath $packageItem.FullName
  Copy-Item -LiteralPath $packageItem.FullName -Destination $packageDir
  $packageInfo = [ordered]@{
    sourcePath = $packageItem.FullName
    copiedFile = "package/$($packageItem.Name)"
    sha256 = $packageHash.Hash.ToLowerInvariant()
    sizeBytes = $packageItem.Length
  }

  $packageVerifyLog = Join-Path $logsDir "package_verify.log"
  $verifyArgs = @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    (Join-Path $PSScriptRoot "verify_release_package.ps1"),
    "-Version",
    $ReleaseTag,
    "-ZipPath",
    $packageItem.FullName,
    "-ExpectedCommit",
    $commit
  )
  $verifyOutput = & powershell.exe @verifyArgs 2>&1
  $verifyExitCode = $LASTEXITCODE
  $verifyOutput | Set-Content -Path $packageVerifyLog -Encoding UTF8
  if ($verifyExitCode -ne 0) {
    throw "Release package verification failed while creating evidence packet. See $packageVerifyLog"
  }
  $requiredLogs = @("logs/package_verify.log") + $requiredLogs
}

Copy-Item -LiteralPath "docs/ROLLOUT_CHECKLIST.md" -Destination (Join-Path $outDir "CHECKLIST.md")
Copy-Item -LiteralPath "docs/DEVICE_BRINGUP.md" -Destination (Join-Path $outDir "DEVICE_BRINGUP.md")
Copy-Item -LiteralPath "docs/PRODUCTION_READINESS.md" -Destination (Join-Path $outDir "PRODUCTION_READINESS.md")
Copy-Item -LiteralPath "data/calibration.yaml" -Destination (Join-Path $calibrationDir "calibration.yaml")

$observations = @(
  "# Hardware Test Observations",
  "",
  "Release tag: $ReleaseTag",
  "Commit: $commit",
  "Created UTC: $createdUtc",
  "Device ID: $DeviceId",
  "Port: $Port",
  "Operator: $Operator",
  "",
  "## Display-Only Flash",
  "",
  "- Start UTC:",
  "- End UTC:",
  "- Command:",
  "- Result:",
  "- Reset loop observed:",
  "- Procedural face visible:",
  "- Dry-run servo log observed:",
  "- Notes:",
  "",
  "## Servo Calibration Flash",
  "",
  "- Start UTC:",
  "- End UTC:",
  "- Command:",
  "- Result:",
  "- Pitch behavior:",
  "- Yaw classification: angle / velocity / disabled",
  "- Heat or brownout observed:",
  "- Calibration changes:",
  "- Notes:",
  "",
  "## Soak Test",
  "",
  "- Start UTC:",
  "- End UTC:",
  "- Duration:",
  "- Reset, stall, jitter, or heat observed:",
  "- USB power-cycle recovery:",
  "- Notes:",
  "",
  "## Attachments",
  "",
  "- Display serial log: logs/display_only_serial.log",
  "- Servo serial log: logs/servo_calibration_serial.log",
  "- Soak serial log: logs/soak_serial.log",
  "- Package verification log: logs/package_verify.log",
  "- Photos/videos: photos/",
  "- Calibration record: calibration/calibration.yaml"
)
$observations | Set-Content -Path (Join-Path $outDir "OBSERVATIONS.md") -Encoding UTF8

$portArg = ""
if (-not [string]::IsNullOrWhiteSpace($Port)) {
  $portArg = " -Port $Port"
}

$packageFlashZip = "<path-to-release-zip>"
if ($packageInfo) {
  $packageFlashZip = Join-Path $packageDir ([System.IO.Path]::GetFileName($packageInfo["sourcePath"]))
}
$packageFlashArg = " -PackageZip `"$packageFlashZip`""

$displayCommand = ".\tools\flash_release_firmware.ps1$packageFlashArg -Firmware display_only$portArg -Monitor 2>&1 | Tee-Object -FilePath `"$logsDir\display_only_serial.log`""
$servoCommand = ".\tools\flash_release_firmware.ps1$packageFlashArg -Firmware servo_calibration$portArg -Monitor -ConfirmServoRisk 2>&1 | Tee-Object -FilePath `"$logsDir\servo_calibration_serial.log`""
$verifyCommand = ".\tools\verify_release_package.ps1 -Version $ReleaseTag -ZipPath `"$packageFlashZip`" -ExpectedCommit $commit"

$readme = @(
  "# Stackchan Hardware Evidence Packet",
  "",
  "Use this folder as the record for one device bring-up session. Complete CHECKLIST.md and OBSERVATIONS.md, save serial logs under logs/, and place photos or short videos under photos/.",
  "",
  "## Suggested Commands",
  "",
  "Display-only flash:",
  "",
  "    $displayCommand",
  "",
  "Servo calibration flash:",
  "",
  "    $servoCommand",
  "",
  "Before promotion, verify the release ZIP:",
  "",
  "    $verifyCommand",
  "",
  "The packet creation command automatically writes ``logs/package_verify.log`` when ``-PackageZip`` is provided.",
  "",
  "Before marking a release hardware-validated, verify this evidence packet:",
  "",
  "    .\tools\verify_hardware_evidence.ps1 -EvidenceRoot `"$outDir`"",
  "",
  "Do not promote this release until every gate in CHECKLIST.md has explicit evidence."
)
$readme | Set-Content -Path (Join-Path $outDir "README.md") -Encoding UTF8

$metadata = [ordered]@{
  releaseTag = $ReleaseTag
  commit = $commit
  branch = $branch
  createdUtc = $createdUtc
  operator = $Operator
  deviceId = $DeviceId
  port = $Port
  package = $packageInfo
  requiredLogs = $requiredLogs
  requiredRecords = @(
    "CHECKLIST.md",
    "OBSERVATIONS.md",
    "calibration/calibration.yaml"
  )
  promotionVerifier = "tools/verify_hardware_evidence.ps1"
}

$metadata | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $outDir "metadata.json") -Encoding UTF8

New-Item -ItemType File -Force -Path (Join-Path $logsDir ".gitkeep") | Out-Null
New-Item -ItemType File -Force -Path (Join-Path $photosDir ".gitkeep") | Out-Null

Write-Host "Hardware evidence packet:"
Write-Host $outDir
