param(
  [string]$Text = "Stackchan, selected voice check. Please say hello once.",
  [int]$SelectedVoiceMaxAudioBytes = 65536,
  [int]$SelectedVoiceStartBytes = 0,
  [double]$SelectedVoiceGain = 0.40,
  [int]$DownlinkBinaryFrameDelayMs = 20,
  [int]$DownlinkTextFrameDelayMs = 40,
  [int]$WaitSeconds = 60,
  [switch]$LeaveBrainRunning
)

$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

Write-Host "[selected-voice-once] starting one-shot PC brain voice check"
& (Join-Path $PSScriptRoot "start_pc_brain.ps1") `
  -Background `
  -StopExisting `
  -Once `
  -SelectedVoiceMaxAudioBytes $SelectedVoiceMaxAudioBytes `
  -SelectedVoiceStartBytes $SelectedVoiceStartBytes `
  -SelectedVoiceGain $SelectedVoiceGain `
  -DownlinkAudioChunkBytes 4096 `
  -DownlinkBinaryFrameDelayMs $DownlinkBinaryFrameDelayMs `
  -DownlinkTextFrameDelayMs $DownlinkTextFrameDelayMs `
  -AutoTurnText $Text

if ($WaitSeconds -gt 0) {
  Start-Sleep -Seconds $WaitSeconds
}

if (-not $LeaveBrainRunning) {
  $PidFile = Join-Path "output\pc-brain\latest" "lan_service.pid"
  if (Test-Path -LiteralPath $PidFile) {
    $PidText = (Get-Content -LiteralPath $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1).Trim()
    if ($PidText) {
      Stop-Process -Id ([int]$PidText) -Force -ErrorAction SilentlyContinue
      Write-Host "[selected-voice-once] stopped one-shot PC brain pid=$PidText"
    }
  }
}

Write-Host "[selected-voice-once] logs: output\pc-brain\latest\lan_service.out.log ; output\pc-brain\latest\lan_service.err.log"
