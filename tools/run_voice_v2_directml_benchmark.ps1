param(
  [string]$PythonExe = "C:\stackchan_dml_venv\Scripts\python.exe",
  [string]$VendorPath = "output\voice-lab\vendor\rvc-webui",
  [string]$ModelPath = "output\voice_sources\stackchan_rvc_base\model\model.pth",
  [string]$IndexPath = "output\voice_sources\stackchan_rvc_base\model\model.index",
  [string]$OutputDir = "output\voice-lab\directml-latest",
  [double]$MaxFirstAudioSeconds = 3.0,
  [double]$MaxMedianRealtimeFactor = 1.0,
  [double]$IndexRate = 0.62,
  [string]$F0Method = "rmvpe"
)

$ErrorActionPreference = "Stop"
$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $RepoRoot

foreach ($RequiredPath in @($PythonExe, $VendorPath, $ModelPath, $IndexPath)) {
  if (-not (Test-Path -LiteralPath $RequiredPath)) {
    throw "Required DirectML benchmark path not found: $RequiredPath"
  }
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
& $PythonExe bridge\voice_v2_directml_benchmark.py `
  --vendor-root $VendorPath `
  --model $ModelPath `
  --index $IndexPath `
  --output-dir $OutputDir `
  --max-first-audio-seconds $MaxFirstAudioSeconds `
  --max-median-realtime-factor $MaxMedianRealtimeFactor `
  --index-rate $IndexRate `
  --f0-method $F0Method `
  --json
exit $LASTEXITCODE
