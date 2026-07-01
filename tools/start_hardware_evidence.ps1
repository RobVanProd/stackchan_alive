param(
  [string]$ReleaseTag = "",
  [string]$PackageZip = "",
  [string]$PackageRoot = "",
  [string]$Port = "",
  [string]$Operator = "",
  [string]$DeviceId = "",
  [switch]$AllowIncompleteMetadata,
  [switch]$AllowDirtyPackage
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. (Join-Path $PSScriptRoot "platformio_resolver.ps1")

function Invoke-GitText {
  param([string[]]$Arguments)

  try {
    $output = & git @Arguments 2>$null
  } catch {
    return ""
  }
  if ($LASTEXITCODE -ne 0) {
    return ""
  }
  return ($output | Out-String).Trim()
}

function Get-ReleaseManifest {
  param([string]$RootPath)

  $manifestPath = Join-Path $RootPath "release_manifest.json"
  if (-not (Test-Path -LiteralPath $manifestPath)) {
    return $null
  }

  return Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
}

function Quote-PowerShellArgument {
  param([string]$Value)
  return "'" + ($Value -replace "'", "''") + "'"
}

function Copy-AcceptanceArtifactsFromRoot {
  param(
    [string]$SourceRoot,
    [string]$DestinationRoot
  )

  foreach ($relativePath in @("RELEASE_ACCEPTANCE.md", "release_acceptance.json")) {
    $sourcePath = Join-Path $SourceRoot $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath)) {
      throw "Release package missing acceptance artifact: $relativePath"
    }
    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $DestinationRoot $relativePath)
  }
}

