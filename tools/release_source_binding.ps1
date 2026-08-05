function ConvertTo-StackchanPackageReadmeText {
  param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

  $canonicalLf = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
  $rewritten = $canonicalLf.Replace('](docs/media/', '](media/')
  return $rewritten.Replace("`n", "`r`n")
}

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

function Resolve-StackchanCommitBoundPackageLeaf {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$RelativePath,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if ([string]::IsNullOrWhiteSpace($RelativePath) -or
      [System.IO.Path]::IsPathRooted($RelativePath) -or
      $RelativePath.Contains(':')) {
    throw "$Label path must be a safe relative path: $RelativePath"
  }
  $segments = @($RelativePath.Replace('\', '/').Split('/') | Where-Object { $_ -ne '' })
  if ($segments.Count -eq 0 -or $segments -contains '.' -or $segments -contains '..') {
    throw "$Label path contains traversal: $RelativePath"
  }

  $rootItem = Get-Item -LiteralPath (Resolve-Path -LiteralPath $Root).Path -Force
  if (-not $rootItem.PSIsContainer -or
      ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    throw "$Label root must be one exact non-redirected directory: $Root"
  }
  $resolvedRoot = $rootItem.FullName.TrimEnd('\', '/')
  $rootPrefix = $resolvedRoot + [System.IO.Path]::DirectorySeparatorChar
  $leafPath = [System.IO.Path]::GetFullPath((Join-Path $resolvedRoot $RelativePath))
  if (-not $leafPath.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "$Label path escapes its root: $RelativePath"
  }

  $cursor = $resolvedRoot
  for ($index = 0; $index -lt $segments.Count; $index++) {
    $cursor = Join-Path $cursor $segments[$index]
    $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
      throw "$Label path contains a redirected component: $RelativePath"
    }
    $isLeaf = $index -eq ($segments.Count - 1)
    if (($isLeaf -and $item.PSIsContainer) -or (-not $isLeaf -and -not $item.PSIsContainer)) {
      throw "$Label path has an invalid component type: $RelativePath"
    }
  }
  return $leafPath
}

function Get-StackchanStreamSha256 {
  param([Parameter(Mandatory = $true)][System.IO.Stream]$Stream)

  $hasher = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([System.BitConverter]::ToString($hasher.ComputeHash($Stream)) -replace '-', '').ToUpperInvariant()
  } finally {
    $hasher.Dispose()
  }
}

function Get-StackchanUtf8GitBlobHash {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)][ValidateSet(40, 64)][int]$HashLength
  )

  $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
  $contentBytes = $utf8.GetBytes($Text)
  $headerBytes = [System.Text.Encoding]::ASCII.GetBytes("blob $($contentBytes.Length)`0")
  $objectBytes = New-Object byte[] ($headerBytes.Length + $contentBytes.Length)
  [System.Array]::Copy($headerBytes, 0, $objectBytes, 0, $headerBytes.Length)
  [System.Array]::Copy($contentBytes, 0, $objectBytes, $headerBytes.Length, $contentBytes.Length)
  $hasher = if ($HashLength -eq 40) {
    [System.Security.Cryptography.SHA1]::Create()
  } else {
    [System.Security.Cryptography.SHA256]::Create()
  }
  try {
    return (($hasher.ComputeHash($objectBytes) | ForEach-Object { $_.ToString('x2') }) -join '')
  } finally {
    $hasher.Dispose()
  }
}

