param(
  [string]$OutputRoot = "",
  [string]$AcceptedRollbackRoot = "output\firmware-leads\power-coordinator-priority2-accepted-60min-20260710-003026",
  [string[]]$EvidenceRoots = @(
    "output\pc-brain\release-forensics-filtered-direct-flash-20260710-195923",
    "output\pc-brain\release-forensics-filtered-pc-nomotion-2min-20260710-200231",
    "output\pc-brain\release-forensics-wall-nomotion-2min-20260710-202209",
    "output\pc-brain\release-forensics-wall-clean-reboot-20260710-202449",
    "output\pc-brain\release-forensics-wall-servo-60s-20260710-203302",
    "output\pc-brain\release-forensics-wall-servo-6min-20260710-203435"
  ),
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $RepoRoot

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
  $OutputRoot = "output\firmware-candidates\forensics-validated-" +
    (Get-Date -Format "yyyyMMdd-HHmmss")
}

$CandidateBuild = ".pio\build\stackchan_release_forensics"
$RequiredCandidateFiles = @(
  "firmware.bin",
  "firmware.elf",
  "firmware.map",
  "bootloader.bin",
  "partitions.bin"
)
$BootApp0Path = Join-Path $env:USERPROFILE ".platformio\packages\framework-arduinoespressif32\tools\partitions\boot_app0.bin"
$RequiredRollbackFiles = @(
  "firmware.bin",
  "firmware.elf",
  "bootloader.bin",
  "partitions.bin",
  "manifest.json",
  "SHA256SUMS.txt"
)

foreach ($name in $RequiredCandidateFiles) {
  $path = Join-Path $CandidateBuild $name
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Required candidate artifact is missing: $path"
  }
}
if (-not (Test-Path -LiteralPath $BootApp0Path -PathType Leaf)) {
  throw "Required framework boot_app0 artifact is missing: $BootApp0Path"
}
foreach ($name in $RequiredRollbackFiles) {
  $path = Join-Path $AcceptedRollbackRoot $name
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Required accepted rollback artifact is missing: $path"
  }
}
foreach ($path in $EvidenceRoots) {
  if (-not (Test-Path -LiteralPath $path -PathType Container)) {
    throw "Required physical evidence root is missing: $path"
  }
}

