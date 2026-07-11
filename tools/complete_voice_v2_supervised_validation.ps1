param(
  [Parameter(Mandatory = $true)]
  [string]$EvidenceRoot,
  [string]$DeviceHost = "192.168.1.238",
  [double]$MaxFirstAudioMs = 5000,
  [switch]$ConfirmHeardCleanAudio,
  [switch]$ConfirmHeardCompleteReply,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot
$DebugUrl = "http://$DeviceHost`:8789/debug"

$Deadline = (Get-Date).AddSeconds(60)
$After = $null
while ((Get-Date) -lt $Deadline) {
  try { $After = Invoke-RestMethod -Uri $DebugUrl -TimeoutSec 5 } catch { $After = $null }
  if ($After -and -not [bool]$After.audio_stream_active -and
      [int]$After.speaker_channel_state -eq 0 -and $After.bridge_state -eq "ready") { break }
  Start-Sleep -Seconds 1
}
if (-not $After) { throw "Could not capture post-turn robot debug." }
$After | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $EvidenceRoot "after-debug.json") -Encoding UTF8

$CheckOutput = $null
$CheckExit = 1
try {
  $CheckArgs = @("-EvidenceRoot", $EvidenceRoot, "-MaxFirstAudioMs", $MaxFirstAudioMs, "-RequireReady", "-Json")
  if ($ConfirmHeardCleanAudio) { $CheckArgs += "-ConfirmHeardCleanAudio" }
  if ($ConfirmHeardCompleteReply) { $CheckArgs += "-ConfirmHeardCompleteReply" }
  $CheckOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $PSScriptRoot "check_voice_v2_supervised_evidence.ps1") @CheckArgs
  $CheckExit = $LASTEXITCODE
} finally {
  $RestoreOutput = & (Join-Path $PSScriptRoot "restore_voice_v2_production.ps1") -DeviceHost $DeviceHost -EvidenceRoot $EvidenceRoot -Json
}

$Result = [ordered]@{
  schema = "stackchan.voice-v2-supervised-complete.v1"
  evidence_root = (Resolve-Path $EvidenceRoot).Path
  check_exit = $CheckExit
  check = if ($CheckOutput) { $CheckOutput | ConvertFrom-Json } else { $null }
  restore = if ($RestoreOutput) { $RestoreOutput | ConvertFrom-Json } else { $null }
}
$Result | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $EvidenceRoot "completion.json") -Encoding UTF8
if ($Json) { $Result | ConvertTo-Json -Depth 10 } else { Write-Host "Voice V2 test captured and production restored. Check: $($Result.check.status)" }
if ($CheckExit -ne 0) { exit 1 }
