$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$platformioPath = Join-Path $repoRoot "platformio.ini"
$mainPath = Join-Path $repoRoot "src\main.cpp"
$gateHeaderPath = Join-Path $repoRoot "src\io\BridgeWakeGate.hpp"
$nativeTestPath = Join-Path $repoRoot "test\test_native_logic\test_main.cpp"

$platformio = Get-Content -LiteralPath $platformioPath -Raw
$main = Get-Content -LiteralPath $mainPath -Raw
$gateHeader = Get-Content -LiteralPath $gateHeaderPath -Raw
$nativeTest = Get-Content -LiteralPath $nativeTestPath -Raw

function Get-IniSection([string]$Text, [string]$Name) {
  $escaped = [regex]::Escape($Name)
  $match = [regex]::Match($Text, "(?ms)^\[$escaped\]\s*(.*?)(?=^\[|\z)")
  if (-not $match.Success) {
    throw "Missing platformio.ini section [$Name]."
  }
  return $match.Groups[1].Value
}

function Require-Contains([string]$Text, [string]$Needle, [string]$Message) {
  if (-not $Text.Contains($Needle)) {
    throw $Message
  }
}

$uplinkSection = Get-IniSection $platformio "env:stackchan_wake_mww_uplink"
Require-Contains $uplinkSection '-D STACKCHAN_MWW_WAKE_UPLINK_CHUNK_SAMPLES=800' `
  "Release inheritance root must keep the reviewed 800-sample uplink chunk."
Require-Contains $uplinkSection '-D STACKCHAN_MWW_WAKE_CAPTURE_SAMPLE_RATE=16000' `
  "Release inheritance root must keep the reviewed 16000 Hz capture rate."
foreach ($macro in @(
  "STACKCHAN_MWW_WAKE_UPLINK_CHUNK_SAMPLES",
  "STACKCHAN_MWW_WAKE_CAPTURE_SAMPLE_RATE"
)) {
  $definitions = [regex]::Matches(
    $uplinkSection,
    "(?m)^\s*-[DU]\s+$macro(?:=|\s)[^\r\n]*")
  if ($definitions.Count -ne 1) {
    throw "[env:stackchan_wake_mww_uplink] must define $macro exactly once."
  }
}

$inheritance = [ordered]@{
  "env:stackchan_wake_mww_uplink_servos" = "env:stackchan_wake_mww_uplink"
  "env:stackchan_wake_mww_uplink_servos_m5" = "env:stackchan_wake_mww_uplink_servos"
  "env:stackchan_wake_mww_uplink_servos_m5_voiceout" = "env:stackchan_wake_mww_uplink_servos_m5"
  "env:stackchan_voice_v2" = "env:stackchan_wake_mww_uplink_servos_m5_voiceout"
  "env:stackchan_release_forensics" = "env:stackchan_voice_v2"
  "env:stackchan_release_full" = "env:stackchan_release_forensics"
}
foreach ($entry in $inheritance.GetEnumerator()) {
  $section = Get-IniSection $platformio $entry.Key
  if ($section -notmatch "(?m)^\s*extends\s*=\s*$([regex]::Escape($entry.Value))\s*$") {
    throw "[$($entry.Key)] no longer inherits [$($entry.Value)]."
  }
  foreach ($macro in @(
    "STACKCHAN_MWW_WAKE_UPLINK_CHUNK_SAMPLES",
    "STACKCHAN_MWW_WAKE_CAPTURE_SAMPLE_RATE"
  )) {
    if ($section -match "(?m)^\s*-[DU]\s+$macro(?:=|\s|$)") {
      throw "[$($entry.Key)] must not override or unflag release timing macro $macro."
    }
  }
}

$releaseChunkSamples = 800
$releaseSampleRate = 16000
$releaseGateOpenMs = 6000
$releaseCaptureChunks = 240
$releaseGateMaxTurnMs = 15000
$chunkMs = [int](($releaseChunkSamples * 1000) / $releaseSampleRate)
$captureCeilingMs = $releaseCaptureChunks * $chunkMs
if ($chunkMs -ne 50 -or (120 * $chunkMs) -ne $releaseGateOpenMs -or
    $captureCeilingMs -ne 12000) {
  throw "Release boundary arithmetic changed: chunkMs=$chunkMs gate=$releaseGateOpenMs ceiling=$captureCeilingMs."
}
# The wake gate's hard privacy guard must outlast any capture we can take, or it
# closes the turn mid-utterance and the remaining chunks are rejected. This is
# the PR #217 ordering that closed the F2 equal-threshold race.
if ($captureCeilingMs -ge $releaseGateMaxTurnMs) {
  throw "Capture ceiling ${captureCeilingMs} ms must stay below the ${releaseGateMaxTurnMs} ms wake-gate privacy guard."
}

Require-Contains $gateHeader 'constexpr uint32_t kBridgeWakeGateOpenMs = 6000;' `
  "Bridge wake-gate open duration must stay bound to the reviewed 6000 ms value."
Require-Contains $gateHeader "constexpr uint32_t kBridgeWakeGateMaxTurnMs = $releaseGateMaxTurnMs;" `
  "Wake-gate hard privacy guard must stay bound to the reviewed $releaseGateMaxTurnMs ms value."
