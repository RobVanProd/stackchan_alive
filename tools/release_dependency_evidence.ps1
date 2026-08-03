function Convert-StackchanPioPackageList {
  param([string]$Text)

  $entries = @()
  foreach ($line in ($Text -split "`r?`n")) {
    $clean = ($line -replace "^[^A-Za-z0-9]+", "").Trim()
    if ($clean -match "^Platform\s+(.+?)\s+@\s+([^\s]+)\s+\(required:\s*(.+)\)$") {
      $entries += [ordered]@{
        kind = "platform"
        name = $Matches[1]
        version = $Matches[2]
        required = $Matches[3]
      }
    } elseif ($clean -match "^(.+?)\s+@\s+([^\s]+)\s+\(required:\s*(.+)\)$") {
      $entries += [ordered]@{
        kind = "package"
        name = $Matches[1]
        version = $Matches[2]
        required = $Matches[3]
      }
    }
  }
  return @($entries)
}

function Get-StackchanResolvedCorePackageNames {
  param(
    [Parameter(Mandatory = $true)][object[]]$ResolvedPackages,
    [Parameter(Mandatory = $true)][string]$CorePackagesRoot
  )

  $names = @(
    $ResolvedPackages |
      Where-Object { $_.kind -eq 'package' } |
      ForEach-Object { [string]$_.name } |
      Sort-Object -Unique |
      Where-Object {
        if ($_ -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
          throw "Unsafe resolved PlatformIO package name: $_"
        }
        Test-Path -LiteralPath (Join-Path $CorePackagesRoot $_) -PathType Container
      }
  )
  return @($names)
}

function Get-StackchanVerbosePlatformSource {
  param(
    [Parameter(Mandatory = $true)][string]$VerbosePackageList,
    [Parameter(Mandatory = $true)][string]$PlatformioCoreDir
  )

  $platformLine = @($VerbosePackageList -split "`r?`n" | Where-Object { $_ -match '^Platform\s' })
  if ($platformLine.Count -ne 1 -or
      $platformLine[0] -notmatch '^Platform\s.+\s+@\s+\S+\s+\(required:\s*.+,\s*(.+)\)$') {
    throw 'Verbose PlatformIO inventory did not contain one resolved platform path.'
  }
  $candidate = [System.IO.Path]::GetFullPath($Matches[1].Trim())
  if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
    throw "Resolved PlatformIO platform directory is missing: $candidate"
  }
  $platformsRoot = [System.IO.Path]::GetFullPath((Join-Path $PlatformioCoreDir 'platforms')).TrimEnd('\', '/')
  $candidateParent = [System.IO.Path]::GetFullPath((Split-Path -Parent $candidate)).TrimEnd('\', '/')
  $leaf = Split-Path -Leaf $candidate
  if (-not $candidateParent.Equals($platformsRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
      $leaf -notmatch '^[A-Za-z0-9][A-Za-z0-9._@-]*$') {
    throw "Resolved PlatformIO platform escaped the selected core: $candidate"
  }
  return [pscustomobject][ordered]@{
    sourcePath = $candidate
    sourceLeaf = $leaf
  }
}

function Copy-StackchanResolvedCorePackageEvidence {
  param(
    [Parameter(Mandatory = $true)][string]$CorePackagesRoot,
    [Parameter(Mandatory = $true)][string]$DestinationRoot,
    [Parameter(Mandatory = $true)][string[]]$CorePackageNames
  )

  foreach ($packageName in @($CorePackageNames | Sort-Object -Unique)) {
    if ($packageName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
      throw "Unsafe resolved PlatformIO package name: $packageName"
    }
    $sourceRoot = Join-Path $CorePackagesRoot $packageName
    if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
      throw "Missing resolved PlatformIO core package: $packageName"
    }
    $resolvedSource = (Resolve-Path -LiteralPath $sourceRoot).Path.TrimEnd('\', '/')
    foreach ($file in Get-ChildItem -LiteralPath $resolvedSource -Recurse -File -Force -ErrorAction Stop) {
      if ($file.Name -notmatch '(?i)^(LICENSE|LICENCE|COPYING|NOTICE)(\..*)?$' -and
          $file.Name -notin @('library.json', 'library.properties', 'package.json', 'platform.json')) {
        continue
      }
      $relative = $file.FullName.Substring($resolvedSource.Length + 1)
      $destination = Join-Path (Join-Path $DestinationRoot $packageName) $relative
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
      Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
    }
  }
}

function Assert-StackchanCorePackageEvidenceAllowlisted {
  param(
    [Parameter(Mandatory = $true)][string]$Environment,
    [Parameter(Mandatory = $true)][string[]]$CorePackageNames,
    [Parameter(Mandatory = $true)][string[]]$IndexedThirdPartyPaths
  )

  $allowed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($name in @($CorePackageNames)) {
    if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or -not $allowed.Add($name)) {
      throw "Invalid or duplicate corePackageNames entry for $Environment`: $name"
    }
  }
  foreach ($relative in @($IndexedThirdPartyPaths)) {
    if ($relative -match ('^' + [regex]::Escape($Environment) + '/packages/([^/]+)/')) {
      $observedName = $Matches[1]
      if (-not $allowed.Contains($observedName)) {
        throw "Unlisted PlatformIO core package evidence for $Environment`: $observedName"
      }
    }
  }
}
