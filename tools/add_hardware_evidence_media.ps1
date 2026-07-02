param(
  [string]$EvidenceRoot = "",
  [ValidateSet("Auto", "Photo", "Audio")]
  [string]$Type = "Auto",
  [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
  [string[]]$MediaPath = @(),
  [string]$Notes = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

if ([string]::IsNullOrWhiteSpace($EvidenceRoot)) {
  $latestEvidence = Get-ChildItem -Directory -Path "output/hardware-evidence" -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    Select-Object -First 1

  if ($null -eq $latestEvidence) {
    throw "No evidence packet found under output/hardware-evidence. Pass -EvidenceRoot explicitly."
  }
  $EvidenceRoot = $latestEvidence.FullName
}

if (-not (Test-Path -LiteralPath $EvidenceRoot)) {
  throw "Missing evidence packet: $EvidenceRoot"
}

if ($MediaPath.Count -lt 1) {
  throw "Pass at least one media path. Example: .\tools\add_hardware_evidence_media.cmd -EvidenceRoot output\hardware-evidence\<packet> -Type Photo C:\path\device-face.jpg"
}

$evidencePath = (Resolve-Path $EvidenceRoot).Path
$photosDir = Join-Path $evidencePath "photos"
$audioDir = Join-Path $evidencePath "audio"
New-Item -ItemType Directory -Force -Path $photosDir, $audioDir | Out-Null

function Test-BytesAtOffset {
  param(
    [byte[]]$Bytes,
    [byte[]]$Expected,
    [int]$Offset = 0
  )

  if ($Bytes.Length -lt ($Offset + $Expected.Length)) {
    return $false
  }

  for ($i = 0; $i -lt $Expected.Length; $i++) {
    if ($Bytes[$Offset + $i] -ne $Expected[$i]) {
      return $false
    }
  }

  return $true
}

function Get-BigEndianUInt16 {
  param([byte[]]$Bytes, [int]$Offset)
  if ($Bytes.Length -lt ($Offset + 2)) {
    throw "Not enough bytes to read UInt16 at offset $Offset"
  }
  return (($Bytes[$Offset] -shl 8) -bor $Bytes[$Offset + 1])
}

function Get-BigEndianUInt32 {
  param([byte[]]$Bytes, [int]$Offset)
  if ($Bytes.Length -lt ($Offset + 4)) {
    throw "Not enough bytes to read UInt32 at offset $Offset"
  }
  return (($Bytes[$Offset] -shl 24) -bor ($Bytes[$Offset + 1] -shl 16) -bor ($Bytes[$Offset + 2] -shl 8) -bor $Bytes[$Offset + 3])
}

function Get-LittleEndianUInt16 {
  param([byte[]]$Bytes, [int]$Offset)
  if ($Bytes.Length -lt ($Offset + 2)) {
    throw "Not enough bytes to read UInt16 at offset $Offset"
  }
  return ($Bytes[$Offset] -bor ($Bytes[$Offset + 1] -shl 8))
}

function Get-JpegDimensions {
  param([byte[]]$Bytes)

  if (-not (Test-BytesAtOffset -Bytes $Bytes -Expected ([byte[]](0xff, 0xd8, 0xff)))) {
    return $null
  }

  $offset = 2
  while ($offset -lt ($Bytes.Length - 9)) {
    while ($offset -lt $Bytes.Length -and $Bytes[$offset] -ne 0xff) {
      $offset++
    }
    while ($offset -lt $Bytes.Length -and $Bytes[$offset] -eq 0xff) {
      $offset++
    }
    if ($offset -ge $Bytes.Length) {
      break
    }

    $marker = $Bytes[$offset]
    $offset++
    if ($marker -eq 0xd9 -or $marker -eq 0xda) {
      break
    }
    if ($offset + 2 -gt $Bytes.Length) {
      break
    }

    $segmentLength = Get-BigEndianUInt16 $Bytes $offset
    if ($segmentLength -lt 2 -or ($offset + $segmentLength) -gt $Bytes.Length) {
      break
    }

    if (@(0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf) -contains $marker) {
      if ($segmentLength -lt 7) {
        return $null
      }
      return [pscustomobject]@{
        Width = Get-BigEndianUInt16 $Bytes ($offset + 5)
        Height = Get-BigEndianUInt16 $Bytes ($offset + 3)
      }
    }

    $offset += $segmentLength
  }

  return $null
}

function Read-FilePrefix {
  param([System.IO.FileInfo]$File)

  $bytesToRead = [Math]::Min([int64]$File.Length, [int64]1048576)
  if ($bytesToRead -lt 12) {
    throw "Media evidence file is too small to inspect: $($File.FullName)"
  }

  $stream = [System.IO.File]::OpenRead($File.FullName)
  try {
    $bytes = New-Object byte[] ([int]$bytesToRead)
    $read = $stream.Read($bytes, 0, $bytes.Length)
    if ($read -lt $bytes.Length) {
      throw "Could not read media file prefix: $($File.FullName)"
    }
    return $bytes
  } finally {
    $stream.Dispose()
  }
}

function Test-PhotoEvidenceFile {
  param([System.IO.FileInfo]$File)

  $extension = $File.Extension.ToLowerInvariant()
  if (@(".png", ".jpg", ".jpeg", ".gif", ".mp4", ".mov", ".webm") -notcontains $extension) {
    return $false
  }

  $minimumBytes = 512
  if (@(".mp4", ".mov", ".webm") -contains $extension) {
    $minimumBytes = 8192
  }
  if ($File.Length -lt $minimumBytes) {
    throw "Photo/video evidence file is too small to be credible: $($File.Name) ($($File.Length) bytes)"
  }

  $bytes = Read-FilePrefix $File
  switch ($extension) {
    ".png" {
      if (-not (Test-BytesAtOffset -Bytes $bytes -Expected ([byte[]](0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)))) { return $false }
      if ($bytes.Length -lt 24) { return $false }
      return ((Get-BigEndianUInt32 $bytes 16) -ge 32 -and (Get-BigEndianUInt32 $bytes 20) -ge 32)
    }
    ".jpg" {
      $dimensions = Get-JpegDimensions $bytes
      return ($null -ne $dimensions -and $dimensions.Width -ge 32 -and $dimensions.Height -ge 32)
    }
    ".jpeg" {
      $dimensions = Get-JpegDimensions $bytes
      return ($null -ne $dimensions -and $dimensions.Width -ge 32 -and $dimensions.Height -ge 32)
    }
    ".gif" {
      if (-not (Test-BytesAtOffset -Bytes $bytes -Expected ([byte[]](0x47, 0x49, 0x46, 0x38)))) { return $false }
      if ($bytes.Length -lt 10) { return $false }
      return ((Get-LittleEndianUInt16 $bytes 6) -ge 32 -and (Get-LittleEndianUInt16 $bytes 8) -ge 32)
    }
    ".mp4" { return Test-BytesAtOffset -Bytes $bytes -Expected ([byte[]](0x66, 0x74, 0x79, 0x70)) -Offset 4 }
    ".mov" { return Test-BytesAtOffset -Bytes $bytes -Expected ([byte[]](0x66, 0x74, 0x79, 0x70)) -Offset 4 }
    ".webm" { return Test-BytesAtOffset -Bytes $bytes -Expected ([byte[]](0x1a, 0x45, 0xdf, 0xa3)) }
  }

  return $false
}

function Test-AudioEvidenceFile {
  param([System.IO.FileInfo]$File)

  $extension = $File.Extension.ToLowerInvariant()
  if (@(".wav", ".mp3", ".m4a", ".aac", ".mp4", ".mov", ".webm") -notcontains $extension) {
    return $false
  }
  if ($File.Length -lt 4096) {
    throw "Audio evidence file is too small to be credible: $($File.Name) ($($File.Length) bytes)"
  }

  $bytes = Read-FilePrefix $File
  switch ($extension) {
    ".wav" {
      return (
        (Test-BytesAtOffset -Bytes $bytes -Expected ([byte[]](0x52, 0x49, 0x46, 0x46))) -and
        (Test-BytesAtOffset -Bytes $bytes -Expected ([byte[]](0x57, 0x41, 0x56, 0x45)) -Offset 8)
      )
    }
    ".mp3" {
      return (
        (Test-BytesAtOffset -Bytes $bytes -Expected ([byte[]](0x49, 0x44, 0x33))) -or
        ($bytes[0] -eq 0xff -and (($bytes[1] -band 0xe0) -eq 0xe0))
      )
    }
    ".m4a" { return Test-BytesAtOffset -Bytes $bytes -Expected ([byte[]](0x66, 0x74, 0x79, 0x70)) -Offset 4 }
    ".mp4" { return Test-BytesAtOffset -Bytes $bytes -Expected ([byte[]](0x66, 0x74, 0x79, 0x70)) -Offset 4 }
    ".mov" { return Test-BytesAtOffset -Bytes $bytes -Expected ([byte[]](0x66, 0x74, 0x79, 0x70)) -Offset 4 }
    ".webm" { return Test-BytesAtOffset -Bytes $bytes -Expected ([byte[]](0x1a, 0x45, 0xdf, 0xa3)) }
    ".aac" { return ($bytes[0] -eq 0xff -and (($bytes[1] -band 0xf0) -eq 0xf0)) }
  }

  return $false
}

function Get-UniqueDestination {
  param(
    [string]$Directory,
    [string]$FileName
  )

  $safeName = [System.IO.Path]::GetFileName($FileName) -replace '[^A-Za-z0-9_.-]', '_'
  if ([string]::IsNullOrWhiteSpace($safeName)) {
    $safeName = "evidence.bin"
  }

  $candidate = Join-Path $Directory $safeName
  if (-not (Test-Path -LiteralPath $candidate)) {
    return $candidate
  }

  $stem = [System.IO.Path]::GetFileNameWithoutExtension($safeName)
  $extension = [System.IO.Path]::GetExtension($safeName)
  for ($i = 2; $i -lt 1000; $i++) {
    $candidate = Join-Path $Directory "$stem-$i$extension"
    if (-not (Test-Path -LiteralPath $candidate)) {
      return $candidate
    }
  }

  throw "Could not create a unique destination for $FileName"
}

function Get-ExistingManifestEntries {
  param([string]$ManifestPath)

  if (-not (Test-Path -LiteralPath $ManifestPath)) {
    return @()
  }

  $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
  return @($manifest.entries)
}

$resolvedMedia = New-Object System.Collections.Generic.List[System.IO.FileInfo]
foreach ($path in $MediaPath) {
  $matches = @(Resolve-Path -Path $path -ErrorAction Stop)
  foreach ($match in $matches) {
    $item = Get-Item -LiteralPath $match.Path
    if ($item.PSIsContainer) {
      throw "Media path is a directory; pass files explicitly: $($item.FullName)"
    }
    $resolvedMedia.Add($item) | Out-Null
  }
}

$manifestPath = Join-Path $evidencePath "media_manifest.json"
$entries = New-Object System.Collections.Generic.List[object]
foreach ($entry in (Get-ExistingManifestEntries $manifestPath)) {
  $entries.Add($entry) | Out-Null
}

$imported = New-Object System.Collections.Generic.List[object]
foreach ($media in $resolvedMedia) {
  $kind = $Type.ToLowerInvariant()
  if ($Type -eq "Auto") {
    $extension = $media.Extension.ToLowerInvariant()
    if (@(".wav", ".mp3", ".m4a", ".aac") -contains $extension -and (Test-AudioEvidenceFile $media)) {
      $kind = "audio"
    } elseif (Test-PhotoEvidenceFile $media) {
      $kind = "photo"
    } else {
      throw "Unsupported evidence media file: $($media.FullName)"
    }
  } elseif ($Type -eq "Audio") {
    if (-not (Test-AudioEvidenceFile $media)) {
      throw "File is not valid audio evidence: $($media.FullName)"
    }
    $kind = "audio"
  } elseif ($Type -eq "Photo") {
    if (-not (Test-PhotoEvidenceFile $media)) {
      throw "File is not valid photo/video evidence: $($media.FullName)"
    }
    $kind = "photo"
  }

  $destinationDir = if ($kind -eq "audio") { $audioDir } else { $photosDir }
  $destination = Get-UniqueDestination -Directory $destinationDir -FileName $media.Name
  Copy-Item -LiteralPath $media.FullName -Destination $destination
  $copied = Get-Item -LiteralPath $destination
  $relativePath = $copied.FullName.Substring($evidencePath.Length + 1).Replace("\", "/")
  $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $copied.FullName).Hash.ToLowerInvariant()

  $record = [pscustomobject][ordered]@{
    importedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    kind = $kind
    relativePath = $relativePath
    sha256 = $hash
    sizeBytes = $copied.Length
    sourcePath = $media.FullName
    notes = $Notes
  }
  $entries.Add($record) | Out-Null
  $imported.Add($record) | Out-Null
}

$entryArray = @($entries | ForEach-Object { $_ })
$manifest = [ordered]@{
  schema = "stackchan.hardware-media-manifest.v1"
  evidenceRoot = $evidencePath
  updatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  entries = $entryArray
}
$manifest | ConvertTo-Json -Depth 6 | Set-Content -Path $manifestPath -Encoding UTF8

Write-Host "Imported hardware evidence media:"
foreach ($item in $imported) {
  Write-Host "  [$($item.kind)] $($item.relativePath) $($item.sha256)"
}
Write-Host "Manifest: $manifestPath"