function Copy-AcceptanceArtifactsFromZip {
  param(
    [string]$ZipPath,
    [string]$DestinationRoot
  )

  $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "stackchan-acceptance"
  $extractDir = Join-Path $tempRoot ([System.Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
  try {
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractDir
    Copy-AcceptanceArtifactsFromRoot -SourceRoot $extractDir -DestinationRoot $DestinationRoot
  } finally {
    Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$rootManifest = Get-ReleaseManifest $repoRoot

if ([string]::IsNullOrWhiteSpace($ReleaseTag)) {
  if ($null -ne $rootManifest) {
    $ReleaseTag = [string]$rootManifest.version
  } else {
    $ReleaseTag = Invoke-GitText @("describe", "--tags", "--always", "--dirty")
  }
}

if ([string]::IsNullOrWhiteSpace($PackageRoot) -and [string]::IsNullOrWhiteSpace($PackageZip) -and $null -ne $rootManifest) {
  $PackageRoot = $repoRoot
}

$packageRootManifest = $null
if (-not [string]::IsNullOrWhiteSpace($PackageRoot)) {
  if (-not (Test-Path -LiteralPath $PackageRoot)) {
    throw "Missing package root: $PackageRoot"
  }
  $PackageRoot = (Resolve-Path $PackageRoot).Path
  $packageRootManifest = Get-ReleaseManifest $PackageRoot
}

$commit = ""
if ($null -ne $rootManifest) {
  $commit = [string]$rootManifest.commit
} elseif ($null -ne $packageRootManifest) {
  $commit = [string]$packageRootManifest.commit
}
if ([string]::IsNullOrWhiteSpace($commit)) {
  $commit = Invoke-GitText @("rev-parse", "HEAD")
}
if ([string]::IsNullOrWhiteSpace($commit)) {
  throw "Could not determine release commit from git or package manifest."
}

if (-not $AllowIncompleteMetadata) {
  $missingMetadata = @()
  if ([string]::IsNullOrWhiteSpace($Port)) { $missingMetadata += "-Port" }
  if ([string]::IsNullOrWhiteSpace($Operator)) { $missingMetadata += "-Operator" }
  if ([string]::IsNullOrWhiteSpace($DeviceId)) { $missingMetadata += "-DeviceId" }
  if ($missingMetadata.Count -gt 0) {
    throw "Missing hardware evidence metadata: $($missingMetadata -join ', '). Pass these values for promotion-ready evidence, or use -AllowIncompleteMetadata for diagnostic-only packets."
  }
}

$branch = Invoke-GitText @("rev-parse", "--abbrev-ref", "HEAD")
if ([string]::IsNullOrWhiteSpace($branch)) {
  $branch = "release-package"
}
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
  if ($AllowDirtyPackage) {
    $verifyArgs += "-AllowDirtyPackage"
  }
  $verifyOutput = & powershell.exe @verifyArgs 2>&1
  $verifyExitCode = $LASTEXITCODE
  $verifyOutput | Set-Content -Path $packageVerifyLog -Encoding UTF8
  if ($verifyExitCode -ne 0) {
    throw "Release package verification failed while creating evidence packet. See $packageVerifyLog"
  }
  Copy-AcceptanceArtifactsFromZip -ZipPath $packageItem.FullName -DestinationRoot $outDir
  $requiredLogs = @("logs/package_verify.log") + $requiredLogs
} elseif (-not [string]::IsNullOrWhiteSpace($PackageRoot)) {
  $packageRootItem = Get-Item -LiteralPath $PackageRoot
  $packageInfo = [ordered]@{
    sourcePath = $packageRootItem.FullName
    packageRoot = $true
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
    "-PackageRoot",
    $packageRootItem.FullName,
    "-ExpectedCommit",
    $commit
  )
  if ($AllowDirtyPackage) {
    $verifyArgs += "-AllowDirtyPackage"
  }
  $verifyOutput = & powershell.exe @verifyArgs 2>&1
  $verifyExitCode = $LASTEXITCODE
  $verifyOutput | Set-Content -Path $packageVerifyLog -Encoding UTF8
  if ($verifyExitCode -ne 0) {
    throw "Release package verification failed while creating evidence packet. See $packageVerifyLog"
  }
  Copy-AcceptanceArtifactsFromRoot -SourceRoot $packageRootItem.FullName -DestinationRoot $outDir
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
  "- Yaw classification:",
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
$monitorPortArg = ""
if (-not [string]::IsNullOrWhiteSpace($Port)) {
  $portArg = " -Port $(Quote-PowerShellArgument $Port)"
  $monitorPortArg = " --port $(Quote-PowerShellArgument $Port)"
}

$packageFlashArg = " -PackageZip $(Quote-PowerShellArgument '<path-to-release-zip>')"
$verifyPackageArg = "-ZipPath $(Quote-PowerShellArgument '<path-to-release-zip>')"
if ($packageInfo -and $packageInfo.Contains("copiedFile")) {
  $packageFlashZip = Join-Path $packageDir ([System.IO.Path]::GetFileName($packageInfo["sourcePath"]))
  $packageFlashArg = " -PackageZip $(Quote-PowerShellArgument $packageFlashZip)"
  $verifyPackageArg = "-ZipPath $(Quote-PowerShellArgument $packageFlashZip)"
} elseif (-not [string]::IsNullOrWhiteSpace($PackageRoot)) {
  $packageFlashArg = " -PackageRoot $(Quote-PowerShellArgument $PackageRoot) -Version $(Quote-PowerShellArgument $ReleaseTag) -ExpectedCommit $(Quote-PowerShellArgument $commit)"
  $verifyPackageArg = "-PackageRoot $(Quote-PowerShellArgument $PackageRoot)"
}

$displayLog = Quote-PowerShellArgument (Join-Path $logsDir "display_only_serial.log")
$servoLog = Quote-PowerShellArgument (Join-Path $logsDir "servo_calibration_serial.log")
$soakLog = Quote-PowerShellArgument (Join-Path $logsDir "soak_serial.log")
$displayCommand = "& '.\tools\flash_release_firmware.ps1'$packageFlashArg -Firmware display_only$portArg -Monitor 2>&1 | Tee-Object -FilePath $displayLog"
$servoCommand = "& '.\tools\flash_release_firmware.ps1'$packageFlashArg -Firmware servo_calibration$portArg -Monitor -ConfirmServoRisk 2>&1 | Tee-Object -FilePath $servoLog"
$verifyCommand = "& '.\tools\verify_release_package.ps1' -Version $(Quote-PowerShellArgument $ReleaseTag) $verifyPackageArg -ExpectedCommit $(Quote-PowerShellArgument $commit)"
if ($AllowDirtyPackage) {
  $verifyCommand += " -AllowDirtyPackage"
}
$progressCommand = "& '.\tools\check_hardware_evidence_progress.ps1' -EvidenceRoot $(Quote-PowerShellArgument $outDir)"
$evidenceVerifyCommand = "& '.\tools\verify_hardware_evidence.ps1' -EvidenceRoot $(Quote-PowerShellArgument $outDir)"
$promotionPackageArg = "-PackageZip $(Quote-PowerShellArgument '<path-to-release-zip>')"
if ($packageInfo -and $packageInfo.Contains("copiedFile")) {
  $promotionPackageArg = "-PackageZip $(Quote-PowerShellArgument $packageFlashZip)"
} elseif (-not [string]::IsNullOrWhiteSpace($PackageRoot)) {
  $promotionPackageArg = "-PackageRoot $(Quote-PowerShellArgument $PackageRoot)"
}
$consumerPromotionCommand = "& '.\tools\verify_consumer_promotion.ps1' -Version $(Quote-PowerShellArgument $ReleaseTag) $promotionPackageArg -EvidenceRoot $(Quote-PowerShellArgument $outDir) -ExpectedCommit $(Quote-PowerShellArgument $commit)"
$platformioResolver = Quote-PowerShellArgument (Join-Path $PSScriptRoot "platformio_resolver.ps1")
$soakCommand = ". $platformioResolver; Invoke-StackchanPlatformio device monitor --baud 115200$monitorPortArg 2>&1 | Tee-Object -FilePath $soakLog"

$commandFiles = [ordered]@{
  "RUN_DISPLAY_ONLY.cmd" = @(
    "@echo off",
    "cd /d `"$repoRoot`"",
    "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"& { $displayCommand }`""
  )
  "RUN_SERVO_CALIBRATION.cmd" = @(
    "@echo off",
    "cd /d `"$repoRoot`"",
    "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"& { $servoCommand }`""
  )
  "RUN_SOAK_MONITOR.cmd" = @(
    "@echo off",
    "cd /d `"$repoRoot`"",
    "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"& { $soakCommand }`""
  )
  "RUN_PACKAGE_VERIFY.cmd" = @(
    "@echo off",
    "cd /d `"$repoRoot`"",
    "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"& { $verifyCommand }`""
  )
  "RUN_PROGRESS_CHECK.cmd" = @(
    "@echo off",
    "cd /d `"$repoRoot`"",
    "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"& { $progressCommand }`""
  )
  "RUN_EVIDENCE_VERIFY.cmd" = @(
    "@echo off",
    "cd /d `"$repoRoot`"",
    "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"& { $evidenceVerifyCommand }`""
  )
  "RUN_CONSUMER_PROMOTION_CHECK.cmd" = @(
    "@echo off",
    "cd /d `"$repoRoot`"",
    "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"& { $consumerPromotionCommand }`""
  )
}

foreach ($commandFile in $commandFiles.GetEnumerator()) {
  $commandFile.Value | Set-Content -Path (Join-Path $outDir $commandFile.Key) -Encoding ASCII
}

$readme = @(
  "# Stackchan Hardware Evidence Packet",
  "",
  "Use this folder as the record for one device bring-up session. Complete CHECKLIST.md and OBSERVATIONS.md, save serial logs under logs/, and place real photos or short videos under photos/.",
  "",
  "The runnable command files in this folder are generated for this release, port, package, and evidence path.",
  "",
  "RELEASE_ACCEPTANCE.md and release_acceptance.json record the no-hardware gates that were already accepted and the hardware gates still required before consumer rollout.",
  "",
  "Promotion verification expects OBSERVATIONS.md to record passing values: Result = pass/ok/success, reset/heat/brownout/stall/jitter observed = no, procedural face and dry-run servo log observed = yes, yaw classification = angle/velocity/disabled, soak Duration >= 30 minutes, and USB power-cycle recovery = pass/ok/success.",
  "",
  "Promotion verification also expects serial logs to include firmware markers: display-only boot ``mode=display_only``, servo-calibration boot ``mode=servo_calibration``, display readiness, servo dry-run or hardware-enable line, and soak heartbeat ``[heartbeat] stackchan_alive ... uptime_ms=...``.",
  "",
  "Promotion verification also requires at least one valid media file under photos/: .png, .jpg, .jpeg, .gif, .mp4, .mov, or .webm. Text placeholders, header-only files, tiny files, and images without plausible dimensions do not count as photo/video evidence.",
  "",
  "## Suggested Commands",
  "",
  "Display-only flash:",
  "",
  "    $displayCommand",
  "",
  "    .\RUN_DISPLAY_ONLY.cmd",
  "",
  "Servo calibration flash:",
  "",
  "    $servoCommand",
  "",
  "    .\RUN_SERVO_CALIBRATION.cmd",
  "",
  "Soak monitor log:",
  "",
  "    $soakCommand",
  "",
  "    .\RUN_SOAK_MONITOR.cmd",
  "",
  "Before promotion, verify the release ZIP:",
  "",
  "    $verifyCommand",
  "",
  "    .\RUN_PACKAGE_VERIFY.cmd",
  "",
  "The packet creation command automatically writes ``logs/package_verify.log`` when ``-PackageZip`` is provided.",
  "",
  "Before marking a release hardware-validated, verify this evidence packet:",
  "",
  "    $progressCommand",
  "",
  "    .\RUN_PROGRESS_CHECK.cmd",
  "",
  "Use the progress check during testing to list missing fields, logs, markers, media, and checklist items. It is advisory; the strict promotion check is still required:",
  "",
  "    $evidenceVerifyCommand",
  "",
  "    .\RUN_EVIDENCE_VERIFY.cmd",
  "",
  "After the strict evidence check passes, run the full consumer promotion gate. This also requires successful GitHub Actions status and completed production voice-source provenance:",
  "",
  "    $consumerPromotionCommand",
  "",
  "    .\RUN_CONSUMER_PROMOTION_CHECK.cmd",
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
    "RELEASE_ACCEPTANCE.md",
    "release_acceptance.json",
    "OBSERVATIONS.md",
    "calibration/calibration.yaml",
    "RUN_DISPLAY_ONLY.cmd",
    "RUN_SERVO_CALIBRATION.cmd",
    "RUN_SOAK_MONITOR.cmd",
    "RUN_PACKAGE_VERIFY.cmd",
    "RUN_PROGRESS_CHECK.cmd",
    "RUN_EVIDENCE_VERIFY.cmd",
    "RUN_CONSUMER_PROMOTION_CHECK.cmd"
  )
  promotionVerifier = "tools/verify_consumer_promotion.ps1"
  hardwareEvidenceVerifier = "tools/verify_hardware_evidence.ps1"
}

$metadata | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $outDir "metadata.json") -Encoding UTF8

New-Item -ItemType File -Force -Path (Join-Path $logsDir ".gitkeep") | Out-Null
New-Item -ItemType File -Force -Path (Join-Path $photosDir ".gitkeep") | Out-Null

Write-Host "Hardware evidence packet:"
Write-Output $outDir