if (Test-Path -LiteralPath $OutputRoot) {
  Remove-Item -LiteralPath $OutputRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$OutputPath = (Resolve-Path $OutputRoot).Path
$CandidateOut = Join-Path $OutputPath "candidate"
$RollbackOut = Join-Path $OutputPath "accepted-rollback"
$SourceOut = Join-Path $OutputPath "source-and-procedure"
$EvidenceOut = Join-Path $OutputPath "physical-evidence"
foreach ($path in @($CandidateOut, $RollbackOut, $SourceOut, $EvidenceOut)) {
  New-Item -ItemType Directory -Force -Path $path | Out-Null
}

foreach ($name in $RequiredCandidateFiles) {
  Copy-Item -LiteralPath (Join-Path $CandidateBuild $name) -Destination (Join-Path $CandidateOut $name)
}
Copy-Item -LiteralPath $BootApp0Path -Destination (Join-Path $CandidateOut "boot_app0.bin")
foreach ($name in $RequiredRollbackFiles) {
  Copy-Item -LiteralPath (Join-Path $AcceptedRollbackRoot $name) -Destination (Join-Path $RollbackOut $name)
}
# boot_app0 is framework-owned and identical across these two images.
Copy-Item -LiteralPath $BootApp0Path `
  -Destination (Join-Path $RollbackOut "boot_app0.bin")

$SourceFiles = @(
  "platformio.ini",
  "docs\POWER_BLACKOUT_FORENSICS.md",
  "docs\VOICE_V2_DIRECTML.md",
  "tools\archive_release_forensics_candidate.ps1",
  "tools\capture_first_post_return_power_forensics.ps1",
  "tools\check_full_system_soak_evidence.ps1",
  "tools\flash_device.ps1",
  "tools\run_full_system_soak_http_motion.ps1",
  "tools\start_warm_rocm_full_system_soak.ps1",
  "tools\test_full_system_soak_evidence_contract.ps1"
)
foreach ($relative in $SourceFiles) {
  if (-not (Test-Path -LiteralPath $relative -PathType Leaf)) {
    throw "Source/procedure file is missing: $relative"
  }
  $destination = Join-Path $SourceOut $relative
  New-Item -ItemType Directory -Force -Path (Split-Path $destination -Parent) | Out-Null
  Copy-Item -LiteralPath $relative -Destination $destination
}
foreach ($relative in @("src", "test\native_stubs", "test\test_native_logic")) {
  $destination = Join-Path $SourceOut $relative
  New-Item -ItemType Directory -Force -Path (Split-Path $destination -Parent) | Out-Null
  Copy-Item -LiteralPath $relative -Destination $destination -Recurse
}

$EvidenceAliases = @("flash", "pc-nomotion", "wall-nomotion", "clean-reboot", "servo-60s", "servo-6min")
if ($EvidenceRoots.Count -ne $EvidenceAliases.Count) {
  throw "Expected $($EvidenceAliases.Count) ordered evidence roots, received $($EvidenceRoots.Count)."
}
for ($i = 0; $i -lt $EvidenceRoots.Count; $i++) {
  Copy-Item -LiteralPath $EvidenceRoots[$i] -Destination (Join-Path $EvidenceOut $EvidenceAliases[$i]) -Recurse
}

$CandidateFirmware = Join-Path $CandidateOut "firmware.bin"
$RollbackFirmware = Join-Path $RollbackOut "firmware.bin"
$ServoSummary = Get-Content -Raw -LiteralPath (
  Join-Path $EvidenceOut "servo-6min\summary.json"
) | ConvertFrom-Json
$FormalCheck = Get-Content -Raw -LiteralPath (
  Join-Path $EvidenceOut "servo-6min\formal-check.json"
) | ConvertFrom-Json

$Manifest = [ordered]@{
  schema = "stackchan.release-forensics-filtered-validated.v1"
  status = "flashed-short-supervised-validation-pass"
  generatedAt = (Get-Date).ToUniversalTime().ToString("o")
  candidateEnvironment = "stackchan_release_forensics"
  candidateFirmwareSha256 = (Get-FileHash -LiteralPath $CandidateFirmware -Algorithm SHA256).Hash
  candidateFirmwareBytes = (Get-Item -LiteralPath $CandidateFirmware).Length
  candidateStaticRamBytes = 157364
  candidateFlashBytes = 2674911
  acceptedRollbackEnvironment = "stackchan_wake_mww_uplink_servos_m5_voiceout"
  acceptedRollbackFirmwareSha256 = (Get-FileHash -LiteralPath $RollbackFirmware -Algorithm SHA256).Hash
  nativeTests = "198/198 pass"
  embeddedBuild = "pass"
  directFlash = "esptool hash verified for all four written regions"
  filtering = "Only enabled selected PMIC IRQ bits increment strict runtime counters; raw disabled informational bits are cleared and tracked separately."
  physicalValidation = [ordered]@{
    pcNoMotion = "120-second pass after informational IRQ filtering"
    wallNoMotion = "120-second pass, 56/56 polls"
    wallServo60Seconds = "61-second pass, 29/29 polls"
    wallServo6Minutes = "360-second pass, 71/71 polls"
    formalCheck = "$($FormalCheck.passed)/$($FormalCheck.checks.Count) pass"
    minVbusMv = $ServoSummary.minPowerVbusMv
    maxChipTempC = $ServoSummary.maxChipTempC
    maxDisplayFrameUs = $ServoSummary.maxFrameUs
    newHardFloorEvents = $ServoSummary.newPowerVbusHardFloorEntries
    newPmicRuntimeEvents = $ServoSummary.newPowerForensicsRuntimeEvents
    newPmicProtectiveEvents = $ServoSummary.newPowerForensicsProtectiveEvents
    motionStopVerified = $ServoSummary.motionStopVerified
  }
  promotionStatus = "Diagnostic lead physically qualified for short supervised use; longer blackout-capture soak and Voice V2 audio validation remain pending."
  flashLayout = [ordered]@{
    bootloader = "0x0000"
    partitions = "0x8000"
    bootApp0 = "0xE000"
    firmware = "0x10000"
  }
}
$ManifestPath = Join-Path $OutputPath "manifest.json"
$Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ManifestPath -Encoding UTF8

$PackageFiles = Get-ChildItem -LiteralPath $OutputPath -Recurse -File | Sort-Object FullName
$FileIndex = @($PackageFiles | ForEach-Object {
    [ordered]@{
      path = $_.FullName.Substring($OutputPath.Length + 1)
      bytes = $_.Length
      sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
  })
$FileIndex | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputPath "files.json") -Encoding UTF8

$ZipPath = "$OutputPath.zip"
if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
Compress-Archive -Path (Join-Path $OutputPath "*") -DestinationPath $ZipPath -CompressionLevel Optimal

Add-Type -AssemblyName System.IO.Compression.FileSystem
$Archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
try {
  $EntryNames = @($Archive.Entries | ForEach-Object { $_.FullName.Replace("\", "/") })
} finally {
  $Archive.Dispose()
}
foreach ($required in @(
    "manifest.json",
    "files.json",
    "candidate/firmware.bin",
    "accepted-rollback/firmware.bin",
    "physical-evidence/servo-6min/summary.json",
    "physical-evidence/servo-6min/formal-check.json"
  )) {
  if ($EntryNames -notcontains $required) { throw "Archive verification failed; missing entry: $required" }
}

$Result = [ordered]@{
  schema = "stackchan.release-forensics-filtered-archive-result.v1"
  status = "verified"
  directory = $OutputPath
  archive = $ZipPath
  archiveSha256 = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash
  archiveBytes = (Get-Item -LiteralPath $ZipPath).Length
  archiveEntries = $EntryNames.Count
  candidateFirmwareSha256 = $Manifest.candidateFirmwareSha256
  acceptedRollbackFirmwareSha256 = $Manifest.acceptedRollbackFirmwareSha256
}
$ResultPath = "$OutputPath-archive-result.json"
$Result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
if ($Json) { $Result | ConvertTo-Json -Depth 5 } else { Write-Host "Release-forensics candidate archived: $ZipPath" }
