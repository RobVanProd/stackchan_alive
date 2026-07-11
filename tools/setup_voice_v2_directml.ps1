param(
  [string]$PythonExe = "",
  [string]$VenvPath = "C:\stackchan_dml_venv",
  [string]$VendorPath = "output\voice-lab\vendor\rvc-webui",
  [string]$HubertSource = ""
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

if ([string]::IsNullOrWhiteSpace($PythonExe)) {
  $PythonCandidates = @(
    $env:STACKCHAN_PYTHON310,
    (Join-Path $env:LOCALAPPDATA "Programs\Python\Python310\python.exe"),
    (Get-Command python.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1)
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
  $PythonExe = $PythonCandidates | Select-Object -First 1
}

if (-not $PythonExe -or -not (Test-Path -LiteralPath $PythonExe)) {
  throw "Python 3.10 runtime not found. Set STACKCHAN_PYTHON310 or pass -PythonExe."
}

if (-not (Test-Path -LiteralPath (Join-Path $VendorPath ".git"))) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $VendorPath) | Out-Null
  git clone --depth 1 https://github.com/RVC-Project/Retrieval-based-Voice-Conversion-WebUI.git $VendorPath
  if ($LASTEXITCODE -ne 0) {
    throw "Could not clone the official RVC project"
  }
}

$VenvPython = Join-Path $VenvPath "Scripts\python.exe"
if (-not (Test-Path -LiteralPath $VenvPython)) {
  & $PythonExe -m venv $VenvPath
  if ($LASTEXITCODE -ne 0) {
    throw "Could not create DirectML environment: $VenvPath"
  }
}

$Constraints = Join-Path $RepoRoot "tools\voice_v2_directml_constraints.txt"
$Requirements = Join-Path $VendorPath "requirements-dml.txt"

& $VenvPython -m pip install --disable-pip-version-check "pip==24.0" "setuptools<81" wheel
if ($LASTEXITCODE -ne 0) {
  throw "Could not install the DirectML packaging toolchain"
}

& $VenvPython -m pip install --disable-pip-version-check -c $Constraints `
  "torch-directml==0.2.5.dev240914" "torchaudio==2.4.1"
if ($LASTEXITCODE -ne 0) {
  throw "Could not install the pinned DirectML runtime"
}

& $VenvPython -m pip install --disable-pip-version-check -c $Constraints -r $Requirements
if ($LASTEXITCODE -ne 0) {
  throw "Could not install the official RVC DirectML dependencies"
}

$HubertCandidates = @(
  $HubertSource,
  $env:STACKCHAN_RVC_HUBERT_PATH,
  "C:\stackchan_rocm_venv\Lib\site-packages\rvc_python\base_model\hubert_base.pt",
  (Join-Path $VendorPath "assets\hubert\hubert_base.pt")
) | Where-Object { $_ -and (Test-Path -LiteralPath $_) }
$HubertSource = $HubertCandidates | Select-Object -First 1
$HubertTarget = Join-Path $VendorPath "assets\hubert\hubert_base.pt"
if (-not $HubertSource) {
  throw "HuBERT source asset not found. Set STACKCHAN_RVC_HUBERT_PATH or pass -HubertSource."
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $HubertTarget) | Out-Null
if (-not (Test-Path -LiteralPath $HubertTarget)) {
  Copy-Item -LiteralPath $HubertSource -Destination $HubertTarget
}

$Probe = @'
import json
import torch
import torch_directml
import fairseq
import faiss
import onnxruntime

device = torch_directml.device(torch_directml.default_device())
value = torch.tensor([1.0, 2.0], device=device).sum().cpu().item()
print(json.dumps({
    "ready": value == 3.0,
    "torch": torch.__version__,
    "device": str(device),
    "fairseq": getattr(fairseq, "__version__", "unknown"),
    "faiss": getattr(faiss, "__version__", "unknown"),
    "onnx_providers": onnxruntime.get_available_providers(),
}))
'@
$ProbeOutput = $Probe | & $VenvPython -
if ($LASTEXITCODE -ne 0) {
  throw "DirectML import/device probe failed"
}
$ProbeOutput
