param(
  [string]$DeviceHost = "192.168.1.238",
  [int]$RobotHttpPort = 8789,
  [Parameter(Mandatory = $true)]
  [string]$PairingCodeFile,
  [string]$PythonExe = "",
  [double]$IntervalSeconds = 1.0,
  [string]$LogDir = "output\pc-brain\latest",
  [switch]$StopExisting,
  [switch]$PreflightOnly,
  [switch]$Background,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

if ($IntervalSeconds -lt 0.5) {
  throw "IntervalSeconds must be at least 0.5."
}
if (-not (Test-Path -LiteralPath $PairingCodeFile -PathType Leaf)) {
  throw "PairingCodeFile is missing."
}
if ([string]::IsNullOrWhiteSpace($PythonExe)) {
  $managedVisionPython = "C:\stackchan_vision_venv\Scripts\python.exe"
  $PythonExe = if (Test-Path -LiteralPath $managedVisionPython -PathType Leaf) {
    $managedVisionPython
  } else {
    "python"
  }
}

$RobotUrl = "http://$DeviceHost`:$RobotHttpPort"
$ServicePath = "bridge\vision_service.py"
$PreflightArgs = @(
  $ServicePath,
  "--robot-url", $RobotUrl,
  "--pairing-code-file", $PairingCodeFile,
  "--preflight"
)
$PreflightRaw = & $PythonExe @PreflightArgs
if ($LASTEXITCODE -ne 0) {
  throw "Local vision preflight failed with exit $LASTEXITCODE."
}
$Preflight = $PreflightRaw | ConvertFrom-Json
if (-not [bool]$Preflight.ready -or
    [string]$Preflight.schema -ne "stackchan.local-vision-preflight.v1") {
  throw "Local vision preflight did not report ready."
}

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$PidFile = Join-Path $LogDir "vision_service.pid"
$OutLog = Join-Path $LogDir "vision_service.out.log"
$ErrLog = Join-Path $LogDir "vision_service.err.log"

if ($StopExisting -and (Test-Path -LiteralPath $PidFile -PathType Leaf)) {
  $existingPid = 0
  [void][int]::TryParse((Get-Content -LiteralPath $PidFile -Raw).Trim(), [ref]$existingPid)
  if ($existingPid -gt 0) {
    $existing = Get-CimInstance Win32_Process -Filter "ProcessId=$existingPid" -ErrorAction SilentlyContinue
    if ($existing) {
      if ([string]$existing.CommandLine -notmatch "bridge[\\/]vision_service\.py") {
        throw "Refusing to stop PID $existingPid because it is not Stackchan local vision."
      }
      Stop-Process -Id $existingPid -Force
      try {
        Wait-Process -Id $existingPid -Timeout 5 -ErrorAction SilentlyContinue
      } catch {
      }
    }
  }
  Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
}

$Result = [ordered]@{
  schema = "stackchan.local-vision-start.v1"
  status = if ($PreflightOnly) { "preflight-ready" } else { "starting" }
  generatedAt = (Get-Date).ToUniversalTime().ToString("o")
  robotUrl = $RobotUrl
  intervalSeconds = $IntervalSeconds
  python = $PythonExe
  modelSha256 = [string]$Preflight.model_sha256
  rawFramePersistence = $false
  pid = $null
  log = $OutLog
  errorLog = $ErrLog
}

if ($PreflightOnly) {
  if ($Json) {
    $Result | ConvertTo-Json -Depth 5
  } else {
    Write-Host "Stackchan local vision preflight passed."
  }
  exit 0
}

$ServiceArgs = @(
  $ServicePath,
  "--robot-url", $RobotUrl,
  "--pairing-code-file", $PairingCodeFile,
  "--interval-seconds", ([string]::Format(
    [Globalization.CultureInfo]::InvariantCulture,
    "{0:0.###}",
    $IntervalSeconds
  ))
)

if ($Background) {
  function ConvertTo-CommandLineArg([string]$Value) {
    if ($Value -notmatch '[\s"]') {
      return $Value
    }
    return '"' + $Value.Replace('"', '\"') + '"'
  }
  $ProcessArgs = ($ServiceArgs | ForEach-Object { ConvertTo-CommandLineArg $_ }) -join " "
  $Process = Start-Process -FilePath $PythonExe -ArgumentList $ProcessArgs `
    -WorkingDirectory $RepoRoot -RedirectStandardOutput $OutLog `
    -RedirectStandardError $ErrLog -WindowStyle Hidden -PassThru
  Start-Sleep -Milliseconds 750
  $Process.Refresh()
  if ($Process.HasExited) {
    $stderr = if (Test-Path -LiteralPath $ErrLog) {
      (Get-Content -LiteralPath $ErrLog -Raw).Trim()
    } else {
      ""
    }
    throw "Local vision exited during startup with code $($Process.ExitCode): $stderr"
  }
  Set-Content -LiteralPath $PidFile -Value $Process.Id -Encoding ASCII
  $Result.status = "running"
  $Result.pid = $Process.Id
  if ($Json) {
    $Result | ConvertTo-Json -Depth 5
  } else {
    Write-Host "Stackchan local vision started."
    Write-Host "PID: $($Process.Id)"
    Write-Host "Robot: $RobotUrl"
    Write-Host "Logs: $OutLog ; $ErrLog"
  }
  exit 0
}

if ($Json) {
  $Result.status = "foreground"
  $Result | ConvertTo-Json -Depth 5
}
& $PythonExe @ServiceArgs
exit $LASTEXITCODE
