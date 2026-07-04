param(
  [string]$Version = "",
  [string]$PackageRoot = "",
  [string]$PackageZip = "",
  [string]$EvidenceRoot = "",
  [string]$OutDir = "",
  [string]$ActionsStatusPath = "",
  [string]$ExpectedCommit = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

$cleanupDir = $null

function Join-ResolvedPath {
  param(
    [string]$Root,
    [string]$RelativePath
  )
  return Join-Path $Root ($RelativePath -replace "/", "\")
}

function Read-JsonFile {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
    return $null
  }
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Invoke-ToolCapture {
  param([string[]]$Arguments)

  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File @Arguments 2>&1
    return [ordered]@{
      exitCode = $LASTEXITCODE
      text = ($output | Out-String).TrimEnd()
    }
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
}

function Add-Gate {
  param(
    [System.Collections.Generic.List[object]]$List,
    [string]$Gate,
    [string]$Status,
    [string]$Evidence,
    [string]$Owner = "local"
  )

  $List.Add([ordered]@{
      gate = $Gate
      status = $Status
      evidence = $Evidence
      owner = $Owner
    }) | Out-Null
}

function Get-SpeechMouthDemoEvidenceStatus {
  param([string]$EvidenceRoot)

  $logPath = Join-Path $EvidenceRoot "logs/speech_mouth_demo_serial.log"
  $speakAllLogPath = Join-Path $EvidenceRoot "logs/speak_all_intents_serial.log"
  if (-not (Test-Path -LiteralPath $logPath)) {
    return [ordered]@{
      status = "pending"
      evidence = "logs/speech_mouth_demo_serial.log is missing"
    }
  }
  if (-not (Test-Path -LiteralPath $speakAllLogPath)) {
    return [ordered]@{
      status = "pending"
      evidence = "logs/speak_all_intents_serial.log is missing"
    }
  }

  $text = Get-Content -LiteralPath $logPath -Raw
  $speakAllText = Get-Content -LiteralPath $speakAllLogPath -Raw
  $missing = New-Object System.Collections.Generic.List[string]
  if ($text -notmatch "\[demo\]\s+>\s+speech\s+[0-9]") {
    $missing.Add("streamed speech envelope command") | Out-Null
  }
  if ($text -notmatch "\[demo\]\s+>\s+speech clear") {
    $missing.Add("speech clear command") | Out-Null
  }
  if ($text -notmatch "\[demo\]\s+Speech mouth demo complete\.") {
    $missing.Add("completion marker") | Out-Null
  }
  foreach ($intentName in @("boot", "idle", "attend", "listen", "think", "speak", "react", "happy", "concern", "sleep", "error", "safety")) {
    if ($speakAllText -notmatch "\[speak-all\]\s+>\s+speak\s+$intentName\b") {
      $missing.Add("speak-all $intentName command") | Out-Null
    }
    if ($speakAllText -notmatch "\[control\]\s+command=speak_intent.*cue_intent=$intentName.*cue_earcon=\w+") {
      $missing.Add("speak-all $intentName cue") | Out-Null
    }
  }
  if ($speakAllText -notmatch "\[audio_out\]\s+seq=\d+\s+source=packaged_prompt\s+prompt_id=") {
    $missing.Add("packaged prompt audio-output handoff") | Out-Null
  }
  if ($speakAllText -notmatch "\[speak-all\]\s+Speak-all-intents demo complete\.") {
    $missing.Add("speak-all completion marker") | Out-Null
  }

  if ($missing.Count -gt 0) {
    return [ordered]@{
      status = "pending"
      evidence = "speech evidence logs missing $($missing -join ', ')"
    }
  }

  return [ordered]@{
    status = "pass"
    evidence = "logs/speech_mouth_demo_serial.log and logs/speak_all_intents_serial.log prove streamed speech envelope, packaged speech intents, earcons, and audio-output handoff"
  }
}

function Get-VoiceGateStatusMismatches {
  param(
    [object]$MetadataVoiceGateStatus,
    [object]$VoiceSourceStatus,
    [object]$RvcVoiceBaseStatus
  )

  $mismatches = New-Object System.Collections.Generic.List[string]
  if ($null -eq $MetadataVoiceGateStatus) {
    $mismatches.Add("metadata.json missing voiceGateStatus reference") | Out-Null
    return @($mismatches.ToArray())
  }

  foreach ($field in @("voiceSourceStatus", "voiceSourceBlockedGateCount", "rvcVoiceBaseStatus", "rvcConsumerApproved", "rvcDistributionApproved")) {
    if ($null -eq $MetadataVoiceGateStatus.$field -or [string]::IsNullOrWhiteSpace([string]$MetadataVoiceGateStatus.$field)) {
      $mismatches.Add("metadata voiceGateStatus missing required field: $field") | Out-Null
    }
  }

  if ($null -eq $VoiceSourceStatus) {
    $mismatches.Add("voice_source_status.json is missing from the release package") | Out-Null
  } else {
    if ($VoiceSourceStatus.schema -ne "stackchan.voice-source-status.v1") {
      $mismatches.Add("voice_source_status.json schema mismatch: $($VoiceSourceStatus.schema)") | Out-Null
    }
    if ([string]$VoiceSourceStatus.status -ne [string]$MetadataVoiceGateStatus.voiceSourceStatus) {
      $mismatches.Add("voice_source_status.json status does not match metadata voiceGateStatus") | Out-Null
    }
    if ([int]$VoiceSourceStatus.blockedGateCount -ne [int]$MetadataVoiceGateStatus.voiceSourceBlockedGateCount) {
      $mismatches.Add("voice_source_status.json blockedGateCount does not match metadata voiceGateStatus") | Out-Null
    }
  }

  if ($null -eq $RvcVoiceBaseStatus) {
    $mismatches.Add("rvc_voice_base_status.json is missing from the release package") | Out-Null
  } else {
    if ($RvcVoiceBaseStatus.schema -ne "stackchan.rvc-voice-base-status.v1") {
      $mismatches.Add("rvc_voice_base_status.json schema mismatch: $($RvcVoiceBaseStatus.schema)") | Out-Null
    }
    if ([string]$RvcVoiceBaseStatus.status -ne [string]$MetadataVoiceGateStatus.rvcVoiceBaseStatus) {
      $mismatches.Add("rvc_voice_base_status.json status does not match metadata voiceGateStatus") | Out-Null
    }
    if ([bool]$RvcVoiceBaseStatus.consumerApproved -ne [bool]$MetadataVoiceGateStatus.rvcConsumerApproved) {
      $mismatches.Add("rvc_voice_base_status.json consumerApproved does not match metadata voiceGateStatus") | Out-Null
    }
    if ([bool]$RvcVoiceBaseStatus.distributionApproved -ne [bool]$MetadataVoiceGateStatus.rvcDistributionApproved) {
      $mismatches.Add("rvc_voice_base_status.json distributionApproved does not match metadata voiceGateStatus") | Out-Null
    }
  }

  return @($mismatches.ToArray())
}

function Get-AndroidProbeEvidenceStatus {
  param(
    [string]$EvidenceRoot,
    [object]$Metadata
  )

  if ($null -eq $Metadata -or $null -eq $Metadata.androidCompanionProbes) {
    return [ordered]@{
      status = "pass"
      evidence = "No Android companion probe metadata; optional unless Android is the bridge host"
      reports = @()
    }
  }

  $probeConfig = $Metadata.androidCompanionProbes
  $reports = @(
    [ordered]@{
      label = "Android APK install evidence"
      path = [string]$probeConfig.apkInstallReport
      schema = "stackchan.android-apk-install.v1"
      passingStatuses = @("installed")
    },
    [ordered]@{
      label = "Android companion bridge probe"
      path = [string]$probeConfig.companionProbeReport
      schema = "stackchan.android-companion-probe.v1"
      passingStatuses = @("pass")
    },
    [ordered]@{
      label = "Android screen-off soak"
      path = [string]$probeConfig.screenOffSoakReport
      schema = "stackchan.android-companion-soak.v1"
      passingStatuses = @("pass")
    },
    [ordered]@{
      label = "Android UDP beacon probe"
      path = [string]$probeConfig.udpBeaconProbeReport
      schema = "stackchan.android-udp-beacon-probe.v1"
      passingStatuses = @("pass")
    },
    [ordered]@{
      label = "Android companion logcat capture"
      path = [string]$probeConfig.logcatReport
      schema = "stackchan.android-companion-logcat.v1"
      passingStatuses = @("captured")
    }
  )

  $present = New-Object System.Collections.Generic.List[string]
  $missing = New-Object System.Collections.Generic.List[string]
  $failures = New-Object System.Collections.Generic.List[string]
  foreach ($probe in $reports) {
    if ([string]::IsNullOrWhiteSpace([string]$probe.path)) {
      $missing.Add("$($probe.label) has no configured report path") | Out-Null
      continue
    }
    $path = Join-Path $EvidenceRoot (([string]$probe.path) -replace "/", "\")
    if (-not (Test-Path -LiteralPath $path)) {
      $missing.Add("$($probe.label) missing at $($probe.path)") | Out-Null
      continue
    }

    $report = Read-JsonFile $path
    if ($null -eq $report) {
      $failures.Add("$($probe.label) report could not be read") | Out-Null
    } elseif ($report.schema -ne [string]$probe.schema) {
      $failures.Add("$($probe.label) schema mismatch: $($report.schema)") | Out-Null
    } elseif (@($probe.passingStatuses) -notcontains [string]$report.status) {
      $issues = @($report.issues) -join "; "
      $failures.Add("$($probe.label) status $($report.status): $issues") | Out-Null
    } elseif ([string]$probe.schema -eq "stackchan.android-apk-install.v1" -and
        [string]$report.apkSha256 -notmatch "^[0-9a-fA-F]{64}$") {
      $failures.Add("$($probe.label) is missing a valid apkSha256") | Out-Null
    } elseif ([string]$probe.schema -eq "stackchan.android-apk-install.v1" -and
        [string]$report.sourceCommit -notmatch "^[0-9a-fA-F]{40}$") {
      $failures.Add("$($probe.label) is missing a full sourceCommit SHA; re-run RUN_ANDROID_APK_INSTALL.cmd with -SourceCommit <git-commit>") | Out-Null
    } elseif ([string]$probe.schema -eq "stackchan.android-apk-install.v1" -and
        ([string]::IsNullOrWhiteSpace([string]$report.versionName) -or
         [string]::IsNullOrWhiteSpace([string]$report.versionCode))) {
      $failures.Add("$($probe.label) is missing installed versionName/versionCode") | Out-Null
    } else {
      $present.Add("$($probe.label) status $($report.status) at $($probe.path)") | Out-Null
    }
  }

  if ($failures.Count -gt 0) {
    return [ordered]@{
      status = "blocked"
      evidence = $failures -join "; "
      reports = @($present.ToArray())
      missing = @($missing.ToArray())
    }
  }
  if ($present.Count -gt 0) {
    $evidence = $present -join "; "
    if ($missing.Count -gt 0) {
      $evidence += "; optional report not present: $($missing -join '; ')"
    }
    return [ordered]@{
      status = "pass"
      evidence = $evidence
      reports = @($present.ToArray())
      missing = @($missing.ToArray())
    }
  }

  return [ordered]@{
    status = "pass"
    evidence = "Android companion probe reports not present; optional unless Android is the bridge host"
    reports = @()
    missing = @($missing.ToArray())
  }
}

function Get-FirstGate {
  param(
    [object[]]$Gates,
    [string]$Gate
  )

  foreach ($item in @($Gates)) {
    if ([string]$item.gate -eq $Gate) {
      return $item
    }
  }
  return $null
}

function Get-RolloutNextAction {
  param(
    [object[]]$Gates,
    [object]$ActionsStatus,
    [object]$EvidenceSummary,
    [string]$ReleaseVersion
  )

  $manifestGate = Get-FirstGate -Gates $Gates -Gate "release-package-manifest"
  if ($null -ne $manifestGate -and [string]$manifestGate.status -ne "pass") {
    return [ordered]@{
      owner = "package"
      action = "Regenerate or verify the release package so release_manifest.json matches the expected commit."
      command = ".\tools\package_release.cmd -Version $ReleaseVersion"
      reason = [string]$manifestGate.evidence
    }
  }

  $progressGate = Get-FirstGate -Gates $Gates -Gate "hardware-evidence-progress"
  $speechMouthGate = Get-FirstGate -Gates $Gates -Gate "speech-mouth-demo-evidence"
  if ($null -ne $speechMouthGate -and [string]$speechMouthGate.status -ne "pass" -and $null -ne $EvidenceSummary -and -not [string]::IsNullOrWhiteSpace([string]$EvidenceSummary.root)) {
    return [ordered]@{
      owner = "hardware"
      action = "Run the speech-mouth and speak-all-intents demos while display-only firmware is connected, then refresh progress and rollout status."
      command = "RUN_SPEECH_MOUTH_DEMO.cmd; RUN_SPEAK_ALL_INTENTS.cmd"
      reason = [string]$speechMouthGate.evidence
    }
  }

  if ($null -ne $progressGate -and [string]$progressGate.status -ne "pass") {
    if ($null -ne $EvidenceSummary -and -not [string]::IsNullOrWhiteSpace([string]$EvidenceSummary.root)) {
      $benchStatus = Read-JsonFile (Join-Path ([string]$EvidenceSummary.root) "BENCH_STATUS.json")
      if ($null -ne $benchStatus -and -not [string]::IsNullOrWhiteSpace([string]$benchStatus.nextAction)) {
        return [ordered]@{
          owner = "hardware"
          action = [string]$benchStatus.nextAction
          command = [string]$benchStatus.nextCommand
          reason = [string]$benchStatus.reason
        }
      }
    }
    return [ordered]@{
      owner = "hardware"
      action = "Create or refresh the hardware evidence packet and run its progress check."
      command = ".\tools\start_hardware_evidence.cmd -ReleaseTag $ReleaseVersion -PackageZip output\release\stackchan_alive_$ReleaseVersion.zip -Port COM3 -Operator `"Your Name`" -DeviceId STACKCHAN-001"
      reason = [string]$progressGate.evidence
    }
  }

  $strictGate = Get-FirstGate -Gates $Gates -Gate "strict-hardware-evidence"
  if ($null -ne $strictGate -and [string]$strictGate.status -ne "pass") {
    return [ordered]@{
      owner = "hardware"
      action = "Run the strict hardware evidence verifier on the completed packet."
      command = "RUN_EVIDENCE_VERIFY.cmd"
      reason = [string]$strictGate.evidence
    }
  }

  $voiceGate = Get-FirstGate -Gates $Gates -Gate "production-voice-source"
  if ($null -ne $voiceGate -and [string]$voiceGate.status -ne "pass") {
    return [ordered]@{
      owner = "voice"
      action = "Complete production voice-source provenance with an owned or licensed source before consumer promotion."
      command = "notepad docs\VOICE_SOURCE_PROVENANCE_TEMPLATE.md"
      reason = [string]$voiceGate.evidence
    }
  }

  $rvcGate = Get-FirstGate -Gates $Gates -Gate "rvc-voice-base-approval"
  if ($null -ne $rvcGate -and [string]$rvcGate.status -ne "pass") {
    return [ordered]@{
      owner = "voice"
      action = "Resolve or replace the review-only RVC base before consumer distribution."
      command = ".\tools\export_rvc_voice_base_status.cmd"
      reason = [string]$rvcGate.evidence
    }
  }

  $voiceConsistencyGate = Get-FirstGate -Gates $Gates -Gate "voice-gate-status-consistency"
  if ($null -ne $voiceConsistencyGate -and [string]$voiceConsistencyGate.status -ne "pass") {
    return [ordered]@{
      owner = "voice"
      action = "Regenerate the evidence packet or copy the current package voice status reports so metadata voiceGateStatus matches."
      command = "RUN_PROGRESS_CHECK.cmd"
      reason = [string]$voiceConsistencyGate.evidence
    }
  }

  $actionsGate = Get-FirstGate -Gates $Gates -Gate "github-actions"
  if ($null -ne $actionsGate -and [string]$actionsGate.status -ne "pass") {
    $action = if ($null -ne $ActionsStatus -and -not [string]::IsNullOrWhiteSpace([string]$ActionsStatus.nextAction)) {
      [string]$ActionsStatus.nextAction
    } else {
      "Refresh GitHub Actions status after hosted workflows can run."
    }
    $command = if ($null -ne $ActionsStatus -and -not [string]::IsNullOrWhiteSpace([string]$ActionsStatus.nextCommand)) {
      [string]$ActionsStatus.nextCommand
    } else {
      ".\tools\export_github_actions_status.cmd -Version $ReleaseVersion"
    }
    return [ordered]@{
      owner = "github"
      action = $action
      command = $command
      reason = [string]$actionsGate.evidence
    }
  }

  return [ordered]@{
    owner = "release"
    action = "Run the consumer promotion verifier."
    command = ".\tools\verify_consumer_promotion.cmd -Version $ReleaseVersion"
    reason = "All rollout status gates are passing."
  }
}

try {
  if (-not [string]::IsNullOrWhiteSpace($PackageZip)) {
    if (-not (Test-Path -LiteralPath $PackageZip)) {
      throw "Missing package ZIP: $PackageZip"
    }
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "stackchan-rollout-status"
    $cleanupDir = Join-Path $tempRoot ([System.Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $cleanupDir | Out-Null
    Expand-Archive -LiteralPath $PackageZip -DestinationPath $cleanupDir
    $PackageRoot = $cleanupDir
  }

  if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = (git describe --tags --always --dirty).Trim()
  }
  if ([string]::IsNullOrWhiteSpace($ExpectedCommit)) {
    $ExpectedCommit = (git rev-parse HEAD).Trim()
  }
  if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
    $PackageRoot = Join-Path $repoRoot "output/release/$Version"
  }
  if (-not (Test-Path -LiteralPath $PackageRoot)) {
    throw "Missing package root: $PackageRoot"
  }
  $packageRootPath = (Resolve-Path $PackageRoot).Path

  if ([string]::IsNullOrWhiteSpace($OutDir)) {
    if (-not [string]::IsNullOrWhiteSpace($EvidenceRoot)) {
      $OutDir = $EvidenceRoot
    } else {
      $OutDir = Join-Path $repoRoot "output/rollout-status/$Version"
    }
  }
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  $outPath = (Resolve-Path $OutDir).Path

  $manifest = Read-JsonFile (Join-ResolvedPath $packageRootPath "release_manifest.json")
  $readiness = Read-JsonFile (Join-ResolvedPath $packageRootPath "readiness_report.json")
  $actionsStatusSource = if ([string]::IsNullOrWhiteSpace($ActionsStatusPath)) {
    Join-ResolvedPath $packageRootPath "github_actions_status.json"
  } else {
    $ActionsStatusPath
  }
  $actions = Read-JsonFile $actionsStatusSource
  $voice = Read-JsonFile (Join-ResolvedPath $packageRootPath "voice_source_status.json")
  $rvcVoiceBase = Read-JsonFile (Join-ResolvedPath $packageRootPath "rvc_voice_base_status.json")

  if ($null -ne $manifest) {
    $Version = [string]$manifest.version
    $ExpectedCommit = [string]$manifest.commit
  }

  $gates = New-Object System.Collections.Generic.List[object]
  $blockers = New-Object System.Collections.Generic.List[string]

  if ($null -ne $manifest -and $manifest.commit -eq $ExpectedCommit) {
    Add-Gate $gates "release-package-manifest" "pass" "release_manifest.json commit matches $ExpectedCommit"
  } else {
    Add-Gate $gates "release-package-manifest" "blocked" "release_manifest.json is missing or does not match $ExpectedCommit"
    $blockers.Add("Release package manifest is missing or commit-mismatched.") | Out-Null
  }

  if ($null -ne $readiness -and $readiness.consumerRollout -eq "blocked-pending-hardware-validation") {
    Add-Gate $gates "no-hardware-readiness" "pass" "readiness_report.json documents test-ready prerelease state"
  } else {
    Add-Gate $gates "no-hardware-readiness" "review" "readiness_report.json is missing or has unexpected consumer rollout state"
  }

  $actionsStatus = if ($null -ne $actions) { [string]$actions.status } else { "missing" }
  $missingRequiredActionWorkflows = if ($null -ne $actions) { @($actions.missingRequiredWorkflows | ForEach-Object { [string]$_ }) } else { @() }
  if ($missingRequiredActionWorkflows.Count -gt 0) {
    Add-Gate $gates "github-actions-required-workflows" "blocked" "Missing required workflow evidence: $($missingRequiredActionWorkflows -join ', ')" "github"
    $blockers.Add("GitHub Actions status is missing required workflow evidence: $($missingRequiredActionWorkflows -join ', ').") | Out-Null
  } else {
    Add-Gate $gates "github-actions-required-workflows" "pass" "Required workflow evidence observed or status predates this check" "github"
  }

  if ($actionsStatus -eq "success") {
    Add-Gate $gates "github-actions" "pass" "github_actions_status.json reports success" "github"
  } elseif (@("external-account-billing-or-spending-limit", "external-account-ci-pre-runner-allocation") -contains $actionsStatus) {
    Add-Gate $gates "github-actions" "blocked-external" "GitHub Actions status: $actionsStatus" "github"
    $blockers.Add("GitHub Actions is externally blocked: $actionsStatus.") | Out-Null
  } else {
    Add-Gate $gates "github-actions" "blocked" "GitHub Actions status: $actionsStatus" "github"
    $blockers.Add("GitHub Actions is not promotion-ready: $actionsStatus.") | Out-Null
  }

  $voiceStatus = if ($null -ne $voice) { [string]$voice.status } else { "missing" }
  if ($voiceStatus -eq "production-source-ready") {
    Add-Gate $gates "production-voice-source" "pass" "voice_source_status.json reports production-source-ready" "voice"
  } else {
    Add-Gate $gates "production-voice-source" "blocked" "Voice source status: $voiceStatus" "voice"
    $blockers.Add("Production voice source is not cleared: $voiceStatus.") | Out-Null
  }

  if ($null -eq $rvcVoiceBase) {
    Add-Gate $gates "rvc-voice-base-approval" "blocked" "rvc_voice_base_status.json is missing" "voice"
    $blockers.Add("RVC voice base approval report is missing.") | Out-Null
  } elseif ([bool]$rvcVoiceBase.consumerApproved -and [bool]$rvcVoiceBase.distributionApproved -and [int]$rvcVoiceBase.blockedGateCount -eq 0 -and [int]$rvcVoiceBase.failedGateCount -eq 0) {
    Add-Gate $gates "rvc-voice-base-approval" "pass" "RVC base is consumer and distribution approved" "voice"
  } else {
    Add-Gate $gates "rvc-voice-base-approval" "blocked" "RVC base status: $($rvcVoiceBase.status), consumerApproved=$($rvcVoiceBase.consumerApproved), distributionApproved=$($rvcVoiceBase.distributionApproved)" "voice"
    $blockers.Add("RVC voice base is not approved for consumer distribution.") | Out-Null
  }

  $evidenceSummary = $null
  if (-not [string]::IsNullOrWhiteSpace($EvidenceRoot)) {
    if (-not (Test-Path -LiteralPath $EvidenceRoot)) {
      throw "Missing evidence packet: $EvidenceRoot"
    }
    $evidencePath = (Resolve-Path $EvidenceRoot).Path
    $progress = Invoke-ToolCapture @((Join-Path $PSScriptRoot "check_hardware_evidence_progress.ps1"), "-EvidenceRoot", $evidencePath)
    $strict = Invoke-ToolCapture @((Join-Path $PSScriptRoot "verify_hardware_evidence.ps1"), "-EvidenceRoot", $evidencePath)
    $metadata = Read-JsonFile (Join-Path $evidencePath "metadata.json")
    $speechMouth = Get-SpeechMouthDemoEvidenceStatus -EvidenceRoot $evidencePath
    $androidProbes = Get-AndroidProbeEvidenceStatus -EvidenceRoot $evidencePath -Metadata $metadata

    if ($progress.exitCode -eq 0) {
      Add-Gate $gates "hardware-evidence-progress" "pass" "RUN_PROGRESS_CHECK has no obvious gaps" "hardware"
    } else {
      Add-Gate $gates "hardware-evidence-progress" "pending" "RUN_PROGRESS_CHECK exit code $($progress.exitCode)" "hardware"
      $blockers.Add("Hardware evidence progress still has gaps.") | Out-Null
    }

    if ($strict.exitCode -eq 0) {
      Add-Gate $gates "strict-hardware-evidence" "pass" "verify_hardware_evidence.ps1 passed" "hardware"
    } else {
      Add-Gate $gates "strict-hardware-evidence" "pending" "verify_hardware_evidence.ps1 exit code $($strict.exitCode)" "hardware"
      $blockers.Add("Strict hardware evidence verification has not passed.") | Out-Null
    }

    Add-Gate $gates "speech-mouth-demo-evidence" ([string]$speechMouth.status) ([string]$speechMouth.evidence) "hardware"
    if ([string]$speechMouth.status -ne "pass") {
      $blockers.Add("Speech-mouth demo evidence has not passed: $($speechMouth.evidence).") | Out-Null
    }

    Add-Gate $gates "android-companion-probes" ([string]$androidProbes.status) ([string]$androidProbes.evidence) "android"
    if ([string]$androidProbes.status -ne "pass") {
      $blockers.Add("Android companion probe evidence has not passed: $($androidProbes.evidence).") | Out-Null
    }

    if ($null -ne $metadata -and $null -ne $metadata.shareVerification) {
      Add-Gate $gates "hosted-media-reference" "pass" "HOSTED_MEDIA_REFERENCE.md and share verification metadata are pinned" "share"
    } else {
      Add-Gate $gates "hosted-media-reference" "review" "No shareVerification metadata in evidence packet" "share"
    }

    $voiceGateMismatches = @(Get-VoiceGateStatusMismatches -MetadataVoiceGateStatus $metadata.voiceGateStatus -VoiceSourceStatus $voice -RvcVoiceBaseStatus $rvcVoiceBase)
    if ($voiceGateMismatches.Count -eq 0) {
      Add-Gate $gates "voice-gate-status-consistency" "pass" "Evidence metadata voiceGateStatus matches package voice status reports" "voice"
    } else {
      Add-Gate $gates "voice-gate-status-consistency" "blocked" "metadata voiceGateStatus does not match package voice status reports: $($voiceGateMismatches -join '; ')" "voice"
      $blockers.Add("Evidence voiceGateStatus is not pinned to the package voice status reports: $($voiceGateMismatches -join '; ').") | Out-Null
    }

    $evidenceSummary = [ordered]@{
      root = $evidencePath
      metadata = if ($null -ne $metadata) {
        [ordered]@{
          releaseTag = [string]$metadata.releaseTag
          commit = [string]$metadata.commit
          deviceId = [string]$metadata.deviceId
          port = [string]$metadata.port
          operator = [string]$metadata.operator
          sharePublicUrl = if ($null -ne $metadata.shareVerification) { [string]$metadata.shareVerification.publicUrl } else { "" }
          shareVerifiedUrl = if ($null -ne $metadata.shareVerification -and -not [string]::IsNullOrWhiteSpace([string]$metadata.shareVerification.verifiedUrl)) { [string]$metadata.shareVerification.verifiedUrl } elseif ($null -ne $metadata.shareVerification) { [string]$metadata.shareVerification.publicUrl } else { "" }
          shareUrlKind = if ($null -ne $metadata.shareVerification) { [string]$metadata.shareVerification.urlKind } else { "" }
          leadVoice = if ($null -ne $metadata.voiceLeadAudition) { [string]$metadata.voiceLeadAudition.title } else { "" }
        }
      } else {
        $null
      }
      progressExitCode = $progress.exitCode
      progressOutput = $progress.text
      strictExitCode = $strict.exitCode
      strictOutput = $strict.text
      androidCompanionProbes = $androidProbes
    }
  } else {
    Add-Gate $gates "hardware-evidence-progress" "pending" "No hardware evidence packet was passed" "hardware"
    Add-Gate $gates "strict-hardware-evidence" "pending" "No hardware evidence packet was passed" "hardware"
    Add-Gate $gates "speech-mouth-demo-evidence" "pending" "No hardware evidence packet was passed" "hardware"
    Add-Gate $gates "android-companion-probes" "pass" "No hardware evidence packet was passed; Android probes are optional unless Android is the bridge host" "android"
    Add-Gate $gates "voice-gate-status-consistency" "pending" "No hardware evidence packet was passed" "voice"
    $blockers.Add("No hardware evidence packet was passed.") | Out-Null
  }

  $consumerReady = $true
  $gateArray = @($gates.ToArray())
  $blockerArray = @($blockers.ToArray())
  foreach ($gate in $gateArray) {
    if (@("pass") -notcontains [string]$gate.status) {
      $consumerReady = $false
      break
    }
  }
  $overall = if ($consumerReady) { "consumer-promotion-ready" } else { "blocked-or-pending" }
  $next = Get-RolloutNextAction -Gates $gateArray -ActionsStatus $actions -EvidenceSummary $evidenceSummary -ReleaseVersion $Version

  $generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  $status = [ordered]@{
    schema = "stackchan.rollout-status.v1"
    version = $Version
    commit = $ExpectedCommit
    generatedUtc = $generatedUtc
    packageRoot = $packageRootPath
    evidenceRoot = if ($null -ne $evidenceSummary) { $evidenceSummary.root } else { "" }
    actionsStatusPath = $actionsStatusSource
    status = $overall
    consumerReady = $consumerReady
    nextOwner = [string]$next.owner
    nextAction = [string]$next.action
    nextCommand = [string]$next.command
    nextReason = [string]$next.reason
    gates = $gateArray
    blockers = $blockerArray
    evidence = $evidenceSummary
  }
  $status | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $outPath "ROLLOUT_STATUS.json") -Encoding UTF8

  $lines = @(
    "# Stackchan Rollout Status",
    "",
    "- Version: $Version",
    "- Commit: $ExpectedCommit",
    "- Status: $overall",
    "- Consumer ready: $consumerReady",
    "- Next owner: $($status.nextOwner)",
    "- Next action: $($status.nextAction)",
    "- Next command: ``$($status.nextCommand)``",
    "- Next reason: $($status.nextReason)",
    "- Generated UTC: $generatedUtc",
    "- Package root: $packageRootPath",
    "- Evidence root: $($status.evidenceRoot)",
    "",
    "## Gates",
    ""
  )

  foreach ($gate in $gateArray) {
    $lines += "- $($gate.status): $($gate.gate) - $($gate.evidence)"
  }

  if ($blockers.Count -gt 0) {
    $lines += @(
      "",
      "## Blockers",
      ""
    )
    foreach ($blocker in $blockerArray) {
      $lines += "- $blocker"
    }
  }

  if ($null -ne $evidenceSummary) {
    $lines += @(
      "",
      "## Hardware Progress Output",
      "",
      '```text',
      $evidenceSummary.progressOutput,
      '```',
      "",
      "## Strict Evidence Output",
      "",
      '```text',
      $evidenceSummary.strictOutput,
      '```'
    )
  }

  $lines | Set-Content -Path (Join-Path $outPath "ROLLOUT_STATUS.md") -Encoding UTF8

  Write-Host "Rollout status exported:"
  Write-Host (Join-Path $outPath "ROLLOUT_STATUS.md")
  Write-Host (Join-Path $outPath "ROLLOUT_STATUS.json")

  if (-not $consumerReady) {
    exit 2
  }
} finally {
  if ($null -ne $cleanupDir) {
    Remove-Item -LiteralPath $cleanupDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}
