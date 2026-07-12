param(
  [Parameter(Mandatory = $true)]
  [string]$InputArchive,
  [Parameter(Mandatory = $true)]
  [string]$OutputArchive
)

$ErrorActionPreference = "Stop"

$inputPath = (Resolve-Path -LiteralPath $InputArchive).Path
$outputPath = [System.IO.Path]::GetFullPath($OutputArchive)
if ($inputPath -eq $outputPath) {
  throw "InputArchive and OutputArchive must be different paths."
}
if ([System.IO.Path]::GetExtension($inputPath) -ne ".zip" -or
    [System.IO.Path]::GetExtension($outputPath) -ne ".zip") {
  throw "Only ZIP archives are supported."
}

$outputDir = Split-Path -Parent $outputPath
if (-not (Test-Path -LiteralPath $outputDir)) {
  New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}
if (Test-Path -LiteralPath $outputPath) {
  Remove-Item -LiteralPath $outputPath -Force
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Test-RestrictedArchiveEntry {
  param([string]$EntryName)

  $name = $EntryName.Replace("\", "/")
  $allowedVisionModel = $name -match '(?i)^(provenance/)?bridge/models/face_detection_yunet_2023mar\.onnx$'
  return (
    (($name -match '(?i)(^|/)[^/]+\.(pth|index|onnx)$') -and -not $allowedVisionModel) -or
    $name -match '(?i)weightsgg|weights\.gg' -or
    $name -match '(?i)(^|/)media/voice/rvc/(?!README\.md$).+' -or
    $name -match '(?i)(^|/)[^/]*rvc[^/]*\.(wav|mp3|html)$'
  )
}

$source = [System.IO.Compression.ZipFile]::OpenRead($inputPath)
$destination = [System.IO.Compression.ZipFile]::Open(
  $outputPath,
  [System.IO.Compression.ZipArchiveMode]::Create
)
$removed = @()
try {
  foreach ($entry in $source.Entries) {
    $name = $entry.FullName.Replace("\", "/")
    if (Test-RestrictedArchiveEntry $name) {
      $removed += $name
      continue
    }

    $copy = $destination.CreateEntry($entry.FullName, [System.IO.Compression.CompressionLevel]::Optimal)
    $copy.LastWriteTime = $entry.LastWriteTime
    if (-not [string]::IsNullOrEmpty($entry.Name)) {
      $inputStream = $entry.Open()
      $outputStream = $copy.Open()
      try {
        $inputStream.CopyTo($outputStream)
      } finally {
        $outputStream.Dispose()
        $inputStream.Dispose()
      }
    }
  }
} finally {
  $destination.Dispose()
  $source.Dispose()
}

$verify = [System.IO.Compression.ZipFile]::OpenRead($outputPath)
try {
  $remainingRestricted = @($verify.Entries | Where-Object {
    Test-RestrictedArchiveEntry $_.FullName
  })
  if ($remainingRestricted.Count -gt 0) {
    throw "Sanitized archive still contains restricted voice payloads."
  }
} finally {
  $verify.Dispose()
}

[ordered]@{
  schema = "stackchan.public-archive-sanitizer.v1"
  input = $inputPath
  output = $outputPath
  outputSha256 = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash.ToLowerInvariant()
  removedEntries = $removed
} | ConvertTo-Json -Depth 4
