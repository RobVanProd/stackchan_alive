param()

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$sanitizer = Join-Path $PSScriptRoot "sanitize_public_archive.ps1"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-public-archive-contract-" + [guid]::NewGuid().ToString("N"))
$inputRoot = Join-Path $tempRoot "input"
$inputZip = Join-Path $tempRoot "input.zip"
$outputZip = Join-Path $tempRoot "output.zip"

function Write-FixtureFile {
  param([string]$RelativePath, [string]$Content)
  $path = Join-Path $inputRoot ($RelativePath -replace "/", "\")
  New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
  Set-Content -LiteralPath $path -Value $Content -Encoding ASCII
}

try {
  Write-FixtureFile "README.md" "public"
  Write-FixtureFile "bridge/models/face_detection_yunet_2023mar.onnx" "approved-vision-model"
  Write-FixtureFile "provenance/bridge/models/face_detection_yunet_2023mar.onnx" "approved-vision-provenance"
  Write-FixtureFile "bridge/models/private_voice.onnx" "restricted"
  Write-FixtureFile "private/model.pth" "restricted"
  Write-FixtureFile "private/model.index" "restricted"
  Write-FixtureFile "media/voice/rvc/private.wav" "restricted"
  Write-FixtureFile "media/voice/RVC_AUDITION.html" "restricted"

  Compress-Archive -Path (Join-Path $inputRoot "*") -DestinationPath $inputZip
  $powerShellExe = (Get-Process -Id $PID).Path
  $output = & $powerShellExe -NoProfile -ExecutionPolicy Bypass -File $sanitizer `
    -InputArchive $inputZip -OutputArchive $outputZip
  if ($LASTEXITCODE -ne 0) {
    throw "Public archive sanitizer failed: $($output | Out-String)"
  }

  $report = ($output | Out-String) | ConvertFrom-Json
  if ($report.schema -ne "stackchan.public-archive-sanitizer.v1") {
    throw "Unexpected sanitizer report schema: $($report.schema)"
  }

  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [System.IO.Compression.ZipFile]::OpenRead($outputZip)
  try {
    $names = @($archive.Entries | ForEach-Object { $_.FullName.Replace("\", "/") })
  } finally {
    $archive.Dispose()
  }

  foreach ($required in @(
    "README.md",
    "bridge/models/face_detection_yunet_2023mar.onnx",
    "provenance/bridge/models/face_detection_yunet_2023mar.onnx"
  )) {
    if ($names -notcontains $required) {
      throw "Sanitized archive removed approved entry: $required"
    }
  }
  foreach ($restricted in @(
    "bridge/models/private_voice.onnx",
    "private/model.pth",
    "private/model.index",
    "media/voice/rvc/private.wav",
    "media/voice/RVC_AUDITION.html"
  )) {
    if ($names -contains $restricted) {
      throw "Sanitized archive retained restricted entry: $restricted"
    }
  }

  Write-Host "Public archive sanitizer contract verified."
} finally {
  $resolvedTemp = [System.IO.Path]::GetFullPath($tempRoot)
  $tempPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
  if ($resolvedTemp.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase) -and
      (Test-Path -LiteralPath $resolvedTemp)) {
    Remove-Item -LiteralPath $resolvedTemp -Recurse -Force
  }
}