Require-Contains $gateHeader 'constexpr bool dedicatedWakeCaptureMaySubmit(' `
  "Pure dedicated-capture submission policy is missing."
Require-Contains $gateHeader 'return gateOpen && gateTurnActive && uplinkActive;' `
  "Dedicated capture must require all wake-gate and uplink authorities."
Require-Contains $main "constexpr uint16_t kWakeMwwDedicatedCaptureChunks = $releaseCaptureChunks;" `
  "Dedicated capture chunk ceiling must stay bound to the reviewed $releaseCaptureChunks chunks."

$retryStart = $main.IndexOf('DedicatedWakeCaptureSubmitResult submitDedicatedWakeCaptureChunk(')
$retryEnd = $main.IndexOf('void finishDedicatedWakeCaptureTurn(', $retryStart)
if ($retryStart -lt 0 -or $retryEnd -le $retryStart) {
  throw "Dedicated capture retry function could not be isolated."
}
$retry = $main.Substring($retryStart, $retryEnd - $retryStart)
$retryUpdateIndex = $retry.IndexOf('gBridgeNetworkSession.update(attemptMs);')
$retryGuardIndex = $retry.IndexOf('dedicatedWakeCaptureMaySubmit(')
$retrySubmitIndex = $retry.IndexOf('gBridgeAudioUplink.submitPcmChunk(')
if ($retryUpdateIndex -lt 0 -or $retryGuardIndex -lt $retryUpdateIndex -or
    $retrySubmitIndex -lt 0 -or $retryGuardIndex -gt $retrySubmitIndex) {
  throw "Each retry must revalidate capture authority after network drain and before PCM submission."
}
Require-Contains $retry 'return DedicatedWakeCaptureSubmitResult::AuthorityExpired;' `
  "Retry authority loss must return a distinct clean-stop result."

$serviceStart = $main.IndexOf('void serviceDedicatedWakeCaptureChunk()')
$serviceEnd = $main.IndexOf('void serviceDedicatedWakeCapture(uint32_t nowMs)', $serviceStart)
if ($serviceStart -lt 0 -or $serviceEnd -le $serviceStart) {
  throw "Dedicated capture service function could not be isolated."
}
$service = $main.Substring($serviceStart, $serviceEnd - $serviceStart)
$guardMatches = [regex]::Matches($service, 'dedicatedWakeCaptureMaySubmit\s*\(')
if ($guardMatches.Count -ne 2) {
  throw "Dedicated capture must have exactly two submission-authority guards; found $($guardMatches.Count)."
}
$attemptIndex = $service.IndexOf('++gWakeMwwDedicatedCapture.chunksAttempted;')
$endpointIndex = $service.IndexOf('gWakeMwwDedicatedCapture.endpoint.process(')
$submitIndex = $service.IndexOf('submitDedicatedWakeCaptureChunk(')
if ($guardMatches[0].Index -gt $attemptIndex) {
  throw "Pre-capture authority guard must precede the attempted-chunk counter."
}
if ($endpointIndex -lt 0 -or $guardMatches[1].Index -lt $endpointIndex -or
    $submitIndex -lt 0 -or $guardMatches[1].Index -gt $submitIndex) {
  throw "Post-record authority guard must sit between VAD processing and PCM submission."
}
$authorityBranch = [regex]::Match(
  $service,
  '(?s)else\s+if\s*\(\s*submitResult\s*==\s*DedicatedWakeCaptureSubmitResult::AuthorityExpired\s*\)\s*\{\s*finishDedicatedWakeCaptureSession\s*\([^;]+;\s*return\s*;\s*\}\s*else\s*\{\s*gWakeMwwUplinkSubmitFailed\s*=')
if (-not $authorityBranch.Success) {
  throw "Authority expiry must clean-finish and return before the real submit-failure counter branch."
}

foreach ($needle in @(
  'test_dedicated_wake_capture_submission_requires_all_owners',
  'test_dedicated_wake_capture_keeps_queue_failures_visible_while_authorized',
  'test_dedicated_wake_capture_retry_stops_when_backpressure_reaches_gate_edge',
  'test_dedicated_wake_capture_stops_cleanly_at_release_gate_boundary',
  'constexpr uint16_t kReleaseChunkSamples = 800;',
  'constexpr uint32_t kReleaseSampleRate = 16000;',
  'constexpr uint32_t kReleaseGateOpenMs = 6000;',
  'TEST_ASSERT_EQUAL_UINT16(120, chunksAttempted);',
  'TEST_ASSERT_EQUAL_UINT16(119, chunksSubmitted);',
  'TEST_ASSERT_EQUAL_UINT32(0, submitFailures);',
  'TEST_ASSERT_EQUAL_UINT32(0, uplink.telemetry().errors);',
  '\"audio_bytes\":190400',
  'TEST_ASSERT_EQUAL_UINT32(119, session.telemetry().writerBinaryFrames);'
)) {
  Require-Contains $nativeTest $needle "Native release-boundary regression is missing: $needle"
}

Write-Output "dedicated-wake-capture-contract-passed"
