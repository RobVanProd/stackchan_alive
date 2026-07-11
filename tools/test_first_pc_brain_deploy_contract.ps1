param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$checkScript = Join-Path $PSScriptRoot "check_first_pc_brain_deploy.ps1"
$createdRoots = New-Object System.Collections.Generic.List[string]

function Write-JsonFile {
  param(
    [string]$Path,
    [object]$Value
  )

  $dir = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $Value | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Encoding UTF8
}

function New-TempEvidenceRoot {
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-first-pc-brain-deploy-contract-" + [guid]::NewGuid().ToString("N"))
  $createdRoots.Add($root) | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $root "pc-brain") | Out-Null
  return $root
}

function Invoke-FirstDeployCheck {
  param(
    [string]$EvidenceRoot,
    [string]$ReportDir = "",
    [switch]$RequireFullOnline
  )

  $powerShellExe = (Get-Process -Id $PID).Path
  $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $checkScript, "-EvidenceRoot", $EvidenceRoot, "-Json")
  if (-not [string]::IsNullOrWhiteSpace($ReportDir)) {
    $arguments += @("-ReportDir", $ReportDir)
  }
  if ($RequireFullOnline) {
    $arguments += "-RequireFullOnline"
  }

  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & $powerShellExe @arguments 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }

  $text = ($output | Out-String).Trim()
  $report = if ([string]::IsNullOrWhiteSpace($text)) { $null } else { $text | ConvertFrom-Json }
  return [pscustomobject]@{ exitCode = $exitCode; text = $text; report = $report }
}

function Assert-CheckStatus {
  param(
    [object]$Report,
    [string]$Id,
    [string]$Status
  )

  $check = @($Report.checks | Where-Object { $_.id -eq $Id })
  if ($check.Count -ne 1) {
    throw "Expected exactly one check with id '$Id'."
  }
  if ($check[0].status -ne $Status) {
    throw "Expected check '$Id' to be '$Status', got '$($check[0].status)'. Detail: $($check[0].detail)"
  }
}

function Write-CompleteEvidence {
  param([string]$Root)

  $debug = [ordered]@{
    schema = "stackchan.bridge-debug.v1"
    network_state = "connected"
    bridge_state = "ready"
    network_error = ""
    speaker_volume = 150
    audio_streams_started = 1
    audio_streams_ended = 1
    audio_stream_chunks_received = 16
    audio_stream_chunks_expected = 16
    bridge_downlink_playback_errors = 0
    speaker_stream_play_raw_failed = 0
  }

  Write-JsonFile -Path (Join-Path $Root "pc-brain/PC_BRAIN_DEPLOY_EVIDENCE.json") -Value ([ordered]@{
      schema = "stackchan.pc-brain-deploy-evidence.v1"
      status = "pass"
      issues = @()
      device_debug = $debug
    })

  Write-JsonFile -Path (Join-Path $Root "pc-brain/PC_BRAIN_QUIET_SOAK.json") -Value ([ordered]@{
      schema = "stackchan.pc-brain-quiet-soak.v1"
      status = "pass"
      duration_seconds = 600
      poll_count = 10
      records = @(
        [ordered]@{ network_state = "connected"; bridge_state = "ready"; audio_streams_started = 1 },
        [ordered]@{ network_state = "connected"; bridge_state = "ready"; audio_streams_started = 1 }
      )
    })

  @"
network_state=connected
[bridge_text_turn] result=accepted
type=event state=thinking
type=response_start
type=audio_stream_start
chunk_index=16
type=audio_stream_end
type=response_end
"@ | Set-Content -Path (Join-Path $Root "pc-brain/post_flash_voice_turn_serial.log") -Encoding UTF8

  "# Review" | Set-Content -Path (Join-Path $Root "FIRST_PC_BRAIN_DEPLOY_REVIEW.md") -Encoding UTF8
  @"
# Deploy Mode

PC Brain text-turn voice-out bench deploy.

Physical robot mic capture is not enabled in this flashed build.
"@ | Set-Content -Path (Join-Path $Root "DEPLOY_MODE.md") -Encoding UTF8

  @'
# Human Evidence Review

- Post-flash voice line heard: yes
- Voice matched selected `stackchan-rvc-bright-robot` direction: yes
- Volume at firmware `150` acceptable: yes
- Choppiness, clipping, or dropout heard: no
'@ | Set-Content -Path (Join-Path $Root "HUMAN_EVIDENCE_REVIEW.md") -Encoding UTF8

  @"
# Audio Review

- Intelligible through device speaker: yes
- Clipping or distortion observed: no
- Volume adequate at normal listening distance: yes
- Delay or playback dropout observed: no
"@ | Set-Content -Path (Join-Path $Root "AUDIO_REVIEW.md") -Encoding UTF8

  Write-JsonFile -Path (Join-Path $Root "media_manifest.json") -Value ([ordered]@{
      schema = "stackchan.hardware-evidence-media.v1"
      media = @(
        [ordered]@{ type = "Photo"; destination = "photos/stackchan-face.jpg" },
        [ordered]@{ type = "Audio"; destination = "audio/stackchan-speaker.mp4" }
      )
    })
}

