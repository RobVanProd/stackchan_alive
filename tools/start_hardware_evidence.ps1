param(
  [string]$ReleaseTag = "",
  [string]$PackageZip = "",
  [string]$PackageRoot = "",
  [string]$Port = "",
  [string]$Operator = "",
  [string]$DeviceId = "",
  [string]$ShareRoot = "",
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

function Copy-VoiceLeadArtifactsFromRoot {
  param(
    [string]$SourceRoot,
    [string]$DestinationRoot
  )

  $auditionJsonPath = Join-Path $SourceRoot "media/voice/rvc/RVC_AUDITIONS.json"
  $auditionMarkdownPath = Join-Path $SourceRoot "media/voice/rvc/RVC_AUDITIONS.md"
  if (-not (Test-Path -LiteralPath $auditionJsonPath)) {
    throw "Release package missing RVC audition manifest: media/voice/rvc/RVC_AUDITIONS.json"
  }
  if (-not (Test-Path -LiteralPath $auditionMarkdownPath)) {
    throw "Release package missing RVC audition notes: media/voice/rvc/RVC_AUDITIONS.md"
  }

  $auditions = Get-Content -LiteralPath $auditionJsonPath -Raw | ConvertFrom-Json
  if ($null -eq $auditions.leadAudition) {
    throw "RVC_AUDITIONS.json missing leadAudition metadata."
  }

  $lead = $auditions.leadAudition
  $leadFile = [string]$lead.file
  if ([string]::IsNullOrWhiteSpace($leadFile)) {
    throw "RVC lead audition file is blank."
  }

  $leadSourcePath = Join-Path $SourceRoot "media/voice/rvc/$leadFile"
  if (-not (Test-Path -LiteralPath $leadSourcePath)) {
    throw "Release package missing RVC lead audition WAV: media/voice/rvc/$leadFile"
  }

  $referenceDir = Join-Path $DestinationRoot "reference_audio"
  New-Item -ItemType Directory -Force -Path $referenceDir | Out-Null

  $leadDestinationPath = Join-Path $referenceDir $leadFile
  Copy-Item -LiteralPath $leadSourcePath -Destination $leadDestinationPath
  Copy-Item -LiteralPath $auditionJsonPath -Destination (Join-Path $referenceDir "RVC_AUDITIONS.json")
  Copy-Item -LiteralPath $auditionMarkdownPath -Destination (Join-Path $referenceDir "RVC_AUDITIONS.md")

  $leadHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $leadDestinationPath).Hash.ToLowerInvariant()
  $leadTitle = [string]$lead.title
  $leadTranscript = [string]$lead.transcript
  $leadRating = [string]$lead.userRating
  $leadPurpose = [string]$lead.perceptualPurpose
  $leadPitch = [string]$lead.pitch
  $leadIndex = [string]$lead.index_rate
  $leadRms = [string]$lead.rms_mix_rate
  $leadProtect = [string]$lead.protect
  $leadRelativePath = "reference_audio/$leadFile"

  @(
    "# RVC Lead Audition Reference",
    "",
    "This file pins the exact review-only RVC voice sample to play during the target speaker check. It is not production voice-source approval.",
    "",
    "- Lead audition: $leadTitle",
    "- Reference WAV: $leadRelativePath",
    "- SHA256: $leadHash",
    "- Transcript: $leadTranscript",
    "- Tuning: pitch $leadPitch, index $leadIndex, RMS mix $leadRms, protect $leadProtect",
    "- Listening note: $leadRating",
    "- Perceptual purpose: $leadPurpose",
    "",
    "Use ``RUN_PLAY_LEAD_VOICE.cmd`` only as a playback aid. Consumer promotion still requires a real-device speaker recording imported under ``audio/``, completed ``AUDIO_REVIEW.md``, and completed production voice-source provenance."
  ) | Set-Content -Path (Join-Path $DestinationRoot "RVC_LEAD_AUDITION.md") -Encoding UTF8

  return [ordered]@{
    title = $leadTitle
    file = $leadFile
    referenceFile = $leadRelativePath
    sha256 = $leadHash
    transcript = $leadTranscript
    pitch = $leadPitch
    index_rate = $leadIndex
    rms_mix_rate = $leadRms
    protect = $leadProtect
    userRating = $leadRating
    perceptualPurpose = $leadPurpose
  }
}

