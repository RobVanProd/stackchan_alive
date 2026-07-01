param(
  [string]$ManifestPath = "data/voice_rvc_base.yaml",
  [string]$MetadataPath = "data/voice_rvc_base_metadata.json",
  [string]$ZipPath = "",
  [switch]$RequireLocalModel
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Push-Location $repoRoot
trap {
  Pop-Location
  throw
}

function Assert-Text {
  param(
    [string]$Path,
    [string[]]$Patterns
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Missing file: $Path"
  }
  $text = Get-Content -LiteralPath $Path -Raw
  foreach ($pattern in $Patterns) {
    if ($text -notmatch [regex]::Escape($pattern)) {
      throw "$Path missing RVC base marker: $pattern"
    }
  }
}

Assert-Text $ManifestPath @(
  "schema: stackchan.rvc-voice-base.v1",
  "status: candidate-pending-rights-review",
  "drive_file_id: 1I5A2kfTDE-VPWVo_cGIRRObkGv5w9Spb",
  "weights_model_id: clyaxlb9b000eoiqywl68wcrc",
  "sha256: CA0BFE7A889D81532A449307057718BF83B343BD09D6B69CAF2DFB79450EF9AE",
  "consumer_approved: false",
  "license_or_consent_evidence"
)
Assert-Text $MetadataPath @(
  '"title": "joh"',
  '"name": "triceratops"',
  '"id": "clyaxlb9b000eoiqywl68wcrc"',
  '"type": "v2"',
  '"sr": 48000',
  '"f0": 1'
)

if ([string]::IsNullOrWhiteSpace($ZipPath)) {
  $ZipPath = "output/voice_sources/stackchan_rvc_base/stackchan_voice_weightsgg_model.zip"
}

if (-not (Test-Path -LiteralPath $ZipPath)) {
  if ($RequireLocalModel) {
    throw "Missing local RVC model ZIP: $ZipPath"
  }
  Write-Host "RVC voice base manifest verified. Local model ZIP not present; pass -RequireLocalModel to require it."
  Pop-Location
  exit 0
}

$zipItem = Get-Item -LiteralPath $ZipPath
if ($zipItem.Length -ne 145623728) {
  throw "RVC model ZIP size mismatch: expected 145623728, got $($zipItem.Length)"
}

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ZipPath).Hash.ToUpperInvariant()
if ($hash -ne "CA0BFE7A889D81532A449307057718BF83B343BD09D6B69CAF2DFB79450EF9AE") {
  throw "RVC model ZIP SHA256 mismatch: $hash"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $ZipPath).Path)
try {
  $expectedEntries = @(
    @{ Path = "model.pth"; Bytes = 57577722 },
    @{ Path = "model.index"; Bytes = 99428699 },
    @{ Path = "metadata.json"; Bytes = 2781 }
  )

  foreach ($expected in $expectedEntries) {
    $entry = $zip.GetEntry($expected.Path)
    if ($null -eq $entry) {
      throw "RVC model ZIP missing entry: $($expected.Path)"
    }
    if ($entry.Length -ne $expected.Bytes) {
      throw "RVC model ZIP entry size mismatch for $($expected.Path): expected $($expected.Bytes), got $($entry.Length)"
    }
  }

  $metadataEntry = $zip.GetEntry("metadata.json")
  $reader = New-Object System.IO.StreamReader($metadataEntry.Open())
  try {
    $metadataText = $reader.ReadToEnd()
  } finally {
    $reader.Dispose()
  }

  foreach ($pattern in @('"title": "joh"', '"weightsLink": "https://www.weights.gg/models/clyaxlb9b000eoiqywl68wcrc"', '"sr": 48000', '"version": "v2"')) {
    if ($metadataText -notmatch [regex]::Escape($pattern)) {
      throw "RVC model ZIP metadata missing expected marker: $pattern"
    }
  }
} finally {
  $zip.Dispose()
}

Write-Host "RVC voice base verified:"
Write-Host (Resolve-Path $ZipPath)
Write-Host "SHA256 $hash"
Pop-Location
