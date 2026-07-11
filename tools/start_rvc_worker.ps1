param(
  [string]$PythonExe = "C:\stackchan_rocm_venv\Scripts\python.exe",
  [string]$Device = "cuda:0",
  [string]$Method = "pm",
  [int]$Port = 5055,
  [switch]$StopExisting,
  [switch]$Background
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$WorkerScript = Join-Path $RepoRoot "bridge\rvc_worker_service.py"
$LogDir = Join-Path $RepoRoot "output\rvc-worker"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

if ($StopExisting) {
  Get-CimInstance Win32_Process |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains("rvc_worker_service.py") } |
    ForEach-Object {
      Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

if (!(Test-Path $PythonExe)) {
  throw "Python runtime not found: $PythonExe"
}

$env:TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD = "1"
$env:STACKCHAN_RVC_DEVICE = $Device
$env:STACKCHAN_RVC_F0_METHOD = $Method
$env:STACKCHAN_RVC_WORKER_PORT = [string]$Port

$args = @(
  "-u",
  $WorkerScript,
  "--host", "127.0.0.1",
  "--port", [string]$Port,
  "--device", $Device,
  "--method", $Method
)

if ($Background) {
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $stdout = Join-Path $LogDir "rvc_worker_$stamp.out.log"
  $stderr = Join-Path $LogDir "rvc_worker_$stamp.err.log"
  $proc = Start-Process -FilePath $PythonExe -ArgumentList $args -WorkingDirectory $RepoRoot -RedirectStandardOutput $stdout -RedirectStandardError $stderr -WindowStyle Hidden -PassThru
  [pscustomobject]@{
    pid = $proc.Id
    url = "http://127.0.0.1:$Port"
    device = $Device
    method = $Method
    stdout = $stdout
    stderr = $stderr
  } | ConvertTo-Json -Depth 3
} else {
  & $PythonExe @args
}