function Copy-VoiceLeadArtifactsFromZip {
  param(
    [string]$ZipPath,
    [string]$DestinationRoot
  )

  $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "stackchan-voice-lead"
  $extractDir = Join-Path $tempRoot ([System.Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
  try {
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractDir
    return Copy-VoiceLeadArtifactsFromRoot -SourceRoot $extractDir -DestinationRoot $DestinationRoot
  } finally {
    Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Copy-VoiceGateStatusFromRoot {
  param(
    [string]$SourceRoot,
    [string]$DestinationRoot
  )

  $statusFiles = @(
    "VOICE_SOURCE_STATUS.md",
    "voice_source_status.json",
    "RVC_VOICE_BASE_STATUS.md",
    "rvc_voice_base_status.json"
  )

  foreach ($relativePath in $statusFiles) {
    $sourcePath = Join-Path $SourceRoot $relativePath
    if (-not (Test-Path -LiteralPath $sourcePath)) {
      throw "Release package missing voice gate status artifact: $relativePath"
    }
    Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $DestinationRoot $relativePath)
  }

  $voiceSourceStatus = Get-Content -LiteralPath (Join-Path $DestinationRoot "voice_source_status.json") -Raw | ConvertFrom-Json
  $rvcBaseStatus = Get-Content -LiteralPath (Join-Path $DestinationRoot "rvc_voice_base_status.json") -Raw | ConvertFrom-Json

  return [ordered]@{
    voiceSourceStatus = [string]$voiceSourceStatus.status
    voiceSourceBlockedGateCount = [int]$voiceSourceStatus.blockedGateCount
    rvcVoiceBaseStatus = [string]$rvcBaseStatus.status
    rvcConsumerApproved = [bool]$rvcBaseStatus.consumerApproved
    rvcDistributionApproved = [bool]$rvcBaseStatus.distributionApproved
    reports = @(
      "VOICE_SOURCE_STATUS.md",
      "voice_source_status.json",
      "RVC_VOICE_BASE_STATUS.md",
      "rvc_voice_base_status.json"
    )
  }
}

function Copy-VoiceGateStatusFromZip {
  param(
    [string]$ZipPath,
    [string]$DestinationRoot
  )

  $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "stackchan-voice-gates"
  $extractDir = Join-Path $tempRoot ([System.Guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
  try {
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $extractDir
    return Copy-VoiceGateStatusFromRoot -SourceRoot $extractDir -DestinationRoot $DestinationRoot
  } finally {
    Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

function Copy-ShareVerificationArtifactsFromRoot {
  param(
    [string]$SourceRoot,
    [string]$DestinationRoot,
    [bool]$Required
  )

  if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    return $null
  }

  if (-not (Test-Path -LiteralPath $SourceRoot)) {
    if ($Required) {
      throw "Missing share verification folder: $SourceRoot"
    }
    return $null
  }

  $statusPath = Join-Path $SourceRoot "share_status.json"
  $verificationJsonPath = Join-Path $SourceRoot "share_verification_report.json"
  $verificationMarkdownPath = Join-Path $SourceRoot "share_verification_report.md"
  $publicUrlPath = Join-Path $SourceRoot "PUBLIC_URL.txt"

  foreach ($path in @($statusPath, $verificationJsonPath, $verificationMarkdownPath)) {
    if (-not (Test-Path -LiteralPath $path)) {
      if ($Required) {
        throw "Share verification folder is missing required artifact: $path"
      }
      return $null
    }
  }

  $shareStatus = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
  $shareVerification = Get-Content -LiteralPath $verificationJsonPath -Raw | ConvertFrom-Json
  if ($shareStatus.version -ne $ReleaseTag) {
    throw "share_status.json version mismatch: expected $ReleaseTag, got $($shareStatus.version)"
  }
  if ($shareVerification.version -ne $ReleaseTag) {
    throw "share_verification_report.json version mismatch: expected $ReleaseTag, got $($shareVerification.version)"
  }
  if (-not [bool]$shareVerification.allHttp200) {
    throw "share_verification_report.json does not show all probes HTTP 200."
  }

  $shareDir = Join-Path $DestinationRoot "share"
  New-Item -ItemType Directory -Force -Path $shareDir | Out-Null
  foreach ($path in @($statusPath, $verificationJsonPath, $verificationMarkdownPath)) {
    Copy-Item -LiteralPath $path -Destination (Join-Path $shareDir ([System.IO.Path]::GetFileName($path)))
  }
  if (Test-Path -LiteralPath $publicUrlPath) {
    Copy-Item -LiteralPath $publicUrlPath -Destination (Join-Path $shareDir "PUBLIC_URL.txt")
  }

  $verifiedUrl = [string]$shareStatus.publicUrl
  if ([string]::IsNullOrWhiteSpace($verifiedUrl) -and (Test-Path -LiteralPath $publicUrlPath)) {
    $publicUrl = (Get-Content -LiteralPath $publicUrlPath -Raw).Trim()
    if (-not [string]::IsNullOrWhiteSpace($publicUrl)) {
      $verifiedUrl = $publicUrl
    }
  }
  if ([string]::IsNullOrWhiteSpace($verifiedUrl)) {
    $verifiedUrl = [string]$shareVerification.url
  }
  if ([string]::IsNullOrWhiteSpace($verifiedUrl)) {
    $verifiedUrl = [string]$shareStatus.localUrl
  }
  if ([string]::IsNullOrWhiteSpace($verifiedUrl)) {
    $verifiedUrl = [string]$shareStatus.loopbackUrl
  }
  if ([string]::IsNullOrWhiteSpace($verifiedUrl)) {
    throw "Share verification artifacts do not include a verified URL."
  }
  $urlKind = "local"
  if ($verifiedUrl -match "^https://[-A-Za-z0-9]+\.trycloudflare\.com/?$") {
    $urlKind = "public"
  } elseif ($verifiedUrl -match "^http://(127\.0\.0\.1|localhost)(:\d+)?/") {
    $urlKind = "loopback"
  }
  $verifiedUrl | Set-Content -Path (Join-Path $shareDir "VERIFIED_URL.txt") -Encoding ASCII

  $probeCount = [int]$shareVerification.probeCount
  $fallbackText = if ([bool]$shareVerification.usedCurlResolveFallback) { "yes" } else { "no" }
  $copiedArtifacts = @(
    "share/share_status.json",
    "share/share_verification_report.md",
    "share/share_verification_report.json",
    "share/VERIFIED_URL.txt"
  )
  if (Test-Path -LiteralPath $publicUrlPath) {
    $copiedArtifacts += "share/PUBLIC_URL.txt"
  }

  $hostedMediaLines = @(
    "# Hosted Media Reference",
    "",
    "This packet records the review page that was verified before hardware testing. Use it to compare the physical device against the exact hosted preview, video, face artifacts, and voice samples for this release.",
    "",
    "- Release tag: $ReleaseTag",
    "- Verified URL: $verifiedUrl",
    "- URL kind: $urlKind",
    "- Share status: $($shareStatus.status)",
    "- Public URL ready: $($shareStatus.publicUrlReady)",
    "- Verification generated UTC: $($shareVerification.generatedUtc)",
    "- Probe count: $probeCount",
    "- All probes HTTP 200: $($shareVerification.allHttp200)",
    "- Used curl DNS override fallback: $fallbackText",
    "",
    "Copied artifacts:",
    ""
  )
  foreach ($artifact in $copiedArtifacts) {
    $hostedMediaLines += "- ``$artifact``"
  }
  $hostedMediaLines += @(
    "",
    "This hosted-media reference is review evidence only. Consumer promotion still requires real-device photo/video, target-speaker recording, strict hardware evidence verification, successful GitHub Actions status, and completed production voice-source provenance."
  )
  $hostedMediaLines | Set-Content -Path (Join-Path $DestinationRoot "HOSTED_MEDIA_REFERENCE.md") -Encoding UTF8

  return [ordered]@{
    sourceRoot = (Resolve-Path $SourceRoot).Path
    publicUrl = $verifiedUrl
    verifiedUrl = $verifiedUrl
    urlKind = $urlKind
    status = [string]$shareStatus.status
    publicUrlReady = [bool]$shareStatus.publicUrlReady
    verificationReport = "share/share_verification_report.json"
    verificationSummary = "share/share_verification_report.md"
    hostedMediaReference = "HOSTED_MEDIA_REFERENCE.md"
    verifiedUrlFile = "share/VERIFIED_URL.txt"
    probeCount = $probeCount
    allHttp200 = [bool]$shareVerification.allHttp200
    usedCurlResolveFallback = [bool]$shareVerification.usedCurlResolveFallback
  }
}

function Set-ChecklistItemState {
  param(
    [string[]]$Lines,
    [string]$ExactItemText,
    [bool]$Checked
  )

  $state = if ($Checked) { "x" } else { " " }
  $escaped = [regex]::Escape($ExactItemText)
  return @($Lines | ForEach-Object {
      if ($_ -match "^- \[[ x]\] $escaped$") {
        "- [$state] $ExactItemText"
      } else {
        $_
      }
    })
}

function Write-EvidenceChecklist {
  param(
    [string]$DestinationPath,
    [bool]$PackageVerified,
    [bool]$PreflightPassed,
    [bool]$PackageCopied
  )

  $lines = @(Get-Content -LiteralPath "docs/ROLLOUT_CHECKLIST.md")

  if ($PreflightPassed) {
    foreach ($item in @(
        '`pio run -e stackchan` passes.',
        '`pio run -e stackchan_servo_calibration` passes.',
        '`pio test -e native_logic` passes.',
        '`pio test -e stackchan --without-uploading --without-testing` passes.',
        '`tools/run_device_preflight.ps1` passes.',
        '`tools/flash_release_firmware.ps1 -PackageZip <zip> -Firmware display_only -DryRun -Monitor` passes for the release ZIP.'
      )) {
      $lines = Set-ChecklistItemState -Lines $lines -ExactItemText $item -Checked $true
    }
  }

  if ($PackageVerified) {
    foreach ($item in @(
        'Release package ZIP contains firmware, media, docs, manifest, dependency provenance, `dependency_lock.json`, copied build inputs, and checksums.',
        '`tools/verify_release_package.ps1` passes for the release ZIP.',
        'Hardware evidence packet created with `tools/start_hardware_evidence.ps1`.'
      )) {
      $lines = Set-ChecklistItemState -Lines $lines -ExactItemText $item -Checked $true
    }
  }

  if ($PackageVerified -and $PackageCopied) {
    $lines = Set-ChecklistItemState -Lines $lines -ExactItemText 'Evidence packet includes the tested ZIP and `logs/package_verify.log`, or records a verified extracted package root.' -Checked $true
  }

  $preflightNote = if ($PreflightPassed) {
    "Pre-marked no-hardware gates were proven by the matching preflight report for this release. Hardware, GitHub Actions, production voice-source, media, audio, and promotion gates still require explicit evidence."
  } else {
    "Only package-verification gates were pre-marked. Run the matching no-hardware preflight and attach its report before treating build/test gates as proven."
  }

  $annotated = @(
    "<!-- Generated evidence packet checklist for $ReleaseTag at $createdUtc. -->",
    "<!-- $preflightNote -->"
  ) + $lines

  $annotated | Set-Content -Path $DestinationPath -Encoding UTF8
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
$shareRootWasExplicit = -not [string]::IsNullOrWhiteSpace($ShareRoot)
if (-not $shareRootWasExplicit) {
  $ShareRoot = Join-Path $repoRoot "output/share/$ReleaseTag"
}

$createdUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$safeTag = $ReleaseTag -replace '[^A-Za-z0-9_.-]', '_'
$outDir = Join-Path $repoRoot "output/hardware-evidence/$safeTag-$stamp"

$logsDir = Join-Path $outDir "logs"
$photosDir = Join-Path $outDir "photos"
$audioDir = Join-Path $outDir "audio"
$speechDir = Join-Path $outDir "speech"
$referenceAudioDir = Join-Path $outDir "reference_audio"
$calibrationDir = Join-Path $outDir "calibration"
$packageDir = Join-Path $outDir "package"
New-Item -ItemType Directory -Force -Path $logsDir, $photosDir, $audioDir, $speechDir, $referenceAudioDir, $calibrationDir, $packageDir | Out-Null

$packageInfo = $null
$voiceLeadInfo = $null
$voiceGateInfo = $null
$shareVerificationInfo = $null
$packageVerified = $false
$requiredLogs = @(
  "logs/display_only_serial.log",
  "logs/speech_mouth_demo_serial.log",
  "logs/speak_all_intents_serial.log",
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
  $packageVerified = $true
  Copy-AcceptanceArtifactsFromZip -ZipPath $packageItem.FullName -DestinationRoot $outDir
  $voiceLeadInfo = Copy-VoiceLeadArtifactsFromZip -ZipPath $packageItem.FullName -DestinationRoot $outDir
  $voiceGateInfo = Copy-VoiceGateStatusFromZip -ZipPath $packageItem.FullName -DestinationRoot $outDir
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
  $packageVerified = $true
  Copy-AcceptanceArtifactsFromRoot -SourceRoot $packageRootItem.FullName -DestinationRoot $outDir
  $voiceLeadInfo = Copy-VoiceLeadArtifactsFromRoot -SourceRoot $packageRootItem.FullName -DestinationRoot $outDir
  $voiceGateInfo = Copy-VoiceGateStatusFromRoot -SourceRoot $packageRootItem.FullName -DestinationRoot $outDir
  $requiredLogs = @("logs/package_verify.log") + $requiredLogs
}

$shareVerificationInfo = Copy-ShareVerificationArtifactsFromRoot -SourceRoot $ShareRoot -DestinationRoot $outDir -Required $shareRootWasExplicit

$preflightPassed = $false
$preflightReportPath = Join-Path $repoRoot "output/preflight/$ReleaseTag/preflight_report.json"
if (Test-Path -LiteralPath $preflightReportPath) {
  $preflightReport = Get-Content -LiteralPath $preflightReportPath -Raw | ConvertFrom-Json
  $preflightPassed = ([string]$preflightReport.status -eq "pass" -and [string]$preflightReport.commit -eq $commit)
}
Write-EvidenceChecklist -DestinationPath (Join-Path $outDir "CHECKLIST.md") -PackageVerified $packageVerified -PreflightPassed $preflightPassed -PackageCopied ($null -ne $packageInfo)
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
  "- Hosted media verification: HOSTED_MEDIA_REFERENCE.md",
  "- Photos/videos: photos/",
  "- Calibration record: calibration/calibration.yaml"
)
$observations | Set-Content -Path (Join-Path $outDir "OBSERVATIONS.md") -Encoding UTF8

$audioSamplePlayed = ""
$audioVoiceVariant = "stackchan_spark_greeting / stackchan_spark_thinking / stackchan_spark_safety / warm_slow / bright_robot / production"
$audioSelectedVoiceDirection = ""
if ($voiceLeadInfo) {
  $audioSamplePlayed = [string]$voiceLeadInfo.referenceFile
  $audioVoiceVariant = "$($voiceLeadInfo.title) (pitch $($voiceLeadInfo.pitch), index $($voiceLeadInfo.index_rate), RMS mix $($voiceLeadInfo.rms_mix_rate), protect $($voiceLeadInfo.protect))"
  $audioSelectedVoiceDirection = "$($voiceLeadInfo.title) lead audition; review-only until production voice-source provenance is complete"
}

$audioReview = @(
  "# Stackchan Audio Review",
  "",
  "Release tag: $ReleaseTag",
  "Commit: $commit",
  "Device ID: $DeviceId",
  "Port: $Port",
  "Operator: $Operator",
  "",
  "Record at least one real-device speaker sample under ``audio/``. A phone recording is acceptable for bring-up evidence if the file is not edited and the room/device context is clear.",
  "",
  "## Speaker Playback",
  "",
  "- Start UTC:",
  "- End UTC:",
  "- Sample played: $audioSamplePlayed",
  "- Voice variant: $audioVoiceVariant",
  "- Speaker recording file:",
  "- Intelligible through device speaker: yes/no",
  "- Clipping or distortion observed: yes/no",
  "- Volume adequate at normal listening distance: yes/no",
  "- Delay or playback dropout observed: yes/no",
  "- Selected voice direction: $audioSelectedVoiceDirection",
  "- Notes:",
  "",
  "## Promotion Requirements",
  "",
  "- Use original Stackchan lines, not movie quotes or named-character catchphrases.",
  "- Keep current prototype WAVs as review-only until production voice provenance is complete.",
  "- Consumer promotion requires licensed or owned production voice source evidence plus this target-speaker audio check."
)
$audioReview | Set-Content -Path (Join-Path $outDir "AUDIO_REVIEW.md") -Encoding UTF8

$ciExceptionTemplate = [ordered]@{
  schema = "stackchan.ci-account-block-exception.v1"
  version = $ReleaseTag
  commit = $commit
  githubActionsStatus = "external-account-billing-or-spending-limit"
  approvedBy = "TBD - accountable approver required"
  approvedUtc = "TBD - YYYY-MM-DDTHH:MM:SSZ"
  reason = "GitHub Actions could not start jobs because of an account billing, spending-limit, or pre-runner allocation outage outside this repository."
  riskAccepted = $false
  localReleaseVerificationPassed = $false
  strictHardwareEvidencePassed = $false
  productionVoiceSourceReady = $false
  followUpOwner = "TBD - CI account owner"
  followUpDueUtc = "TBD - YYYY-MM-DDTHH:MM:SSZ"
}
$ciExceptionTemplate | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $outDir "CI_ACCOUNT_BLOCK_EXCEPTION_TEMPLATE.json") -Encoding UTF8

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
$speechDemoLog = Quote-PowerShellArgument (Join-Path $logsDir "speech_mouth_demo_serial.log")
$speakAllLog = Quote-PowerShellArgument (Join-Path $logsDir "speak_all_intents_serial.log")
$bridgeReplayLog = Quote-PowerShellArgument (Join-Path $logsDir "bridge_replay_serial.log")
$hardwareSimBaselineLog = Quote-PowerShellArgument (Join-Path $logsDir "hardware_simulation_baseline.log")
$hardwareSimBaselineDir = Quote-PowerShellArgument (Join-Path $outDir "simulation/hardware-sim/latest")
$displayCommand = "& '.\tools\flash_release_firmware.ps1'$packageFlashArg -Firmware display_only$portArg -Monitor 2>&1 | Tee-Object -FilePath $displayLog"
$servoCommand = "& '.\tools\flash_release_firmware.ps1'$packageFlashArg -Firmware servo_calibration$portArg -Monitor -ConfirmServoRisk 2>&1 | Tee-Object -FilePath $servoLog"
$speechDemoBody = "& '.\tools\send_speech_mouth_demo.ps1'$portArg"
if ($voiceLeadInfo) {
  $leadAudioPath = Join-Path $outDir ([string]$voiceLeadInfo.referenceFile -replace "/", "\")
  $leadSpeechSidecarPath = Join-Path $speechDir "lead_voice.speech_envelope.json"
  $leadAudioArg = Quote-PowerShellArgument $leadAudioPath
  $leadSidecarArg = Quote-PowerShellArgument $leadSpeechSidecarPath
  $speechDemoBody = "& '.\tools\generate_speech_envelope_sidecar.ps1' -InputWav $leadAudioArg -OutputJson $leadSidecarArg; if (`$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }; & '.\tools\verify_speech_envelope_sidecar.ps1' -Path $leadSidecarArg -MinFrames 50 -MinMaxEnvelope 0.35; if (`$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }; & '.\tools\send_speech_mouth_demo.ps1'$portArg -SidecarPath $leadSidecarArg"
}
$speechDemoCommand = "& { $speechDemoBody } 2>&1 | Tee-Object -FilePath $speechDemoLog"
$speakAllCommand = "& '.\tools\send_speak_all_intents_demo.ps1'$portArg 2>&1 | Tee-Object -FilePath $speakAllLog"
$bridgeReplayCommand = "& '.\tools\send_bridge_replay_demo.ps1'$portArg 2>&1 | Tee-Object -FilePath $bridgeReplayLog"
$hardwareSimBaselineCommand = "& '.\tools\run_hardware_simulation.ps1' -OutputDir $hardwareSimBaselineDir -Json 2>&1 | Tee-Object -FilePath $hardwareSimBaselineLog"
$simHardwareCompareCommand = "& '.\tools\compare_hardware_sim_baseline.ps1' -EvidenceRoot $(Quote-PowerShellArgument $outDir)"
$verifyCommand = "& '.\tools\verify_release_package.ps1' -Version $(Quote-PowerShellArgument $ReleaseTag) $verifyPackageArg -ExpectedCommit $(Quote-PowerShellArgument $commit)"
if ($AllowDirtyPackage) {
  $verifyCommand += " -AllowDirtyPackage"
}
$progressCommand = "& '.\tools\check_hardware_evidence_progress.ps1' -EvidenceRoot $(Quote-PowerShellArgument $outDir)"
$addMediaCommand = "& '.\tools\add_hardware_evidence_media.ps1' -EvidenceRoot $(Quote-PowerShellArgument $outDir)"
$evidenceVerifyCommand = "& '.\tools\verify_hardware_evidence.ps1' -EvidenceRoot $(Quote-PowerShellArgument $outDir)"
$promotionPackageArg = "-PackageZip $(Quote-PowerShellArgument '<path-to-release-zip>')"
if ($packageInfo -and $packageInfo.Contains("copiedFile")) {
  $promotionPackageArg = "-PackageZip $(Quote-PowerShellArgument $packageFlashZip)"
} elseif (-not [string]::IsNullOrWhiteSpace($PackageRoot)) {
  $promotionPackageArg = "-PackageRoot $(Quote-PowerShellArgument $PackageRoot)"
}
$rolloutStatusCommand = "& '.\tools\export_rollout_status.ps1' -Version $(Quote-PowerShellArgument $ReleaseTag) $promotionPackageArg -EvidenceRoot $(Quote-PowerShellArgument $outDir) -ExpectedCommit $(Quote-PowerShellArgument $commit) -OutDir $(Quote-PowerShellArgument $outDir)"
$consumerPromotionCommand = "& '.\tools\verify_consumer_promotion.ps1' -Version $(Quote-PowerShellArgument $ReleaseTag) $promotionPackageArg -EvidenceRoot $(Quote-PowerShellArgument $outDir) -ExpectedCommit $(Quote-PowerShellArgument $commit)"
$platformioResolver = Quote-PowerShellArgument (Join-Path $PSScriptRoot "platformio_resolver.ps1")
$soakCommand = ". $platformioResolver; Invoke-StackchanPlatformio device monitor --baud 115200$monitorPortArg 2>&1 | Tee-Object -FilePath $soakLog"
$playLeadCommand = "Write-Host 'No RVC lead audition reference was copied into this packet.'"
if ($voiceLeadInfo) {
  $leadAudioPath = Join-Path $outDir ([string]$voiceLeadInfo.referenceFile -replace "/", "\")
  $playLeadCommand = "`$player = New-Object System.Media.SoundPlayer $(Quote-PowerShellArgument $leadAudioPath); `$player.PlaySync()"
}

function New-PowerShellCommandFile {
  param([string]$Command)

  return @(
    "@echo off",
    "cd /d `"$repoRoot`"",
    "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `"& { $Command; if (`$null -ne `$global:LASTEXITCODE) { exit `$global:LASTEXITCODE }; if (-not `$?) { exit 1 } }`"",
    "exit /b %ERRORLEVEL%"
  )
}

$commandFiles = [ordered]@{
  "RUN_PLAY_LEAD_VOICE.cmd" = New-PowerShellCommandFile $playLeadCommand
  "RUN_DISPLAY_ONLY.cmd" = New-PowerShellCommandFile $displayCommand
  "RUN_SPEECH_MOUTH_DEMO.cmd" = New-PowerShellCommandFile $speechDemoCommand
  "RUN_SPEAK_ALL_INTENTS.cmd" = New-PowerShellCommandFile $speakAllCommand
  "RUN_BRIDGE_REPLAY.cmd" = New-PowerShellCommandFile $bridgeReplayCommand
  "RUN_SERVO_CALIBRATION.cmd" = New-PowerShellCommandFile $servoCommand
  "RUN_SOAK_MONITOR.cmd" = New-PowerShellCommandFile $soakCommand
  "RUN_PACKAGE_VERIFY.cmd" = New-PowerShellCommandFile $verifyCommand
  "RUN_HARDWARE_SIM_BASELINE.cmd" = New-PowerShellCommandFile $hardwareSimBaselineCommand
  "RUN_SIM_HARDWARE_COMPARE.cmd" = New-PowerShellCommandFile $simHardwareCompareCommand
  "RUN_PROGRESS_CHECK.cmd" = New-PowerShellCommandFile $progressCommand
  "RUN_ROLLOUT_STATUS.cmd" = New-PowerShellCommandFile $rolloutStatusCommand
  "RUN_ADD_MEDIA.cmd" = @(
    "@echo off",
    "cd /d `"$repoRoot`"",
    "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `".\tools\add_hardware_evidence_media.ps1`" -EvidenceRoot `"$outDir`" %*",
    "exit /b %ERRORLEVEL%"
  )
  "RUN_EVIDENCE_VERIFY.cmd" = New-PowerShellCommandFile $evidenceVerifyCommand
  "RUN_CONSUMER_PROMOTION_CHECK.cmd" = New-PowerShellCommandFile $consumerPromotionCommand
}

foreach ($commandFile in $commandFiles.GetEnumerator()) {
  $commandFile.Value | Set-Content -Path (Join-Path $outDir $commandFile.Key) -Encoding ASCII
}

$nextSteps = @(
  "# Stackchan Evidence Next Steps",
  "",
  "Release: $ReleaseTag",
  "Commit: $commit",
  "Device: $DeviceId",
  "Port: $Port",
  "Operator: $Operator",
  "",
  "Use this as the short operator path for the packet. The longer README.md explains the details and exact commands.",
  "",
  "Open ``BENCH_STATUS.md`` for the latest single next action. ``RUN_PROGRESS_CHECK.cmd`` refreshes ``BENCH_STATUS.md`` and ``BENCH_STATUS.json`` after each bench step.",
  "",
  "## Run Order",
  "",
  "1. Run ``RUN_PACKAGE_VERIFY.cmd`` and confirm ``logs/package_verify.log`` ends with ``Release package verified:``.",
  "2. If the physical unit is not connected yet, run ``RUN_HARDWARE_SIM_BASELINE.cmd`` to save the no-hardware virtual Stackchan baseline under ``simulation/hardware-sim/latest/`` and ``logs/hardware_simulation_baseline.log``.",
  "3. Run ``RUN_DISPLAY_ONLY.cmd`` and confirm the face is visible, flicker-free, and serial logs show display, face, and system telemetry.",
  "4. Run ``RUN_SPEECH_MOUTH_DEMO.cmd`` while display-only firmware is still connected to exercise speech-envelope mouth motion and capture ``logs/speech_mouth_demo_serial.log``.",
  "5. Run ``RUN_SPEAK_ALL_INTENTS.cmd`` while display-only firmware is still connected to exercise every packaged speech intent, earcon, and audio-output handoff, then capture ``logs/speak_all_intents_serial.log``.",
  "6. Run ``RUN_BRIDGE_REPLAY.cmd`` to exercise P7 bridge hello/listening/thinking/response/audio/end routing and capture ``logs/bridge_replay_serial.log``.",
  "7. Run ``RUN_SIM_HARDWARE_COMPARE.cmd`` to write ``SIM_HARDWARE_COMPARE.md/json`` and compare the real serial markers against the no-hardware baseline. Pending means more logs are needed; it is not promotion evidence.",
  "8. Add a display photo or short video with ``RUN_ADD_MEDIA.cmd -Type Photo C:\path\stackchan-face.jpg``.",
  "9. Run ``RUN_SERVO_CALIBRATION.cmd`` only with the body clear; this command includes ``-ConfirmServoRisk`` and may move the hardware.",
  "10. Update ``calibration/calibration.yaml`` with measured limits and classify yaw as ``angle``, ``velocity``, or ``disabled``.",
  "11. Run ``RUN_SOAK_MONITOR.cmd`` for at least 30 minutes and record the result in ``OBSERVATIONS.md``.",
  "12. Run ``RUN_PLAY_LEAD_VOICE.cmd`` as the playback reference, record the target speaker path, then add the recording with ``RUN_ADD_MEDIA.cmd -Type Audio C:\path\stackchan-speaker.wav``.",
  "13. Complete ``AUDIO_REVIEW.md`` with real-device speaker results. Generated source WAVs alone do not count.",
  "14. Run ``RUN_PROGRESS_CHECK.cmd`` to refresh ``BENCH_STATUS.md/json`` and fix every missing field, marker, media file, and unchecked checklist item it reports.",
  "15. Run ``RUN_ROLLOUT_STATUS.cmd`` to write ``ROLLOUT_STATUS.md`` and ``ROLLOUT_STATUS.json`` for handoff review.",
  "16. Run ``RUN_EVIDENCE_VERIFY.cmd`` for the strict hardware evidence gate.",
  "17. Run ``RUN_CONSUMER_PROMOTION_CHECK.cmd`` only after strict evidence verification passes.",
  "",
  "## Gates Still Expected",
  "",
  "- Hardware validation remains pending until this packet has real display, servo, soak, calibration, photo/video, and speaker evidence.",
  "- ``RUN_HARDWARE_SIM_BASELINE.cmd`` is a pre-arrival rehearsal only. It does not satisfy display, mic, speaker, servo, soak, or promotion evidence gates.",
  "- Production voice-source provenance remains pending until the owned or licensed source record is completed.",
  "- RVC voice-base evidence remains review-only until consumer and distribution approvals are explicitly recorded.",
  "- GitHub Actions may still be externally blocked; use ``RUN_ROLLOUT_STATUS.cmd`` for the current CI/account state.",
  "- Hosted media or synthetic diagnostic packets are review aids only. They do not replace real-device evidence.",
  "",
  "## Hard Stops",
  "",
  "- Do not run servo calibration unless the body is clear and supervised.",
  "- Do not mark the audio gate complete without a recording captured from the actual target speaker path.",
  "- Do not use ``-AllowExternalAccountCiBlock`` silently. ``CI_ACCOUNT_BLOCK_EXCEPTION_TEMPLATE.json`` starts unapproved with TBD fields and false proof booleans.",
  "- Do not promote if ``CHECKLIST.md`` still has unchecked gates or ``RUN_PROGRESS_CHECK.cmd`` reports missing evidence.",
  "- Do not treat generated samples, local previews, or hosted review pages as consumer rollout evidence."
)
$nextSteps | Set-Content -Path (Join-Path $outDir "NEXT_STEPS.md") -Encoding UTF8

$readme = @(
  "# Stackchan Hardware Evidence Packet",
  "",
  "Use this folder as the record for one device bring-up session. Start with NEXT_STEPS.md for the short run order, then complete CHECKLIST.md and OBSERVATIONS.md, save serial logs under logs/, and place real photos or short videos under photos/.",
  "",
  "The runnable command files in this folder are generated for this release, port, package, and evidence path.",
  "",
  "``RUN_HARDWARE_SIM_BASELINE.cmd`` can be run before the robot arrives. It writes the full virtual Stackchan proxy report, including the fake mic/STT/model/TTS/speaker loop, under ``simulation/hardware-sim/latest/`` and logs the command to ``logs/hardware_simulation_baseline.log``. Treat it as a comparison baseline only, not hardware evidence.",
  "",
  "``RUN_SIM_HARDWARE_COMPARE.cmd`` can be run after display, speech-mouth, speak-all, and bridge replay logs exist. It writes ``SIM_HARDWARE_COMPARE.md`` and ``SIM_HARDWARE_COMPARE.json`` as an advisory sim-vs-real serial marker comparison. A pending report means more bench logs are needed; a passing report still does not satisfy hardware promotion gates by itself.",
  "",
  "BENCH_STATUS.md is the quick handoff file. RUN_PROGRESS_CHECK.cmd refreshes it with the current status, next action, next command, top findings, and matching BENCH_STATUS.json machine-readable report.",
  "",
  "RELEASE_ACCEPTANCE.md and release_acceptance.json record the no-hardware gates that were already accepted and the hardware gates still required before consumer rollout.",
  "",
  "Promotion verification expects OBSERVATIONS.md to record passing values: Result = pass/ok/success, reset/heat/brownout/stall/jitter observed = no, procedural face and dry-run servo log observed = yes, yaw classification = angle/velocity/disabled, soak Duration >= 30 minutes, and USB power-cycle recovery = pass/ok/success.",
  "",
  "Promotion verification expects AUDIO_REVIEW.md to record a real-device speaker check: intelligible = yes, clipping/distortion = no, volume adequate = yes, delay/dropout = no, and a speaker recording file saved under audio/.",
  "",
  "Promotion verification also expects serial logs to include firmware markers: display-only boot ``mode=display_only``, servo-calibration boot ``mode=servo_calibration``, display readiness, servo dry-run or hardware-enable line, runtime health telemetry ``[system] heap_free=... stack_face_hwm=...``, and soak heartbeat ``[heartbeat] stackchan_alive ... uptime_ms=...``.",
  "",
  "Promotion verification also requires at least one valid media file under photos/: .png, .jpg, .jpeg, .gif, .mp4, .mov, or .webm. Text placeholders, header-only files, tiny files, and images without plausible dimensions do not count as photo/video evidence.",
  "",
  "Use ``RUN_ADD_MEDIA.cmd`` to import phone photos, videos, and target-speaker recordings. It copies files into ``photos/`` or ``audio/``, validates media headers, and records SHA256 hashes in ``media_manifest.json``.",
  "",
  "The packet includes ``RVC_LEAD_AUDITION.md`` and ``reference_audio/`` with the current lead voice audition copied from the verified release package. Use ``RUN_PLAY_LEAD_VOICE.cmd`` as a playback aid for the speaker check, then record the actual device speaker and import that recording under ``audio/``.",
  "",
  "The packet also includes ``VOICE_SOURCE_STATUS.md/json`` and ``RVC_VOICE_BASE_STATUS.md/json`` copied from the verified release package. These reports document that current voice samples and RVC base evidence are review-only until the production voice-source gate is cleared.",
  "",
  "If present, ``HOSTED_MEDIA_REFERENCE.md`` records the verified Cloudflare/share page for this release. Use it as the remote review reference for the image, video, face GIFs, and voice samples while still collecting real-device evidence locally.",
  "",
  "## Suggested Commands",
  "",
  "No-hardware simulation baseline:",
  "",
  "    $hardwareSimBaselineCommand",
  "",
  "    .\RUN_HARDWARE_SIM_BASELINE.cmd",
  "",
  "Compare the simulator baseline against captured hardware serial logs:",
  "",
  "    $simHardwareCompareCommand",
  "",
  "    .\RUN_SIM_HARDWARE_COMPARE.cmd",
  "",
  "Display-only flash:",
  "",
  "    $displayCommand",
  "",
  "    .\RUN_DISPLAY_ONLY.cmd",
  "",
  "Speech mouth demo:",
  "",
  "    $speechDemoCommand",
  "",
  "    .\RUN_SPEECH_MOUTH_DEMO.cmd",
  "",
  "Speak all packaged intents:",
  "",
  "    $speakAllCommand",
  "",
  "    .\RUN_SPEAK_ALL_INTENTS.cmd",
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
  "Play the lead voice reference for speaker testing:",
  "",
  "    $playLeadCommand",
  "",
  "    .\RUN_PLAY_LEAD_VOICE.cmd",
  "",
  "Before promotion, verify the release ZIP:",
  "",
  "    $verifyCommand",
  "",
  "    .\RUN_PACKAGE_VERIFY.cmd",
  "",
  "The packet creation command automatically writes ``logs/package_verify.log`` when ``-PackageZip`` is provided.",
  "",
  "Import display/motion photos or videos:",
  "",
  "    $addMediaCommand -Type Photo C:\path\stackchan-face.jpg",
  "",
  "    .\RUN_ADD_MEDIA.cmd -Type Photo C:\path\stackchan-face.jpg",
  "",
  "Import a real-device speaker recording. Use ``-Type Audio`` for phone video recordings of the speaker so .mp4/.mov files go under ``audio/``:",
  "",
  "    $addMediaCommand -Type Audio C:\path\stackchan-speaker.wav",
  "",
  "    .\RUN_ADD_MEDIA.cmd -Type Audio C:\path\stackchan-speaker.wav",
  "",
  "Before marking a release hardware-validated, verify this evidence packet:",
  "",
  "    $progressCommand",
  "",
  "    .\RUN_PROGRESS_CHECK.cmd",
  "",
  "This refreshes ``BENCH_STATUS.md`` and ``BENCH_STATUS.json`` with the current next bench action.",
  "",
  "Export the current package/evidence/CI/voice rollout summary:",
  "",
  "    $rolloutStatusCommand",
  "",
  "    .\RUN_ROLLOUT_STATUS.cmd",
  "",
  "This writes ``ROLLOUT_STATUS.md`` and ``ROLLOUT_STATUS.json`` into the packet for handoff review.",
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
  "If GitHub Actions is still externally blocked by account billing, spending limits, or pre-runner allocation, do not use ``-AllowExternalAccountCiBlock`` silently. Complete ``CI_ACCOUNT_BLOCK_EXCEPTION_TEMPLATE.json`` and pass it with ``-ExternalAccountCiExceptionPath``.",
  "",
  "Do not promote this release until every gate in CHECKLIST.md has explicit evidence."
)
$readme | Set-Content -Path (Join-Path $outDir "README.md") -Encoding UTF8

$initialBenchStatus = [ordered]@{
  schema = "stackchan.bench-status.v1"
  evidenceRoot = $outDir
  generatedUtc = $createdUtc
  status = "not-yet-checked"
  nextAction = "Run the progress check to generate the current bench handoff summary."
  nextCommand = "RUN_PROGRESS_CHECK.cmd"
  reason = "Initial evidence packet scaffold; hardware evidence has not been checked yet."
  findingCount = $null
  passCount = $null
  findings = @()
  passes = @()
}
$initialBenchStatus | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $outDir "BENCH_STATUS.json") -Encoding UTF8
@(
  "# Stackchan Bench Status",
  "",
  "- Schema: stackchan.bench-status.v1",
  "- Generated UTC: $createdUtc",
  "- Status: not-yet-checked",
  "- Next action: Run the progress check to generate the current bench handoff summary.",
  "- Next command: ``RUN_PROGRESS_CHECK.cmd``",
  "- Reason: Initial evidence packet scaffold; hardware evidence has not been checked yet.",
  "",
  "Run ``RUN_PROGRESS_CHECK.cmd`` after each bench step to refresh this file."
) | Set-Content -Path (Join-Path $outDir "BENCH_STATUS.md") -Encoding UTF8

$requiredRecords = @(
  "BENCH_STATUS.md",
  "BENCH_STATUS.json",
  "NEXT_STEPS.md",
  "CHECKLIST.md",
  "RELEASE_ACCEPTANCE.md",
  "release_acceptance.json",
  "OBSERVATIONS.md",
  "AUDIO_REVIEW.md",
  "CI_ACCOUNT_BLOCK_EXCEPTION_TEMPLATE.json",
  "calibration/calibration.yaml",
  "RUN_PLAY_LEAD_VOICE.cmd",
  "RUN_HARDWARE_SIM_BASELINE.cmd",
  "RUN_DISPLAY_ONLY.cmd",
  "RUN_SPEECH_MOUTH_DEMO.cmd",
  "RUN_SPEAK_ALL_INTENTS.cmd",
  "RUN_BRIDGE_REPLAY.cmd",
  "RUN_SERVO_CALIBRATION.cmd",
  "RUN_SOAK_MONITOR.cmd",
  "RUN_PACKAGE_VERIFY.cmd",
  "RUN_SIM_HARDWARE_COMPARE.cmd",
  "RUN_PROGRESS_CHECK.cmd",
  "RUN_ROLLOUT_STATUS.cmd",
  "RUN_ADD_MEDIA.cmd",
  "RUN_EVIDENCE_VERIFY.cmd",
  "RUN_CONSUMER_PROMOTION_CHECK.cmd"
)
if ($voiceLeadInfo) {
  $requiredRecords += @(
    "RVC_LEAD_AUDITION.md",
    [string]$voiceLeadInfo.referenceFile,
    "reference_audio/RVC_AUDITIONS.md",
    "reference_audio/RVC_AUDITIONS.json"
  )
}
if ($shareVerificationInfo) {
  $requiredRecords += @(
    "HOSTED_MEDIA_REFERENCE.md",
    "share/share_status.json",
    "share/share_verification_report.md",
    "share/share_verification_report.json",
    "share/VERIFIED_URL.txt"
  )
}
if ($voiceGateInfo) {
  $requiredRecords += @(
    "VOICE_SOURCE_STATUS.md",
    "voice_source_status.json",
    "RVC_VOICE_BASE_STATUS.md",
    "rvc_voice_base_status.json"
  )
}

$metadata = [ordered]@{
  releaseTag = $ReleaseTag
  commit = $commit
  branch = $branch
  createdUtc = $createdUtc
  operator = $Operator
  deviceId = $DeviceId
  port = $Port
  package = $packageInfo
  voiceLeadAudition = $voiceLeadInfo
  voiceGateStatus = $voiceGateInfo
  shareVerification = $shareVerificationInfo
  simulationBaseline = [ordered]@{
    command = "RUN_HARDWARE_SIM_BASELINE.cmd"
    report = "simulation/hardware-sim/latest/hardware_simulation.json"
    log = "logs/hardware_simulation_baseline.log"
    compareCommand = "RUN_SIM_HARDWARE_COMPARE.cmd"
    compareReport = "SIM_HARDWARE_COMPARE.json"
    compareSummary = "SIM_HARDWARE_COMPARE.md"
    evidenceRole = "pre-arrival comparison baseline only"
  }
  requiredLogs = $requiredLogs
  requiredRecords = $requiredRecords
  benchStatus = [ordered]@{
    summary = "BENCH_STATUS.md"
    report = "BENCH_STATUS.json"
    refreshCommand = "RUN_PROGRESS_CHECK.cmd"
  }
  promotionVerifier = "tools/verify_consumer_promotion.ps1"
  hardwareEvidenceVerifier = "tools/verify_hardware_evidence.ps1"
}

$metadata | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $outDir "metadata.json") -Encoding UTF8

New-Item -ItemType File -Force -Path (Join-Path $logsDir ".gitkeep") | Out-Null
New-Item -ItemType File -Force -Path (Join-Path $photosDir ".gitkeep") | Out-Null
New-Item -ItemType File -Force -Path (Join-Path $audioDir ".gitkeep") | Out-Null

Write-Host "Hardware evidence packet:"
Write-Output $outDir
