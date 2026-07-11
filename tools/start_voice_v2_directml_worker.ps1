param(
  [string]$PythonExe = "",
  [string]$VendorPath = "output\voice-lab\vendor\rvc-webui",
  [string]$ModelPath = "output\voice_sources\stackchan_rvc_base\model\model.pth",
  [string]$IndexPath = "output\voice_sources\stackchan_rvc_base\model\model.index",
  [string]$HostName = "127.0.0.1",
  [int]$Port = 5059,
  [string]$F0Method = "pm",
  [double]$IndexRate = 0.62,
  [switch]$NoWarmup,
  [switch]$StopExisting,
  [switch]$Background
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

if ([string]::IsNullOrWhiteSpace($PythonExe)) {
  $PythonCandidates = @(
    $env:STACKCHAN_DIRECTML_PYTHON,
    "C:\stackchan_dml_venv\Scripts\python.exe",
    (Join-Path $RepoRoot ".venv-directml\Scripts\python.exe")
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
  $PythonExe = $PythonCandidates | Select-Object -First 1
}
if (-not $PythonExe) {
  throw "DirectML Python runtime not found. Run setup_voice_v2_directml.ps1 or set STACKCHAN_DIRECTML_PYTHON."
}

foreach ($RequiredPath in @($PythonExe, $VendorPath, $ModelPath, $IndexPath)) {
  if (-not (Test-Path -LiteralPath $RequiredPath)) {
    throw "Required DirectML worker path not found: $RequiredPath"
  }
}

if ($StopExisting) {
  Get-CimInstance Win32_Process |
    Where-Object {
      $_.Name -like "python*.exe" -and
      $_.CommandLine -and
      $_.CommandLine.Contains("rvc_directml_worker_service.py")
    } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

$ArgsList = @(
  "-u",
  (Join-Path $RepoRoot "bridge\rvc_directml_worker_service.py"),
  "--host", $HostName,
  "--port", [string]$Port,
  "--vendor-root", (Resolve-Path $VendorPath),
  "--model", (Resolve-Path $ModelPath),
  "--index", (Resolve-Path $IndexPath),
  "--f0-method", $F0Method,
  "--index-rate", [string]$IndexRate
)
if ($NoWarmup) {
  $ArgsList += "--no-warmup"
}

if ($Background) {
  $LogDir = Join-Path $RepoRoot "output\voice-lab\directml-worker"
  New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
  $Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $Stdout = Join-Path $LogDir "worker-$Stamp.out.log"
  $Stderr = Join-Path $LogDir "worker-$Stamp.err.log"
  $Process = Start-Process -FilePath $PythonExe -ArgumentList $ArgsList -WorkingDirectory $RepoRoot `
    -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr -WindowStyle Hidden -PassThru
  [pscustomobject]@{
    pid = $Process.Id
    url = "http://$HostName`:$Port"
    backend = "torch-directml"
    method = $F0Method
    stdout = $Stdout
    stderr = $Stderr
  } | ConvertTo-Json -Depth 3
  exit 0
}

& $PythonExe @ArgsList
exit $LASTEXITCODE