try {
  Set-Location $repoRoot

  $root = New-TempEvidenceRoot
  Write-CompleteEvidence -Root $root
  $result = Invoke-FirstDeployCheck -EvidenceRoot $root -ReportDir $root

  if ([int]$result.exitCode -ne 0) {
    throw "Expected first PC Brain deploy contract evidence to check without failures. Output:`n$($result.text)"
  }
  if ($result.report.status -ne "first-pc-brain-deploy-pending-human-evidence") {
    throw "Expected live-debug-only pending status, got $($result.report.status)."
  }
  if (-not $result.report.machineReady) {
    throw "Expected machineReady=true for synthetic passing machine evidence."
  }
  foreach ($id in @("human-voice-matched", "human-volume-ok", "media-manifest", "photo-media", "audio-media", "audio-review-volume")) {
    Assert-CheckStatus -Report $result.report -Id $id -Status "pass"
  }
  Assert-CheckStatus -Report $result.report -Id "live-debug-endpoint" -Status "pending"

  foreach ($path in @("FIRST_PC_BRAIN_DEPLOY_CHECK.json", "FIRST_PC_BRAIN_DEPLOY_CHECK.md")) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $path) -PathType Leaf)) {
      throw "Expected report writer to create $path."
    }
  }
  Write-Host "[ok] complete offline first PC Brain deploy evidence is accepted with live debug pending"

  $fullOnlineResult = Invoke-FirstDeployCheck -EvidenceRoot $root -RequireFullOnline
  if ([int]$fullOnlineResult.exitCode -eq 0) {
    throw "Expected full-online check without live robot debug to exit nonzero."
  }
  Assert-CheckStatus -Report $fullOnlineResult.report -Id "full-online-live-debug" -Status "pending"
  Write-Host "[ok] full-online gate requires live robot debug evidence"

  $missingRoot = New-TempEvidenceRoot
  $missingResult = Invoke-FirstDeployCheck -EvidenceRoot $missingRoot
  Assert-CheckStatus -Report $missingResult.report -Id "deploy-json" -Status "fail"
  if ([int]$missingResult.exitCode -eq 0) {
    throw "Expected incomplete evidence to exit nonzero."
  }
  Write-Host "[ok] incomplete first PC Brain deploy evidence is rejected"

  Write-Host "First PC Brain deploy contract tests passed."
} finally {
  foreach ($root in $createdRoots) {
    if ([string]::IsNullOrWhiteSpace($root)) {
      continue
    }
    $resolvedRoot = Resolve-Path -LiteralPath $root -ErrorAction SilentlyContinue
    if ($null -ne $resolvedRoot -and $resolvedRoot.Path.StartsWith([System.IO.Path]::GetTempPath(), [System.StringComparison]::OrdinalIgnoreCase)) {
      Remove-Item -LiteralPath $resolvedRoot.Path -Recurse -Force
    }
  }
}
