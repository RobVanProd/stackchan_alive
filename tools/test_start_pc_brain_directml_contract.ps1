$ErrorActionPreference = "Stop"

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$launcherPath = Join-Path $PSScriptRoot "start_pc_brain_directml.ps1"
$text = Get-Content -LiteralPath $launcherPath -Raw

$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
  $launcherPath,
  [ref]$tokens,
  [ref]$parseErrors
) | Out-Null
if ($parseErrors.Count -ne 0) {
  throw "DirectML launcher has PowerShell parse errors: $($parseErrors -join '; ')"
}

foreach ($required in @(
  "Stop-ExistingBridge",
  "Refusing to stop non-Stackchan listener",
  "Invoke-EncodedChildPowerShell",
  "RedirectStandardOutput",
  "RedirectStandardError",
  "WaitForExit()",
  "Refresh()",
  "[int]`$process.ExitCode",
  "memory_maintenance.py --memory-file `$MemoryFile --apply",
  "start_voice_v2_directml_worker.ps1",
  "stackchan.rvc-directml-worker.health.v1",
  "rvc_production_tts_client.py",
  "-StreamTtsPhrases",
  "-EnableAudioDownlink",
  "-DownlinkAudioChunkBytes 4096",
  "-DownlinkBinaryFrameDelayMs 70",
  "`$ErrorActionPreference = 'Stop'",
  '-ExpectedDisableAudioDownlink `$false',
  '-ExpectedAudioPlaybackEnabled `$true',
  '-ExpectedStreamTtsPhrases `$true',
  '-EncodedCommand $runtimeEncoded',
  "bridge_state -eq `"ready`""
)) {
  if (-not $text.Contains($required)) {
    throw "DirectML launcher missing contract token: $required"
  }
}

$stopIndex = $text.IndexOf("`nStop-ExistingBridge")
$repairIndex = $text.IndexOf("memory_maintenance.py --memory-file `$MemoryFile --apply")
if ($stopIndex -lt 0 -or $repairIndex -lt 0 -or $stopIndex -gt $repairIndex) {
  throw "Memory repair must happen only after the old bridge is stopped."
}

$workerReadyIndex = $text.IndexOf('worker-health.json')
if ($workerReadyIndex -lt 0 -or $stopIndex -lt $workerReadyIndex) {
  throw "DirectML must pass health before the existing bridge is stopped."
}

if ($text -match "Get-CimInstance Win32_Process\s*\|\s*Stop-Process") {
  throw "Launcher must not broadly stop every discovered process."
}

Write-Host "DirectML PC brain launcher contract tests passed."
