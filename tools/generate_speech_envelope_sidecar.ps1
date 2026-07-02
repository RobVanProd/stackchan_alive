param(
  [Parameter(Mandatory = $true)]
  [string]$InputWav,
  [string]$OutputJson = "",
  [int]$FrameMs = 20
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. (Join-Path $PSScriptRoot "preview_python_resolver.ps1")

if (-not (Test-Path -LiteralPath $InputWav)) {
  throw "Missing input WAV: $InputWav"
}

if ([string]::IsNullOrWhiteSpace($OutputJson)) {
  $inputItem = Get-Item -LiteralPath $InputWav
  $OutputJson = Join-Path $inputItem.DirectoryName ($inputItem.BaseName + ".speech_envelope.json")
}

if ($FrameMs -lt 10 -or $FrameMs -gt 100) {
  throw "FrameMs must be between 10 and 100. Received $FrameMs."
}

$pythonPath = Get-StackchanPreviewPython
& $pythonPath (Join-Path $PSScriptRoot "generate_speech_envelope_sidecar.py") `
  --input $InputWav `
  --output $OutputJson `
  --frame-ms $FrameMs
if ($LASTEXITCODE -ne 0) {
  throw "Speech envelope sidecar generation failed."
}
