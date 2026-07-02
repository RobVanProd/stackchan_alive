param(
  [string]$Version = "",
  [string]$PackageRoot = "",
  [string]$PackageZip = "",
  [string]$EvidenceRoot = "",
  [string]$OutDir = "",
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
  $actions = Read-JsonFile (Join-ResolvedPath $packageRootPath "github_actions_status.json")
  $voice = Read-JsonFile (Join-ResolvedPath $packageRootPath "voice_source_status.json")

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

  $evidenceSummary = $null
  if (-not [string]::IsNullOrWhiteSpace($EvidenceRoot)) {
    if (-not (Test-Path -LiteralPath $EvidenceRoot)) {
      throw "Missing evidence packet: $EvidenceRoot"
    }
    $evidencePath = (Resolve-Path $EvidenceRoot).Path
    $progress = Invoke-ToolCapture @((Join-Path $PSScriptRoot "check_hardware_evidence_progress.ps1"), "-EvidenceRoot", $evidencePath)
    $strict = Invoke-ToolCapture @((Join-Path $PSScriptRoot "verify_hardware_evidence.ps1"), "-EvidenceRoot", $evidencePath)
    $metadata = Read-JsonFile (Join-Path $evidencePath "metadata.json")

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

    if ($null -ne $metadata -and $null -ne $metadata.shareVerification) {
      Add-Gate $gates "hosted-media-reference" "pass" "HOSTED_MEDIA_REFERENCE.md and share verification metadata are pinned" "share"
    } else {
      Add-Gate $gates "hosted-media-reference" "review" "No shareVerification metadata in evidence packet" "share"
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
          leadVoice = if ($null -ne $metadata.voiceLeadAudition) { [string]$metadata.voiceLeadAudition.title } else { "" }
        }
      } else {
        $null
      }
      progressExitCode = $progress.exitCode
      progressOutput = $progress.text
      strictExitCode = $strict.exitCode
      strictOutput = $strict.text
    }
  } else {
    Add-Gate $gates "hardware-evidence-progress" "pending" "No hardware evidence packet was passed" "hardware"
    Add-Gate $gates "strict-hardware-evidence" "pending" "No hardware evidence packet was passed" "hardware"
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

  $generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  $status = [ordered]@{
    schema = "stackchan.rollout-status.v1"
    version = $Version
    commit = $ExpectedCommit
    generatedUtc = $generatedUtc
    packageRoot = $packageRootPath
    evidenceRoot = if ($null -ne $evidenceSummary) { $evidenceSummary.root } else { "" }
    status = $overall
    consumerReady = $consumerReady
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
