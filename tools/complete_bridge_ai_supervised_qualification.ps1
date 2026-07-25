param(
  [Parameter(Mandatory = $true)]
  [string]$EvidenceRoot,
  [int]$EchoWindowsObserved = 0,
  [switch]$ConfirmOneWakeMultiTurn,
  [switch]$ConfirmEchoFree,
  [switch]$ConfirmExitPhraseClosed,
  [switch]$ConfirmSilenceClosed,
  [switch]$ConfirmBargeInStoppedAudio,
  [switch]$ConfirmBridgeLossLocalRecovery,
  [switch]$ConfirmCleanCompleteAudio,
  [switch]$ConfirmInitiativeNatural,
  [switch]$ConfirmInitiativeRateFloor,
  [switch]$ConfirmInitiativeIgnoredBackoff,
  [switch]$ConfirmInitiativeNightSuppressed,
  [switch]$ConfirmRoomContextGrounded,
  [switch]$ConfirmRoomOffCleared,
  [switch]$ConfirmNoFramePersisted,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot
$EvidencePath = (Resolve-Path $EvidenceRoot).Path
$Session = Get-Content -LiteralPath (Join-Path $EvidencePath "session.json") -Raw | ConvertFrom-Json
if ($Session.mode -ne "bridge-ai-supervised") { throw "Evidence session mode is invalid." }

$DebugUrl = "http://$($Session.deviceHost)`:8789/debug"
$DashboardUrl = "http://127.0.0.1`:$($Session.dashboardPort)/api/status"
$Deadline = (Get-Date).AddSeconds(45)
$AfterDebug = $null
while ((Get-Date) -lt $Deadline) {
  try { $AfterDebug = Invoke-RestMethod -Uri $DebugUrl -TimeoutSec 5 } catch { $AfterDebug = $null }
  if ($AfterDebug -and -not [bool]$AfterDebug.audio_stream_active -and
      -not [bool]$AfterDebug.bridge_downlink_playback_awaiting_drain -and
      [int]$AfterDebug.speaker_channel_state -eq 0) {
    break
  }
  Start-Sleep -Seconds 1
}
if (-not $AfterDebug) { throw "Could not capture drained post-qualification robot debug." }
$AfterDashboard = Invoke-RestMethod -Uri $DashboardUrl -TimeoutSec 6
$AfterDebug | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $EvidencePath "after-debug.json") -Encoding UTF8
$AfterDashboard | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $EvidencePath "after-dashboard.json") -Encoding UTF8

$TurnLogLines = if (Test-Path -LiteralPath $Session.turnLogPath -PathType Leaf) {
  @(Get-Content -LiteralPath $Session.turnLogPath | Select-Object -Skip ([int]$Session.turnLogStartLine))
} else {
  @()
}
[IO.File]::WriteAllLines(
  (Join-Path $EvidencePath "turns.jsonl"),
  [string[]]$TurnLogLines,
  [Text.UTF8Encoding]::new($false)
)

$Observations = [ordered]@{
  schema = "stackchan.bridge-ai-operator-observations.v1"
  generatedAt = (Get-Date).ToUniversalTime().ToString("o")
  oneWakeMultiTurn = [bool]$ConfirmOneWakeMultiTurn
  echoFree = [bool]$ConfirmEchoFree
  echoWindowsObserved = $EchoWindowsObserved
  exitPhraseClosed = [bool]$ConfirmExitPhraseClosed
  silenceClosed = [bool]$ConfirmSilenceClosed
  bargeInStoppedAudio = [bool]$ConfirmBargeInStoppedAudio
  bridgeLossLocalRecovery = [bool]$ConfirmBridgeLossLocalRecovery
  cleanCompleteAudio = [bool]$ConfirmCleanCompleteAudio
  initiativeNatural = [bool]$ConfirmInitiativeNatural
  initiativeRateFloor = [bool]$ConfirmInitiativeRateFloor
  initiativeIgnoredBackoff = [bool]$ConfirmInitiativeIgnoredBackoff
  initiativeNightSuppressed = [bool]$ConfirmInitiativeNightSuppressed
  roomContextGrounded = [bool]$ConfirmRoomContextGrounded
  roomOffCleared = [bool]$ConfirmRoomOffCleared
  noFramePersisted = [bool]$ConfirmNoFramePersisted
}
$Observations | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $EvidencePath "operator-observations.json") -Encoding UTF8

$CheckOutput = & python bridge\bridge_ai_qualification.py `
  --evidence-root $EvidencePath --json --require-ready
$CheckExit = $LASTEXITCODE
$CheckOutput | Set-Content -LiteralPath (Join-Path $EvidencePath "bridge-ai-check.json") -Encoding UTF8
if ($Json) { $CheckOutput } else {
  $Check = $CheckOutput | ConvertFrom-Json
  Write-Host "$($Check.status) ($($Check.passed) pass, $($Check.failed) fail, $($Check.pending) pending)"
}
exit $CheckExit