function ConvertTo-StackchanCanonicalLfsPointerRecord {
  param(
    [Parameter(Mandatory = $true)][string]$PointerText,
    [Parameter(Mandatory = $true)][string]$RelativePath
  )

  $pointerMatch = [regex]::Match(
    $PointerText,
    '\Aversion https://git-lfs\.github\.com/spec/v1\noid sha256:([0-9a-f]{64})\nsize (0|[1-9][0-9]*)\n\z',
    [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
  if (-not $pointerMatch.Success) {
    throw "Commit-bound LFS pointer is not canonical: $RelativePath"
  }
  $expectedSha256 = $pointerMatch.Groups[1].Value.ToUpperInvariant()
  [int64]$expectedLength = 0
  if (-not [int64]::TryParse(
      $pointerMatch.Groups[2].Value,
      [System.Globalization.NumberStyles]::None,
      [System.Globalization.CultureInfo]::InvariantCulture,
      [ref]$expectedLength)) {
    throw "Commit-bound LFS pointer size is outside Int64 range: $RelativePath"
  }

  return [pscustomobject]@{
    relativePath = $RelativePath.Replace('\', '/')
    bytes = $expectedLength
    sha256 = $expectedSha256
  }
}

function Get-StackchanCommitBoundLfsPointerRecord {
  param(
    [Parameter(Mandatory = $true)][string]$CommitPointerRoot,
    [Parameter(Mandatory = $true)][string]$RelativePath
  )

  $pointerPath = Resolve-StackchanCommitBoundPackageLeaf `
    -Root $CommitPointerRoot -RelativePath $RelativePath -Label 'Commit-bound LFS pointer'
  $pointerBytes = [System.IO.File]::ReadAllBytes($pointerPath)
  if ($pointerBytes.Length -eq 0 -or $pointerBytes.Length -gt 1024) {
    throw "Commit-bound LFS pointer has an invalid byte count: $RelativePath"
  }
  $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
  try {
    $pointerText = $strictUtf8.GetString($pointerBytes)
  } catch {
    throw "Commit-bound LFS pointer is not strict UTF-8: $RelativePath"
  }
  return ConvertTo-StackchanCanonicalLfsPointerRecord `
    -PointerText $pointerText -RelativePath $RelativePath
}

function Copy-StackchanCommitBoundLfsPackageFile {
  param(
    [Parameter(Mandatory = $true)][string]$CommitPointerRoot,
    [Parameter(Mandatory = $true)][string]$GitCommonDir,
    [Parameter(Mandatory = $true)][string]$RelativePath,
    [Parameter(Mandatory = $true)][string]$DestinationPath,
    [Parameter(Mandatory = $true)][int64]$ExpectedBytes,
    [Parameter(Mandatory = $true)][string]$ExpectedSha256
  )

  $pointer = Get-StackchanCommitBoundLfsPointerRecord `
    -CommitPointerRoot $CommitPointerRoot -RelativePath $RelativePath
  $normalizedExpectedSha256 = $ExpectedSha256.ToUpperInvariant()
  if ($ExpectedBytes -lt 0 -or $normalizedExpectedSha256 -notmatch '^[0-9A-F]{64}$' -or
      [int64]$pointer.bytes -ne $ExpectedBytes -or
      [string]$pointer.sha256 -cne $normalizedExpectedSha256) {
    throw "Commit-bound LFS pointer does not match the reviewed release asset: $RelativePath"
  }
  $commonDirItem = Get-Item -LiteralPath (Resolve-Path -LiteralPath $GitCommonDir).Path -Force
  if (-not $commonDirItem.PSIsContainer -or
      ($commonDirItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    throw "Git common directory must be one exact non-redirected directory: $GitCommonDir"
  }
  $localLfsRoot = Join-Path $commonDirItem.FullName 'lfs'
  $localLfsRootItem = Get-Item -LiteralPath $localLfsRoot -Force -ErrorAction Stop
  if (-not $localLfsRootItem.PSIsContainer -or
      ($localLfsRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    throw "Local LFS directory must be one exact non-redirected directory: $localLfsRoot"
  }
  $localLfsObjectRoot = Join-Path $localLfsRootItem.FullName 'objects'
  $localLfsObjectRootItem = Get-Item -LiteralPath $localLfsObjectRoot -Force -ErrorAction Stop
  if (-not $localLfsObjectRootItem.PSIsContainer -or
      ($localLfsObjectRootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    throw "Local LFS object root must be one exact non-redirected directory: $localLfsObjectRoot"
  }
  $objectRelativePath = Join-Path `
    (Join-Path $normalizedExpectedSha256.Substring(0, 2).ToLowerInvariant() `
      $normalizedExpectedSha256.Substring(2, 2).ToLowerInvariant()) `
    $normalizedExpectedSha256.ToLowerInvariant()
  $materializedPath = Resolve-StackchanCommitBoundPackageLeaf `
    -Root $localLfsObjectRootItem.FullName -RelativePath $objectRelativePath -Label 'Local LFS object'

  $destinationFullPath = [System.IO.Path]::GetFullPath($DestinationPath)
  if (Test-Path -LiteralPath $destinationFullPath) {
    throw "Commit-bound LFS package destination already exists: $destinationFullPath"
  }
  $destinationParent = Split-Path -Parent $destinationFullPath
  New-Item -ItemType Directory -Force -Path $destinationParent | Out-Null
  $destinationParentItem = Get-Item -LiteralPath $destinationParent -Force
  if (-not $destinationParentItem.PSIsContainer -or
      ($destinationParentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    throw "Commit-bound LFS package destination parent is redirected: $destinationParent"
  }

  $temporaryPath = $destinationFullPath + '.lfs-stage-' + [guid]::NewGuid().ToString('N')

  try {
    $sourceStream = [System.IO.File]::Open(
      $materializedPath,
      [System.IO.FileMode]::Open,
      [System.IO.FileAccess]::Read,
      [System.IO.FileShare]::Read)
    try {
      if ($sourceStream.Length -ne $ExpectedBytes) {
        throw "Materialized LFS source byte count does not match the commit pointer: $RelativePath"
      }
      $sourceSha256 = Get-StackchanStreamSha256 -Stream $sourceStream
      if ($sourceSha256 -cne $normalizedExpectedSha256) {
        throw "Materialized LFS source SHA-256 does not match the commit pointer: $RelativePath"
      }
      $sourceStream.Position = 0
      $destinationStream = [System.IO.File]::Open(
        $temporaryPath,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None)
      try {
        $sourceStream.CopyTo($destinationStream)
        $destinationStream.Flush()
      } finally {
        $destinationStream.Dispose()
      }
    } finally {
      $sourceStream.Dispose()
    }
    $packagedStream = [System.IO.File]::Open(
      $temporaryPath,
      [System.IO.FileMode]::Open,
      [System.IO.FileAccess]::Read,
      [System.IO.FileShare]::Read)
    try {
      if ($packagedStream.Length -ne $ExpectedBytes -or
          (Get-StackchanStreamSha256 -Stream $packagedStream) -cne $normalizedExpectedSha256) {
        throw "Packaged LFS payload does not match the commit pointer: $RelativePath"
      }
    } finally {
      $packagedStream.Dispose()
    }
    [System.IO.File]::Move($temporaryPath, $destinationFullPath)
  } finally {
    if (Test-Path -LiteralPath $temporaryPath) {
      Remove-Item -LiteralPath $temporaryPath -Force
    }
  }

  return [pscustomobject]@{
    relativePath = $RelativePath.Replace('\', '/')
    bytes = $ExpectedBytes
    sha256 = $normalizedExpectedSha256
  }
}

function Assert-StackchanPackageLfsPayloadMatchesCommitPointer {
  param(
    [Parameter(Mandatory = $true)][string]$CommitPointerRoot,
    [Parameter(Mandatory = $true)][string]$RelativePath,
    [Parameter(Mandatory = $true)][string]$PackagePath
  )

  $pointer = Get-StackchanCommitBoundLfsPointerRecord `
    -CommitPointerRoot $CommitPointerRoot -RelativePath $RelativePath
  Assert-StackchanPackageLfsPayloadMatchesPointerRecord `
    -Pointer $pointer -PackagePath $PackagePath
}

function Assert-StackchanPackageLfsPayloadMatchesPointerRecord {
  param(
    [Parameter(Mandatory = $true)][object]$Pointer,
    [Parameter(Mandatory = $true)][string]$PackagePath
  )

  if ([string]$Pointer.relativePath -notmatch '^[^:]+$' -or
      [int64]$Pointer.bytes -lt 0 -or
      [string]$Pointer.sha256 -notmatch '^[0-9A-F]{64}$') {
    throw 'Packaged LFS payload received an invalid trusted pointer record.'
  }
  $packageItem = Get-Item -LiteralPath $PackagePath -Force -ErrorAction Stop
  if ($packageItem.PSIsContainer -or
      ($packageItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    throw "Packaged LFS payload must be one exact non-redirected file: $PackagePath"
  }
  $packageStream = [System.IO.File]::Open(
    $packageItem.FullName,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::Read)
  try {
    if ($packageStream.Length -ne [int64]$pointer.bytes -or
        (Get-StackchanStreamSha256 -Stream $packageStream) -cne [string]$pointer.sha256) {
      throw "Packaged LFS payload does not match the trusted commit pointer: $([string]$pointer.relativePath)"
    }
  } finally {
    $packageStream.Dispose()
  }
}

function Assert-StackchanLfsSourceBindingRecord {
  param(
    [Parameter(Mandatory = $true)][object[]]$ManifestBindings,
    [Parameter(Mandatory = $true)][string]$SourcePath,
    [Parameter(Mandatory = $true)][string]$ExpectedCommit,
    [Parameter(Mandatory = $true)][string]$PointerBlob,
    [Parameter(Mandatory = $true)][object]$Pointer
  )

  $manifestBinding = @($ManifestBindings | Where-Object {
    [string]$_.sourcePath -ceq $SourcePath
  })
  if ($manifestBinding.Count -ne 1 -or
      [string]$manifestBinding[0].sourceCommit -cne $ExpectedCommit -or
      [string]$manifestBinding[0].pointerBlob -cne $PointerBlob -or
      [int64]$manifestBinding[0].bytes -ne [int64]$Pointer.bytes -or
      [string]$manifestBinding[0].sha256 -cne [string]$Pointer.sha256 -or
      [string]$manifestBinding[0].policy -cne
        'offline-local-lfs-object-bound-to-commit-pointer-v1') {
    throw "Operational package manifest RVC LFS binding is invalid: $SourcePath"
  }
}
