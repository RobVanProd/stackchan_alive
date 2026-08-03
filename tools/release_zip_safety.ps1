function Invoke-StackchanReleaseZipInspection {
  param(
    [Parameter(Mandatory = $true)][string]$ZipPath,
    [Parameter(Mandatory = $true)][string]$ExtractionRoot,
    [switch]$Extract
  )

  if (-not (Test-Path -LiteralPath $ZipPath -PathType Leaf)) {
    throw "Missing release ZIP: $ZipPath"
  }
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zipArchive = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $ZipPath).Path)
  try {
    $zipNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    $resolvedExtractionRoot = [System.IO.Path]::GetFullPath($ExtractionRoot).TrimEnd('\', '/')
    $extractionPrefix = $resolvedExtractionRoot + [System.IO.Path]::DirectorySeparatorChar
    $safeEntries = New-Object System.Collections.Generic.List[object]
    [long]$totalUncompressedBytes = 0
    foreach ($entry in $zipArchive.Entries) {
      $rawEntryName = ([string]$entry.FullName).Replace('\', '/')
      $entryName = $rawEntryName
      while ($entryName.StartsWith('./', [System.StringComparison]::Ordinal)) {
        $entryName = $entryName.Substring(2)
      }
      if ([string]::IsNullOrWhiteSpace($entryName) -and $rawEntryName -eq './') { continue }
      $segments = @($entryName.Split('/') | Where-Object { $_ -ne '' })
      $entryTarget = [System.IO.Path]::GetFullPath((Join-Path $ExtractionRoot ($entryName -replace '/', '\')))
      $unixFileType = (([int64]$entry.ExternalAttributes -shr 16) -band 0xF000)
      if ([string]::IsNullOrWhiteSpace($entryName) -or
          [System.IO.Path]::IsPathRooted($entryName) -or
          $entryName.Contains(':') -or
          $segments -contains '.' -or $segments -contains '..' -or
          -not $entryTarget.StartsWith($extractionPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
          -not $zipNames.Add($entryName.TrimEnd('/')) -or
          $unixFileType -eq 0xA000 -or
          (([int]$entry.ExternalAttributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
        throw "Release ZIP contains an unsafe, duplicate, or link entry: $rawEntryName"
      }
      $totalUncompressedBytes += [long]$entry.Length
      if ($zipNames.Count -gt 25000 -or
          [long]$entry.Length -gt 2147483648 -or
          $totalUncompressedBytes -gt 4294967296) {
        throw "Release ZIP exceeds the bounded extraction budget."
      }
      $safeEntries.Add([pscustomobject]@{
        Entry = $entry
        Name = $entryName
        Target = $entryTarget
        IsDirectory = $entryName.EndsWith('/', [System.StringComparison]::Ordinal)
      })
    }

    if ($Extract) {
      if (Test-Path -LiteralPath $resolvedExtractionRoot) {
        if (-not (Test-Path -LiteralPath $resolvedExtractionRoot -PathType Container) -or
            @(Get-ChildItem -LiteralPath $resolvedExtractionRoot -Force).Count -ne 0) {
          throw "Safe release ZIP extraction requires a fresh empty directory: $resolvedExtractionRoot"
        }
      } else {
        New-Item -ItemType Directory -Path $resolvedExtractionRoot | Out-Null
      }
      foreach ($safeEntry in $safeEntries) {
        if ($safeEntry.IsDirectory) {
          New-Item -ItemType Directory -Force -Path $safeEntry.Target | Out-Null
          continue
        }
        $parent = Split-Path -Parent $safeEntry.Target
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        $source = $safeEntry.Entry.Open()
        $destination = $null
        try {
          $destination = [System.IO.File]::Open(
            $safeEntry.Target,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None)
          $source.CopyTo($destination)
        } finally {
          if ($null -ne $destination) { $destination.Dispose() }
          $source.Dispose()
        }
      }
    }
  } finally {
    $zipArchive.Dispose()
  }
}

function Assert-StackchanReleaseZipEntriesSafe {
  param(
    [Parameter(Mandatory = $true)][string]$ZipPath,
    [Parameter(Mandatory = $true)][string]$ExtractionRoot
  )

  Invoke-StackchanReleaseZipInspection -ZipPath $ZipPath -ExtractionRoot $ExtractionRoot
}

function Expand-StackchanReleaseZipSafely {
  param(
    [Parameter(Mandatory = $true)][string]$ZipPath,
    [Parameter(Mandatory = $true)][string]$DestinationPath
  )

  Invoke-StackchanReleaseZipInspection `
    -ZipPath $ZipPath -ExtractionRoot $DestinationPath -Extract
}
