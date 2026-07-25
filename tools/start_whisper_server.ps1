param(
  [int]$Port = 5061,
  [int]$Threads = 8,
  [string]$ExecutablePath = "",
  [string]$ModelPath = "",
  [string]$OutputDir = "output\pc-brain\whisper-server",
  [int]$ReadyTimeoutSeconds = 30,
  [switch]$StopExisting,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

if ($Port -lt 1 -or $Port -gt 65535) { throw "Port must be between 1 and 65535." }
if ($Threads -lt 1 -or $Threads -gt 32) { throw "Threads must be between 1 and 32." }

function Get-WhisperListener {
  return Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
    Select-Object -First 1
}

function Get-WhisperHealth {
  try {
    return Invoke-RestMethod -Uri "http://127.0.0.1`:$Port/health" -TimeoutSec 3
  } catch {
    return $null
  }
}

$Existing = Get-WhisperListener
if ($Existing) {
  $ExistingProcess = Get-CimInstance Win32_Process -Filter "ProcessId=$($Existing.OwningProcess)" -ErrorAction SilentlyContinue
  if (-not $ExistingProcess -or [string]$ExistingProcess.CommandLine -notmatch "whisper-server(\.exe)?") {
    throw "Refusing to use or stop non-whisper listener PID $($Existing.OwningProcess) on port $Port."
  }
  if ($StopExisting) {
    Stop-Process -Id $Existing.OwningProcess -Force
    $Deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $Deadline -and (Get-WhisperListener)) {
      Start-Sleep -Milliseconds 200
    }
    if (Get-WhisperListener) { throw "Whisper server port $Port did not become free." }
  } else {
    $ExistingHealth = Get-WhisperHealth
    if (-not $ExistingHealth -or [string]$ExistingHealth.status -ne "ok") {
      throw "Existing whisper.cpp server on port $Port is not healthy."
    }
    $Reused = [ordered]@{
      schema = "stackchan.whisper-server-start.v1"
      status = "ready"
      reused = $true
      pid = [int]$Existing.OwningProcess
      url = "http://127.0.0.1`:$Port"
      health = $ExistingHealth
    }
    if ($Json) { $Reused | ConvertTo-Json -Depth 5 } else { Write-Host "Whisper server already ready: PID $($Reused.pid)" }
    exit 0
  }
}

if ([string]::IsNullOrWhiteSpace($ExecutablePath)) {
  $DiscoveredServer = if (Test-Path -LiteralPath (Join-Path $RepoRoot "output\local-tools\whisper.cpp")) {
    Get-ChildItem -LiteralPath (Join-Path $RepoRoot "output\local-tools\whisper.cpp") `
      -Filter "whisper-server.exe" -Recurse -ErrorAction SilentlyContinue |
      Sort-Object FullName |
      Select-Object -First 1
  } else {
    $null
  }
  $Candidates = @(
    $env:STACKCHAN_WHISPER_SERVER_EXE,
    (Join-Path $RepoRoot "output\local-tools\whisper.cpp\Release\whisper-server.exe"),
    (Join-Path $RepoRoot "output\local-tools\whisper.cpp\whisper-server.exe"),
    $(if ($DiscoveredServer) { $DiscoveredServer.FullName })
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }
  $ExecutablePath = $Candidates | Select-Object -First 1
}
if (-not $ExecutablePath -or -not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf)) {
  throw "whisper-server.exe not found. Run tools\setup_whisper_cpp.cmd or pass -ExecutablePath."
}

if ([string]::IsNullOrWhiteSpace($ModelPath)) {
  $Candidates = @(
    $env:STACKCHAN_WHISPER_MODEL,
    (Join-Path $RepoRoot "output\local-tools\whisper.cpp\models\ggml-base.en.bin")
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) }
  $ModelPath = $Candidates | Select-Object -First 1
}
if (-not $ModelPath -or -not (Test-Path -LiteralPath $ModelPath -PathType Leaf)) {
  throw "whisper.cpp model not found. Run tools\setup_whisper_cpp.cmd or pass -ModelPath."
}

$ExecutablePath = (Resolve-Path $ExecutablePath).Path
$ModelPath = (Resolve-Path $ModelPath).Path
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$OutputPath = (Resolve-Path $OutputDir).Path
$StdoutPath = Join-Path $OutputPath "whisper-server.stdout.log"
$StderrPath = Join-Path $OutputPath "whisper-server.stderr.log"

$Process = Start-Process -FilePath $ExecutablePath -ArgumentList @(
  "-m", $ModelPath,
  "--host", "127.0.0.1",
  "--port", "$Port",
  "-t", "$Threads",
  "-nt"
) -WorkingDirectory $RepoRoot -RedirectStandardOutput $StdoutPath `
  -RedirectStandardError $StderrPath -WindowStyle Hidden -PassThru

$Health = $null
$ReadyDeadline = (Get-Date).AddSeconds($ReadyTimeoutSeconds)
while ((Get-Date) -lt $ReadyDeadline) {
  if ($Process.HasExited) {
    $Detail = if (Test-Path -LiteralPath $StderrPath) {
      (Get-Content -LiteralPath $StderrPath -Tail 20) -join " "
    } else {
      "no stderr"
    }
    throw "whisper.cpp server exited before ready: $Detail"
  }
  $Health = Get-WhisperHealth
  if ($Health -and [string]$Health.status -eq "ok") { break }
  Start-Sleep -Milliseconds 250
}
if (-not $Health -or [string]$Health.status -ne "ok") {
  Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
  throw "whisper.cpp server did not become ready within $ReadyTimeoutSeconds seconds."
}

$Process.Id | Set-Content -LiteralPath (Join-Path $OutputPath "whisper-server.pid") -Encoding ASCII
$Result = [ordered]@{
  schema = "stackchan.whisper-server-start.v1"
  status = "ready"
  reused = $false
  pid = [int]$Process.Id
  url = "http://127.0.0.1`:$Port"
  threads = $Threads
  model = Split-Path -Leaf $ModelPath
  modelSha256 = (Get-FileHash -LiteralPath $ModelPath -Algorithm SHA256).Hash.ToLowerInvariant()
  health = $Health
}
if ($Json) { $Result | ConvertTo-Json -Depth 5 } else { Write-Host "Whisper server ready: PID $($Process.Id)" }
