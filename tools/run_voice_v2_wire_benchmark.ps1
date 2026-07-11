param(
  [string]$PythonExe = "",
  [string]$WorkerUrl = "http://127.0.0.1:5059",
  [string]$OutputDir = "output\voice-lab\directml-wire-latest",
  [int]$ChunkBytes = 4096,
  [int]$BinaryDelayMs = 80,
  [int]$TextDelayMs = 40,
  [double]$MaxFirstAudioSeconds = 3.0,
  [double]$MaxWireRealtimeFactor = 1.0
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

if ([string]::IsNullOrWhiteSpace($PythonExe)) {
  $PythonCandidates = @(
    $env:STACKCHAN_BRAIN_PYTHON,
    (Join-Path $env:LOCALAPPDATA "Programs\Python\Python310\python.exe"),
    (Get-Command python.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1)
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
  $PythonExe = $PythonCandidates | Select-Object -First 1
}

if (-not $PythonExe -or -not (Test-Path -LiteralPath $PythonExe)) {
  throw "Python runtime not found. Set STACKCHAN_BRAIN_PYTHON or pass -PythonExe."
}

$Health = Invoke-RestMethod -Uri "$($WorkerUrl.TrimEnd('/'))/health" -TimeoutSec 5
if (-not $Health.ready -or $Health.backend -ne "torch-directml") {
  throw "DirectML lab worker is not ready at $WorkerUrl"
}

$env:STACKCHAN_RVC_DIRECTML_WORKER_URL = $WorkerUrl
& $PythonExe bridge\voice_v2_wire_benchmark.py `
  --output-dir $OutputDir `
  --chunk-bytes $ChunkBytes `
  --binary-delay-ms $BinaryDelayMs `
  --text-delay-ms $TextDelayMs `
  --max-first-audio-seconds $MaxFirstAudioSeconds `
  --max-wire-realtime-factor $MaxWireRealtimeFactor `
  --json
exit $LASTEXITCODE
