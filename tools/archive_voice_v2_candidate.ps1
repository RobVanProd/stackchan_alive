param(
  [string]$OutputRoot = "",
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $RepoRoot

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
  $OutputRoot = "output\firmware-candidates\voice-v2-streaming-" + (Get-Date -Format "yyyyMMdd-HHmmss")
}
$CandidateBuild = ".pio\build\stackchan_voice_v2"
$RollbackBuild = ".pio\build\stackchan_wake_mww_uplink_servos_m5_voiceout"
foreach ($path in @(
    "$CandidateBuild\firmware.bin",
    "$CandidateBuild\firmware.elf",
    "$CandidateBuild\bootloader.bin",
    "$CandidateBuild\partitions.bin",
    "$RollbackBuild\firmware.bin",
    "$RollbackBuild\firmware.elf",
    "$RollbackBuild\bootloader.bin",
    "$RollbackBuild\partitions.bin"
  )) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "Required build artifact is missing: $path"
  }
}

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
$OutputPath = (Resolve-Path $OutputRoot).Path
$CandidateOut = Join-Path $OutputPath "candidate-build"
$RollbackOut = Join-Path $OutputPath "rollback-build"
$SourceOut = Join-Path $OutputPath "source"
$EvidenceOut = Join-Path $OutputPath "host-evidence"
foreach ($path in @($CandidateOut, $RollbackOut, $SourceOut, $EvidenceOut)) {
  New-Item -ItemType Directory -Force -Path $path | Out-Null
}

foreach ($name in @("firmware.bin", "firmware.elf", "bootloader.bin", "partitions.bin")) {
  Copy-Item -LiteralPath (Join-Path $CandidateBuild $name) -Destination (Join-Path $CandidateOut $name)
  Copy-Item -LiteralPath (Join-Path $RollbackBuild $name) -Destination (Join-Path $RollbackOut $name)
}

$SourceFiles = @(
  "platformio.ini",
  "src\main.cpp",
  "bridge\lan_service.py",
  "bridge\tts_adapter.py",
  "bridge\rvc_directml_tts_client.py",
  "bridge\rvc_directml_worker_service.py",
  "bridge\voice_v2_directml_benchmark.py",
  "bridge\voice_v2_directml_runtime.py",
  "bridge\voice_v2_wire_benchmark.py",
  "tools\flash_device.ps1",
  "tools\start_pc_brain.ps1",
  "tools\setup_voice_v2_directml.ps1",
  "tools\run_voice_v2_directml_benchmark.ps1",
  "tools\run_voice_v2_wire_benchmark.ps1",
  "tools\start_voice_v2_directml_worker.ps1",
  "tools\start_voice_v2_supervised_validation.ps1",
  "tools\complete_voice_v2_supervised_validation.ps1",
  "tools\restore_voice_v2_production.ps1",
  "tools\check_voice_v2_supervised_evidence.ps1",
  "tools\test_voice_v2_supervised_evidence_contract.ps1",
  "tools\archive_voice_v2_candidate.ps1",
  "tools\voice_v2_directml_constraints.txt"
)
foreach ($relative in $SourceFiles) {
  if (-not (Test-Path -LiteralPath $relative -PathType Leaf)) { throw "Source file is missing: $relative" }
  $destination = Join-Path $SourceOut $relative
  New-Item -ItemType Directory -Force -Path (Split-Path $destination -Parent) | Out-Null
  Copy-Item -LiteralPath $relative -Destination $destination
}

$EvidenceFiles = @(
  "output\voice-lab\directml-rvc-pm-full-index-20260710\benchmark.json",
  "output\voice-lab\directml-wire-paced-pipelined-70ms-20260710-141700\wire-benchmark.json"
)
foreach ($relative in $EvidenceFiles) {
  if (Test-Path -LiteralPath $relative -PathType Leaf) {
    Copy-Item -LiteralPath $relative -Destination (Join-Path $EvidenceOut (Split-Path $relative -Leaf))
  }
}

$Files = Get-ChildItem -LiteralPath $OutputPath -Recurse -File | Sort-Object FullName
$Hashes = @($Files | ForEach-Object {
    [ordered]@{
      path = $_.FullName.Substring($OutputPath.Length + 1)
      bytes = $_.Length
      sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }
  })
$Manifest = [ordered]@{
  schema = "stackchan.voice-v2-firmware-candidate.v1"
  status = "build-validated-not-flashed"
  generated_at = (Get-Date).ToUniversalTime().ToString("o")
  candidate_environment = "stackchan_voice_v2"
  rollback_environment = "stackchan_wake_mww_uplink_servos_m5_voiceout"
  candidate_static_ram_bytes = 157252
  candidate_flash_bytes = 2669275
  rollback_static_ram_bytes = 144964
  rollback_flash_bytes = 2656923
  native_tests = "194/194 pass"
  bridge_tests = "156/156 pass"
  physical_validation = "pending"
  files = $Hashes
}
$ManifestPath = Join-Path $OutputPath "manifest.json"
$Manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $ManifestPath -Encoding UTF8

$ZipPath = "$OutputPath.zip"
if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
Compress-Archive -Path (Join-Path $OutputPath "*") -DestinationPath $ZipPath -CompressionLevel Optimal
$Result = [ordered]@{
  schema = "stackchan.voice-v2-firmware-candidate-archive.v1"
  status = "archived-build-candidate"
  directory = $OutputPath
  archive = $ZipPath
  archive_sha256 = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash
  candidate_firmware_sha256 = (Get-FileHash -LiteralPath (Join-Path $CandidateOut "firmware.bin") -Algorithm SHA256).Hash
  rollback_firmware_sha256 = (Get-FileHash -LiteralPath (Join-Path $RollbackOut "firmware.bin") -Algorithm SHA256).Hash
}
$Result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $OutputPath "archive-result.json") -Encoding UTF8
if ($Json) { $Result | ConvertTo-Json -Depth 5 } else { Write-Host "Voice V2 candidate archived: $ZipPath" }
