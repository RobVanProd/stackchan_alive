function Copy-StackchanCommitBoundPackageFile {
  param(
    [Parameter(Mandatory = $true)][string]$PackageSourceRoot,
    [Parameter(Mandatory = $true)][string]$RelativePath,
    [Parameter(Mandatory = $true)][string]$DestinationPath
  )

  if ([string]::IsNullOrWhiteSpace($RelativePath) -or
      [System.IO.Path]::IsPathRooted($RelativePath) -or
      $RelativePath.Contains(':')) {
    throw "Commit-bound package source path must be a safe relative path: $RelativePath"
  }
  $segments = @($RelativePath.Replace('\', '/').Split('/') | Where-Object { $_ -ne '' })
  if ($segments -contains '.' -or $segments -contains '..') {
    throw "Commit-bound package source path contains traversal: $RelativePath"
  }

  $sourceRoot = (Resolve-Path -LiteralPath $PackageSourceRoot).Path.TrimEnd('\', '/')
  $sourcePrefix = $sourceRoot + [System.IO.Path]::DirectorySeparatorChar
  $sourcePath = [System.IO.Path]::GetFullPath((Join-Path $sourceRoot $RelativePath))
  if (-not $sourcePath.StartsWith($sourcePrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
      -not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    throw "Missing or uncontained commit-bound package source: $RelativePath"
  }

  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $DestinationPath) | Out-Null
  Copy-Item -LiteralPath $sourcePath -Destination $DestinationPath -Force
}
