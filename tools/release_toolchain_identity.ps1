Set-StrictMode -Version Latest

$script:StackchanToolchainIdentitySchema = 'stackchan.release-toolchain-identity.v2'
$script:StackchanToolchainInventorySchema = 'stackchan.byte-tree.v1'
$script:StackchanCanonicalLibdepsSchema = 'stackchan.canonical-libdeps.v1'
$script:StackchanCanonicalGitLibrarySchema = 'stackchan.canonical-git-library.v1'

function Get-StackchanReleaseToolchainPlatformKey {
  if ($env:OS -eq 'Windows_NT') {
    $osName = 'windows'
  } elseif ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
      [System.Runtime.InteropServices.OSPlatform]::Linux)) {
    $osName = 'linux'
  } else {
    throw 'Release toolchain identity has no policy for this operating system.'
  }

  $architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
  if ($architecture -eq 'x64') { $architecture = 'amd64' }
  return "$osName`_$architecture"
}

function Assert-StackchanPythonImportIsolationState {
  param(
    [Parameter(Mandatory = $true)]$Probe,
    [Parameter(Mandatory = $true)][string]$PythonHome,
    [Parameter(Mandatory = $true)][string]$PythonExecutable
  )

  $pythonRoot = (Get-Item -LiteralPath $PythonHome -Force -ErrorAction Stop).FullName.TrimEnd('\', '/')
  $executable = (Get-Item -LiteralPath $PythonExecutable -Force -ErrorAction Stop).FullName
  $comparison = if ($env:OS -eq 'Windows_NT') {
    [StringComparison]::OrdinalIgnoreCase
  } else {
    [StringComparison]::Ordinal
  }
  if (-not ([IO.Path]::GetFullPath([string]$Probe.executable)).Equals($executable, $comparison) -or
      -not ([IO.Path]::GetFullPath([string]$Probe.prefix)).Equals($pythonRoot, $comparison) -or
      -not ([IO.Path]::GetFullPath([string]$Probe.base_prefix)).Equals($pythonRoot, $comparison) -or
      [bool]$Probe.enable_user_site -or
      [int]$Probe.flags.no_user_site -ne 1 -or
      -not [bool]$Probe.flags.safe_path -or
      [int]$Probe.flags.dont_write_bytecode -ne 1 -or
      [int]$Probe.flags.optimize -ne 0) {
    throw 'Python runtime did not prove the exact no-user-site/safe-path installation contract.'
  }
  $expectedPaths = @(
    Join-Path $pythonRoot 'python312.zip'
    Join-Path $pythonRoot 'DLLs'
    Join-Path $pythonRoot 'Lib'
    $pythonRoot
    Join-Path $pythonRoot 'Lib/site-packages'
  ) | ForEach-Object { [IO.Path]::GetFullPath($_) }
  $actualPaths = @($Probe.path | ForEach-Object {
    if ([string]::IsNullOrWhiteSpace([string]$_) -or -not [IO.Path]::IsPathRooted([string]$_)) {
      throw "Python import path is empty or relative: $_"
    }
    [IO.Path]::GetFullPath([string]$_)
  })
  if ($actualPaths.Count -ne $expectedPaths.Count) {
    throw 'Python import path contains an external, missing, or duplicate entry.'
  }
  for ($i = 0; $i -lt $expectedPaths.Count; $i++) {
    if (-not $actualPaths[$i].Equals($expectedPaths[$i], $comparison)) {
      throw "Python import path escaped the exact installation policy: $($actualPaths[$i])"
    }
  }
}

function Assert-StackchanPythonImportIsolation {
  param(
    [Parameter(Mandatory = $true)][string]$PythonHome,
    [Parameter(Mandatory = $true)][string]$PythonExecutable
  )

  $requiredEnvironment = [ordered]@{
    PYTHONNOUSERSITE = '1'
    PYTHONSAFEPATH = '1'
    PYTHONDONTWRITEBYTECODE = '1'
    PYTHONHASHSEED = '0'
    PYTHONUTF8 = '1'
    PYTHONIOENCODING = 'utf-8'
  }
  foreach ($entry in $requiredEnvironment.GetEnumerator()) {
    if ([Environment]::GetEnvironmentVariable(
        [string]$entry.Key, [EnvironmentVariableTarget]::Process) -cne [string]$entry.Value) {
      throw "Release Python isolation requires $($entry.Key)=$($entry.Value)."
    }
  }
  $forbiddenEnvironment = @(
    '__PYVENV_LAUNCHER__', '_PYTHON_HOST_PLATFORM',
    'CONDA_DEFAULT_ENV', 'CONDA_PREFIX', 'VIRTUAL_ENV',
    'PYTHONBREAKPOINT', 'PYTHONCASEOK', 'PYTHONCOERCECLOCALE', 'PYTHONDEBUG',
    'PYTHONEXECUTABLE', 'PYTHONFAULTHANDLER', 'PYTHONHOME', 'PYTHONINSPECT',
    'PYTHONINTMAXSTRDIGITS', 'PYTHONMALLOC', 'PYTHONNODEBUGRANGES', 'PYTHONPATH',
    'PYTHONOPTIMIZE', 'PYTHONPERFSUPPORT', 'PYTHONPLATLIBDIR', 'PYTHONPROFILEIMPORTTIME',
    'PYTHONPYCACHEPREFIX', 'PYTHONSTARTUP', 'PYTHONTRACEMALLOC', 'PYTHONUSERBASE',
    'PYTHONWARNDEFAULTENCODING', 'PYTHONWARNINGS'
  )
  foreach ($name in $forbiddenEnvironment) {
    if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable(
        $name, [EnvironmentVariableTarget]::Process))) {
      throw "Release Python isolation refuses ambient import/runtime override: $name"
    }
  }
  $pythonRoot = (Get-Item -LiteralPath $PythonHome -Force -ErrorAction Stop).FullName
  $escapeFiles = @(Get-ChildItem -LiteralPath $pythonRoot -Recurse -File -Force -ErrorAction Stop | Where-Object {
    $_.Extension -ieq '.pth' -or $_.Extension -ieq '.egg-link' -or
    $_.Name -ieq 'sitecustomize.py' -or $_.Name -ieq 'usercustomize.py'
  })
  if ($escapeFiles.Count -ne 0) {
    throw "Release Python installation contains import-path/customization escape files: $($escapeFiles.FullName -join ', ')"
  }
  $probeCode = @'
import json, site, sys
print(json.dumps({
    'executable': sys.executable,
    'prefix': sys.prefix,
    'base_prefix': sys.base_prefix,
    'path': sys.path,
    'enable_user_site': site.ENABLE_USER_SITE,
    'flags': {
        'no_user_site': sys.flags.no_user_site,
        'safe_path': sys.flags.safe_path,
        'dont_write_bytecode': sys.flags.dont_write_bytecode,
        'optimize': sys.flags.optimize,
    },
}, sort_keys=True))
'@
  $previousPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $output = @(& $PythonExecutable '-c' $probeCode 2>&1)
    $exitCode = $LASTEXITCODE
  } catch {
    throw "Release Python isolation probe failed to launch: $($_.Exception.Message)"
  } finally {
    $ErrorActionPreference = $previousPreference
  }
  if ($exitCode -ne 0) {
    throw "Release Python isolation probe failed (exit $exitCode): $($output -join "`n")"
  }
  try {
    $probe = ($output -join "`n").Trim() | ConvertFrom-Json
  } catch {
    throw "Release Python isolation probe did not return one JSON document: $($output -join "`n")"
  }
  Assert-StackchanPythonImportIsolationState `
    -Probe $probe -PythonHome $pythonRoot -PythonExecutable $PythonExecutable
}

function Get-StackchanFileSha256 {
  param([Parameter(Mandatory = $true)][string]$LiteralPath)

  $stream = [System.IO.FileStream]::new(
    $LiteralPath,
    [System.IO.FileMode]::Open,
    [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::Read,
    1MB,
    [System.IO.FileOptions]::SequentialScan)
  $hasher = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([System.BitConverter]::ToString($hasher.ComputeHash($stream)) -replace '-', '').ToUpperInvariant()
  } finally {
    $hasher.Dispose()
    $stream.Dispose()
  }
}

function ConvertTo-StackchanSafeIdentityRelativePath {
  param([Parameter(Mandatory = $true)][string]$RelativePath)

  if ([string]::IsNullOrWhiteSpace($RelativePath) -or
      $RelativePath -match '[\x00-\x1F\x7F]' -or
      $RelativePath -match '(^|[\\/])\.\.($|[\\/])' -or
      $RelativePath -match ':') {
    throw "Unsafe toolchain identity relative path: $RelativePath"
  }
  if ([System.IO.Path]::IsPathRooted($RelativePath)) {
    throw "Unsafe toolchain identity relative path: $RelativePath"
  }
  $canonical = ($RelativePath -replace '\\', '/').Trim('/')
  if ([string]::IsNullOrWhiteSpace($canonical) -or
      $canonical -match '(^|/)\.($|/)' -or
      -not $canonical.IsNormalized([Text.NormalizationForm]::FormC)) {
    throw "Non-canonical toolchain identity relative path: $RelativePath"
  }
  return $canonical
}

function Get-StackchanIdentityFromRecords {
  param(
    [Parameter(Mandatory = $true)][object[]]$Records,
    [string]$Schema = $script:StackchanToolchainInventorySchema,
    [switch]$IncludeRecords
  )

  $recordMap = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
  foreach ($record in $Records) {
    $key = ConvertTo-StackchanSafeIdentityRelativePath ([string]$record.relativePath)
    if ($recordMap.ContainsKey($key) -or
        [string]$record.sha256 -notmatch '^[0-9A-F]{64}$' -or
        [long]$record.bytes -lt 0) {
      throw "Invalid or duplicate canonical identity record: $key"
    }
    $recordMap.Add($key, [pscustomobject][ordered]@{
      relativePath = $key
      bytes = [long]$record.bytes
      sha256 = [string]$record.sha256
    })
  }
  $recordKeys = [string[]]@($recordMap.Keys)
  [Array]::Sort($recordKeys, [StringComparer]::Ordinal)
  $orderedRecords = [System.Collections.Generic.List[object]]::new()
  $inventoryText = [System.Text.StringBuilder]::new()
  [void]$inventoryText.Append($Schema).Append("`n")
  foreach ($key in $recordKeys) {
    $record = $recordMap[$key]
    $orderedRecords.Add($record) | Out-Null
    [void]$inventoryText.Append('F').Append("`0").Append($key).Append("`0").
      Append([string]$record.bytes).Append("`0").Append([string]$record.sha256).Append("`n")
  }
  $bytes = [Text.Encoding]::UTF8.GetBytes($inventoryText.ToString())
  $hasher = [System.Security.Cryptography.SHA256]::Create()
  try {
    $treeSha256 = ([BitConverter]::ToString($hasher.ComputeHash($bytes)) -replace '-', '').ToUpperInvariant()
  } finally {
    $hasher.Dispose()
  }
  $result = [pscustomobject][ordered]@{
    schema = $Schema
    treeSha256 = $treeSha256
    fileCount = $orderedRecords.Count
    bytes = [long](($orderedRecords | Measure-Object -Property bytes -Sum).Sum)
  }
  if ($IncludeRecords) {
    $result | Add-Member -NotePropertyName records -NotePropertyValue @($orderedRecords)
  }
  return $result
}

function Get-StackchanToolchainTreeIdentity {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [switch]$IncludeRecords
  )

  if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    throw "Toolchain identity root is missing: $Root"
  }
  $resolvedRootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
  if ($resolvedRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw "Toolchain identity refuses a reparse-point root: $Root"
  }
  $resolvedRoot = $resolvedRootItem.FullName.TrimEnd('\', '/')
  $queue = [System.Collections.Generic.Queue[object]]::new()
  $queue.Enqueue([pscustomobject]@{ Item = $resolvedRootItem; Relative = '' })
  $records = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)

  while ($queue.Count -gt 0) {
    $current = $queue.Dequeue()
    $children = @(Get-ChildItem -LiteralPath $current.Item.FullName -Force -ErrorAction Stop)
    $childMap = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($child in $children) {
      if ($childMap.ContainsKey([string]$child.Name)) {
        throw "Duplicate toolchain identity entry under $($current.Item.FullName): $($child.Name)"
      }
      $childMap.Add([string]$child.Name, $child)
    }
    $childNames = [string[]]@($childMap.Keys)
    [Array]::Sort($childNames, [StringComparer]::Ordinal)
    $caseNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $childNames) {
      if (-not $caseNames.Add($name)) {
        throw "Case-ambiguous toolchain identity entries under $($current.Item.FullName): $name"
      }
      if ([string]::IsNullOrWhiteSpace($name) -or $name -match '[\x00-\x1F\x7F/\\]' -or
          -not $name.IsNormalized([Text.NormalizationForm]::FormC)) {
        throw "Unsafe toolchain identity entry under $($current.Item.FullName): $name"
      }
      $item = $childMap[$name]
      $relative = if ([string]::IsNullOrEmpty([string]$current.Relative)) {
        $name
      } else {
        [string]$current.Relative + '/' + $name
      }
      $relative = ConvertTo-StackchanSafeIdentityRelativePath $relative
      if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Toolchain identity refuses reparse points: $($item.FullName)"
      }
      if ($item.PSIsContainer) {
        $queue.Enqueue([pscustomobject]@{ Item = $item; Relative = $relative })
      } elseif ($item -is [System.IO.FileInfo]) {
        $lengthBefore = [long]$item.Length
        $sha256 = Get-StackchanFileSha256 -LiteralPath $item.FullName
        $lengthAfter = [long](Get-Item -LiteralPath $item.FullName -Force -ErrorAction Stop).Length
        if ($lengthBefore -ne $lengthAfter) {
          throw "Toolchain input changed while it was hashed: $($item.FullName)"
        }
        if ($records.ContainsKey($relative)) {
          throw "Duplicate toolchain identity path: $relative"
        }
        $records.Add($relative, [pscustomobject][ordered]@{
          relativePath = $relative
          bytes = $lengthAfter
          sha256 = $sha256
        })
      } else {
        throw "Unsupported toolchain identity filesystem entry: $($item.FullName)"
      }
    }
  }

  return Get-StackchanIdentityFromRecords -Records @($records.Values) `
    -Schema $script:StackchanToolchainInventorySchema -IncludeRecords:$IncludeRecords
}

function New-StackchanCanonicalIdentityRecord {
  param(
    [Parameter(Mandatory = $true)][string]$RelativePath,
    [Parameter(Mandatory = $true)][string]$CanonicalText
  )
  $bytes = [Text.Encoding]::UTF8.GetBytes($CanonicalText)
  $hasher = [Security.Cryptography.SHA256]::Create()
  try {
    $sha256 = ([BitConverter]::ToString($hasher.ComputeHash($bytes)) -replace '-', '').ToUpperInvariant()
  } finally {
    $hasher.Dispose()
  }
  return [pscustomobject][ordered]@{
    relativePath = ConvertTo-StackchanSafeIdentityRelativePath $RelativePath
    bytes = [long]$bytes.Length
    sha256 = $sha256
  }
}

function Get-StackchanUInt32BigEndian {
  param([byte[]]$Bytes, [int]$Offset)
  if ($Offset -lt 0 -or $Offset + 4 -gt $Bytes.Length) { throw 'Truncated big-endian uint32.' }
  return [uint32]((([uint32]$Bytes[$Offset]) -shl 24) -bor
    (([uint32]$Bytes[$Offset + 1]) -shl 16) -bor
    (([uint32]$Bytes[$Offset + 2]) -shl 8) -bor
    ([uint32]$Bytes[$Offset + 3]))
}

function Get-StackchanUInt16BigEndian {
  param([byte[]]$Bytes, [int]$Offset)
  if ($Offset -lt 0 -or $Offset + 2 -gt $Bytes.Length) { throw 'Truncated big-endian uint16.' }
  return [uint16]((([uint16]$Bytes[$Offset]) -shl 8) -bor ([uint16]$Bytes[$Offset + 1]))
}

function Get-StackchanSha1Hex {
  param([Parameter(Mandatory = $true)][byte[]]$Bytes)
  $hasher = [Security.Cryptography.SHA1]::Create()
  try {
    return ([BitConverter]::ToString($hasher.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant()
  } finally {
    $hasher.Dispose()
  }
}

function ConvertTo-StackchanLowerHex {
  param([Parameter(Mandatory = $true)][byte[]]$Bytes)
  return ([BitConverter]::ToString($Bytes) -replace '-', '').ToLowerInvariant()
}

function Get-StackchanCanonicalGitIndexText {
  param([Parameter(Mandatory = $true)][string]$IndexPath)

  [byte[]]$bytes = [IO.File]::ReadAllBytes($IndexPath)
  if ($bytes.Length -lt 32 -or [Text.Encoding]::ASCII.GetString($bytes, 0, 4) -cne 'DIRC') {
    throw "Invalid Git index header: $IndexPath"
  }
  $payloadLength = $bytes.Length - 20
  $expectedChecksum = ConvertTo-StackchanLowerHex ([byte[]]$bytes[$payloadLength..($bytes.Length - 1)])
  $actualChecksum = Get-StackchanSha1Hex ([byte[]]$bytes[0..($payloadLength - 1)])
  if ($actualChecksum -cne $expectedChecksum) { throw "Git index checksum mismatch: $IndexPath" }
  $version = Get-StackchanUInt32BigEndian $bytes 4
  if ($version -ne 2) { throw "Unsupported Git index version $version`: $IndexPath" }
  $entryCount = [int](Get-StackchanUInt32BigEndian $bytes 8)
  $offset = 12
  $builder = [Text.StringBuilder]::new()
  [void]$builder.Append("git-index-v2`n")
  $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $utf8 = [Text.UTF8Encoding]::new($false, $true)
  for ($entry = 0; $entry -lt $entryCount; $entry++) {
    $entryStart = $offset
    if ($entryStart + 63 -gt $payloadLength) { throw "Truncated Git index entry: $IndexPath" }
    $mode = Get-StackchanUInt32BigEndian $bytes ($entryStart + 24)
    $objectId = ConvertTo-StackchanLowerHex ([byte[]]$bytes[($entryStart + 40)..($entryStart + 59)])
    $flags = Get-StackchanUInt16BigEndian $bytes ($entryStart + 60)
    if (($flags -band 0x4000) -ne 0) { throw "Extended Git index entries are not supported: $IndexPath" }
    $nul = $entryStart + 62
    while ($nul -lt $payloadLength -and $bytes[$nul] -ne 0) { $nul++ }
    if ($nul -ge $payloadLength) { throw "Unterminated Git index path: $IndexPath" }
    $pathLength = $nul - ($entryStart + 62)
    $path = $utf8.GetString($bytes, $entryStart + 62, $pathLength)
    $path = ConvertTo-StackchanSafeIdentityRelativePath $path
    if (-not $paths.Add($path)) { throw "Duplicate Git index path: $path" }
    $encodedLength = $flags -band 0x0FFF
    if ($encodedLength -ne [Math]::Min($pathLength, 0x0FFF)) {
      throw "Git index path length mismatch: $path"
    }
    [void]$builder.Append($mode.ToString('X8')).Append(' ').Append($objectId).
      Append(' ').Append(($flags -band 0xF000).ToString('X4')).Append(' ').Append($path).Append("`n")
    $entryBytes = 62 + $pathLength + 1
    $offset = $entryStart + (($entryBytes + 7) -band (-bnot 7))
  }
  if ($offset -gt $payloadLength) { throw "Git index entry padding escaped file: $IndexPath" }
  if ($offset -lt $payloadLength) {
    $extensionBytes = [byte[]]$bytes[$offset..($payloadLength - 1)]
    [void]$builder.Append('extensions ').Append($extensionBytes.Length).Append(' ').
      Append((Get-StackchanSha1Hex $extensionBytes)).Append("`n")
  }
  return $builder.ToString()
}

function Get-StackchanCanonicalReflogText {
  param([Parameter(Mandatory = $true)][string]$LogPath)
  $raw = [IO.File]::ReadAllText($LogPath)
  $builder = [Text.StringBuilder]::new()
  foreach ($line in @($raw -split "`r?`n" | Where-Object { $_ -ne '' })) {
    if ($line -notmatch '^(?<old>[0-9a-f]{40}) (?<new>[0-9a-f]{40}) (?<actor>[^\r\n]+ <[^>\r\n]+>) (?<epoch>[0-9]{1,20}) (?<zone>[+-][0-9]{4})\t(?<message>[^\r\n]*)$') {
      throw "Unsafe or malformed Git reflog entry: $LogPath"
    }
    [void]$builder.Append($Matches.old).Append(' ').Append($Matches.new).
      Append("`t").Append($Matches.message).Append("`n")
  }
  return $builder.ToString()
}

function Get-StackchanCanonicalGitPackText {
  param([Parameter(Mandatory = $true)][string]$PackRoot)

  $items = @(Get-ChildItem -LiteralPath $PackRoot -File -Force -ErrorAction Stop)
  if ($items.Count -eq 0) { throw "Git object pack directory is empty: $PackRoot" }
  $groups = @($items | Group-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) })
  $objectIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($group in $groups) {
    if ($group.Name -notmatch '^pack-[0-9a-f]{40}$') { throw "Unsafe Git pack name: $($group.Name)" }
    $extensions = @($group.Group | ForEach-Object { $_.Extension.ToLowerInvariant() } | Sort-Object)
    if (($extensions -join ',') -cne '.idx,.pack,.rev') {
      throw "Git pack must contain exactly idx/pack/rev: $($group.Name)"
    }
    $idxPath = ($group.Group | Where-Object Extension -eq '.idx').FullName
    $packPath = ($group.Group | Where-Object Extension -eq '.pack').FullName
    $revPath = ($group.Group | Where-Object Extension -eq '.rev').FullName
    [byte[]]$idx = [IO.File]::ReadAllBytes($idxPath)
    if ($idx.Length -lt 1104 -or (ConvertTo-StackchanLowerHex ([byte[]]$idx[0..3])) -cne 'ff744f63' -or
        (Get-StackchanUInt32BigEndian $idx 4) -ne 2) {
      throw "Unsupported Git pack index: $idxPath"
    }
    $idxPayloadLength = $idx.Length - 20
    if ((Get-StackchanSha1Hex ([byte[]]$idx[0..($idxPayloadLength - 1)])) -cne
        (ConvertTo-StackchanLowerHex ([byte[]]$idx[$idxPayloadLength..($idx.Length - 1)]))) {
      throw "Git pack index checksum mismatch: $idxPath"
    }
    $count = [int](Get-StackchanUInt32BigEndian $idx (8 + 255 * 4))
    $objectOffset = 8 + 256 * 4
    if ($objectOffset + $count * 20 + 40 -gt $idx.Length) { throw "Truncated Git pack index: $idxPath" }
    for ($i = 0; $i -lt $count; $i++) {
      $start = $objectOffset + $i * 20
      $id = ConvertTo-StackchanLowerHex ([byte[]]$idx[$start..($start + 19)])
      if (-not $objectIds.Add($id)) { throw "Duplicate Git object identity across packs: $id" }
    }
    $idxPackChecksum = ConvertTo-StackchanLowerHex ([byte[]]$idx[($idx.Length - 40)..($idx.Length - 21)])
    [byte[]]$pack = [IO.File]::ReadAllBytes($packPath)
    if ($pack.Length -lt 32 -or [Text.Encoding]::ASCII.GetString($pack, 0, 4) -cne 'PACK') {
      throw "Invalid Git pack: $packPath"
    }
    $packChecksum = ConvertTo-StackchanLowerHex ([byte[]]$pack[($pack.Length - 20)..($pack.Length - 1)])
    if ((Get-StackchanSha1Hex ([byte[]]$pack[0..($pack.Length - 21)])) -cne $packChecksum -or
        $idxPackChecksum -cne $packChecksum -or $group.Name -cne "pack-$packChecksum") {
      throw "Git pack content identity mismatch: $packPath"
    }
    [byte[]]$rev = [IO.File]::ReadAllBytes($revPath)
    $expectedRevLength = 12 + 4 * $count + 40
    if ($rev.Length -ne $expectedRevLength -or
        [Text.Encoding]::ASCII.GetString($rev, 0, 4) -cne 'RIDX' -or
        (Get-StackchanUInt32BigEndian $rev 4) -ne 1 -or
        (Get-StackchanUInt32BigEndian $rev 8) -ne 1) {
      throw "Invalid Git reverse index: $revPath"
    }
    $seenPositions = [Collections.Generic.HashSet[uint32]]::new()
    for ($i = 0; $i -lt $count; $i++) {
      $position = Get-StackchanUInt32BigEndian $rev (12 + 4 * $i)
      if ($position -ge $count -or -not $seenPositions.Add($position)) {
        throw "Invalid Git reverse-index permutation: $revPath"
      }
    }
    $revPackOffset = 12 + 4 * $count
    $revPackChecksum = ConvertTo-StackchanLowerHex ([byte[]]$rev[$revPackOffset..($revPackOffset + 19)])
    $revChecksum = ConvertTo-StackchanLowerHex ([byte[]]$rev[($rev.Length - 20)..($rev.Length - 1)])
    if ($revPackChecksum -cne $packChecksum -or
        (Get-StackchanSha1Hex ([byte[]]$rev[0..($rev.Length - 21)])) -cne $revChecksum) {
      throw "Git reverse-index checksum mismatch: $revPath"
    }
  }
  $orderedIds = [string[]]@($objectIds)
  [Array]::Sort($orderedIds, [StringComparer]::Ordinal)
  return "git-object-id-set-v1`n" + (($orderedIds | ForEach-Object { "$_`n" }) -join '')
}

function Get-StackchanCanonicalGitLibraryRecords {
  param(
    [Parameter(Mandatory = $true)][string]$LibraryRoot,
    [Parameter(Mandatory = $true)][string]$LibraryLeaf,
    [Parameter(Mandatory = $true)][string]$ExpectedPackageName,
    [Parameter(Mandatory = $true)][string]$ExpectedSourceUri,
    [Parameter(Mandatory = $true)][string]$ExpectedCommit
  )

  if ($ExpectedPackageName -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or
      $ExpectedSourceUri -notmatch '^git\+https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git(?:#[0-9a-f]{7,40})?$' -or
      $ExpectedCommit -notmatch '^[0-9a-f]{40}$') {
    throw "Invalid reviewed Git dependency policy: $LibraryLeaf"
  }

  $gitRoot = Join-Path $LibraryRoot '.git'
  $gitIdentity = Get-StackchanToolchainTreeIdentity -Root $gitRoot -IncludeRecords
  $recordMap = @{}
  foreach ($record in $gitIdentity.records) { $recordMap[[string]$record.relativePath] = $record }
  foreach ($dangerous in @('objects/info/alternates', 'info/grafts')) {
    if ($recordMap.ContainsKey($dangerous)) { throw "Dangerous Git metadata is forbidden: $LibraryLeaf/.git/$dangerous" }
  }
  foreach ($relative in $recordMap.Keys) {
    if ($relative -match '^refs/replace/' -or
        ($relative -match '^hooks/' -and $relative -notmatch '\.sample$') -or
        ($relative -match '^objects/' -and $relative -notmatch '^objects/pack/')) {
      throw "Unexpected executable or object Git state: $LibraryLeaf/.git/$relative"
    }
  }
  $configPath = Join-Path $gitRoot 'config'
  $configText = [IO.File]::ReadAllText($configPath)
  if ($configText -match '(?im)^\s*\[(include|includeIf)\b' -or
      $configText -match '(?im)^\s*(hooksPath|fsmonitor|sshCommand|worktree)\s*=') {
    throw "Dangerous Git config is forbidden: $LibraryLeaf/.git/config"
  }
  if ($configText -notmatch ('(?m)^\s*url\s*=\s*' +
      [regex]::Escape($ExpectedSourceUri.Substring(4).Split('#')[0]) + '\s*$')) {
    throw "Git remote source does not match reviewed policy: $LibraryLeaf/.git/config"
  }
  $headText = [IO.File]::ReadAllText((Join-Path $gitRoot 'HEAD')).Trim()
  if ($headText -notmatch '^ref: (?<ref>refs/heads/[A-Za-z0-9._/-]+)$') {
    throw "Git dependency must have a symbolic branch HEAD: $LibraryLeaf"
  }
  $headRef = $Matches.ref
  $headRefPath = Join-Path $gitRoot ($headRef -replace '/', [IO.Path]::DirectorySeparatorChar)
  if (-not (Test-Path -LiteralPath $headRefPath -PathType Leaf)) {
    throw "Git dependency HEAD ref is missing: $LibraryLeaf/$headRef"
  }
  $headCommit = [IO.File]::ReadAllText($headRefPath).Trim().ToLowerInvariant()
  if ($headCommit -cne $ExpectedCommit) { throw "Git dependency commit does not match reviewed policy: $LibraryLeaf" }

  $piopmPath = Join-Path $gitRoot '.piopm'
  $piopm = [IO.File]::ReadAllText($piopmPath) | ConvertFrom-Json
  $topProperties = @($piopm.PSObject.Properties.Name | Sort-Object)
  $specProperties = @($piopm.spec.PSObject.Properties.Name | Sort-Object)
  if (($topProperties -join ',') -cne 'name,spec,type,version' -or
      ($specProperties -join ',') -cne 'id,name,owner,requirements,uri' -or
      [string]$piopm.type -cne 'library' -or
      [string]$piopm.name -cne $ExpectedPackageName -or
      [string]$piopm.spec.name -cne [string]$piopm.name -or
      $null -ne $piopm.spec.id -or $null -ne $piopm.spec.owner -or
      $null -ne $piopm.spec.requirements -or
      [string]$piopm.spec.uri -cne $ExpectedSourceUri) {
    throw "Unsafe PlatformIO Git package metadata: $LibraryLeaf/.git/.piopm"
  }
  $dynamicLibraryVersion = $null
  if ([string]$piopm.version -match '^(?<base>0\.0\.0\+(?<stamp>[0-9]{14}))\.sha\.(?<sha>[0-9a-f]{7,40})$') {
    $canonicalVersion = "0.0.0+INSTALL_TIMESTAMP.sha.$($Matches.sha)"
    $dynamicLibraryVersion = $Matches.base
    $commitPrefix = $Matches.sha
  } elseif ([string]$piopm.version -match '^(?<base>[0-9]+\.[0-9]+\.[0-9]+)\+sha\.(?<sha>[0-9a-f]{7,40})$') {
    $canonicalVersion = "$($Matches.base)+sha.$($Matches.sha)"
    $commitPrefix = $Matches.sha
  } else {
    throw "Unsupported PlatformIO Git package version: $LibraryLeaf/$($piopm.version)"
  }
  if (-not $headCommit.StartsWith($commitPrefix, [StringComparison]::Ordinal)) {
    throw "PlatformIO Git metadata commit does not match HEAD: $LibraryLeaf"
  }
  if ([string]$piopm.spec.uri -match '#(?<uriCommit>[0-9a-f]{7,40})$' -and
      -not $headCommit.StartsWith($Matches.uriCommit, [StringComparison]::Ordinal)) {
    throw "PlatformIO Git source URI commit does not match HEAD: $LibraryLeaf"
  }
  $piopmCanonical = @(
    'platformio-git-package-v1',
    "name=$([string]$piopm.name)",
    "version=$canonicalVersion",
    "uri=$([string]$piopm.spec.uri)",
    "headRef=$headRef",
    "headCommit=$headCommit"
  ) -join "`n"
  $piopmCanonical += "`n"

  $canonicalRecords = [Collections.Generic.List[object]]::new()
  $packHandled = $false
  foreach ($relative in @($recordMap.Keys | Sort-Object)) {
    $record = $recordMap[$relative]
    $canonicalPath = "$LibraryLeaf/.git/$relative"
    if ($relative -ceq '.piopm') {
      $canonicalRecords.Add((New-StackchanCanonicalIdentityRecord `
        -RelativePath $canonicalPath -CanonicalText $piopmCanonical)) | Out-Null
    } elseif ($relative -ceq 'index') {
      $canonicalRecords.Add((New-StackchanCanonicalIdentityRecord -RelativePath $canonicalPath `
        -CanonicalText (Get-StackchanCanonicalGitIndexText (Join-Path $gitRoot 'index')))) | Out-Null
    } elseif ($relative -match '^logs/') {
      $canonicalRecords.Add((New-StackchanCanonicalIdentityRecord -RelativePath $canonicalPath `
        -CanonicalText (Get-StackchanCanonicalReflogText (Join-Path $gitRoot ($relative -replace '/', '\'))))) | Out-Null
    } elseif ($relative -match '^objects/pack/') {
      if (-not $packHandled) {
        $canonicalRecords.Add((New-StackchanCanonicalIdentityRecord `
          -RelativePath "$LibraryLeaf/.git/objects/pack/@object-set" `
          -CanonicalText (Get-StackchanCanonicalGitPackText (Join-Path $gitRoot 'objects/pack')))) | Out-Null
        $packHandled = $true
      }
    } else {
      $canonicalRecords.Add([pscustomobject][ordered]@{
        relativePath = $canonicalPath
        bytes = [long]$record.bytes
        sha256 = [string]$record.sha256
      }) | Out-Null
    }
  }
  if (-not $packHandled) { throw "Git dependency has no verified object pack: $LibraryLeaf" }
  return [pscustomobject][ordered]@{
    records = @($canonicalRecords)
    dynamicLibraryVersion = $dynamicLibraryVersion
    packageName = [string]$piopm.name
    headCommit = $headCommit
  }
}

function Get-StackchanCanonicalGitLibraryTreeIdentity {
  param(
    [Parameter(Mandatory = $true)][string]$LibraryRoot,
    [Parameter(Mandatory = $true)][string]$LibraryLeaf,
    [Parameter(Mandatory = $true)][string]$ExpectedPackageName,
    [Parameter(Mandatory = $true)][string]$ExpectedSourceUri,
    [Parameter(Mandatory = $true)][string]$ExpectedCommit,
    [switch]$IncludeRecords
  )

  # Git metadata has a narrow canonical form, but the checked-out working tree
  # remains an exact byte inventory. In particular, source and build scripts
  # are never inferred from Git object IDs or omitted as "generated" inputs.
  $rawTree = Get-StackchanToolchainTreeIdentity -Root $LibraryRoot -IncludeRecords
  $gitIdentity = Get-StackchanCanonicalGitLibraryRecords `
    -LibraryRoot $LibraryRoot -LibraryLeaf $LibraryLeaf `
    -ExpectedPackageName $ExpectedPackageName `
    -ExpectedSourceUri $ExpectedSourceUri `
    -ExpectedCommit $ExpectedCommit
  $canonicalRecords = [Collections.Generic.List[object]]::new()
  foreach ($record in $gitIdentity.records) { $canonicalRecords.Add($record) | Out-Null }
  foreach ($record in $rawTree.records) {
    $relative = [string]$record.relativePath
    if ($relative.StartsWith('.git/', [StringComparison]::Ordinal)) { continue }
    if ($relative -ceq 'library.json' -and
        -not [string]::IsNullOrWhiteSpace([string]$gitIdentity.dynamicLibraryVersion)) {
      $metadata = [IO.File]::ReadAllText((Join-Path $LibraryRoot 'library.json')) | ConvertFrom-Json
      $properties = @($metadata.PSObject.Properties.Name | Sort-Object)
      if (($properties -join ',') -cne 'name,version' -or
          [string]$metadata.name -cne [string]$gitIdentity.packageName -or
          [string]$metadata.version -cne [string]$gitIdentity.dynamicLibraryVersion) {
        throw "Dynamic PlatformIO library metadata does not match Git source identity: $LibraryLeaf/library.json"
      }
      $canonicalRecords.Add((New-StackchanCanonicalIdentityRecord `
        -RelativePath "$LibraryLeaf/library.json" `
        -CanonicalText "platformio-generated-library-v1`nname=$([string]$metadata.name)`nversion=0.0.0+INSTALL_TIMESTAMP`n")) | Out-Null
    } else {
      $canonicalRecords.Add([pscustomobject][ordered]@{
        relativePath = "$LibraryLeaf/$relative"
        bytes = [long]$record.bytes
        sha256 = [string]$record.sha256
      }) | Out-Null
    }
  }
  $identity = Get-StackchanIdentityFromRecords -Records @($canonicalRecords) `
    -Schema $script:StackchanCanonicalGitLibrarySchema -IncludeRecords:$IncludeRecords
  $identity | Add-Member -NotePropertyName rawFileCount -NotePropertyValue ([int]$rawTree.fileCount)
  $identity | Add-Member -NotePropertyName rawBytes -NotePropertyValue ([long]$rawTree.bytes)
  $identity | Add-Member -NotePropertyName headCommit -NotePropertyValue ([string]$gitIdentity.headCommit)
  return $identity
}

function Get-StackchanExpectedLibdepsPolicy {
  param([Parameter(Mandatory = $true)][string]$Environment)

  $legacyRequirements = @(
    'M5GFX@0.2.24',
    'M5Stack/M5Unified@0.2.17',
    'https://github.com/mongonta0716/SCServo.git#ee6ee4a',
    'arminjo/ServoEasing@3.1.0',
    'https://github.com/stack-chan/stackchan-arduino.git#b7b98f5',
    'bblanchon/ArduinoJson@7.4.3',
    'tobozo/YAMLDuino@1.5.0',
    'robotis-git/Dynamixel2Arduino@0.7.0',
    'madhephaestus/ESP32Servo@0.13.0'
  )
  if ($Environment -in @('stackchan', 'stackchan_servo_calibration')) {
    return [pscustomobject][ordered]@{
      leaves = @(
        'ArduinoJson', 'Dynamixel2Arduino', 'ESP32Servo', 'M5GFX', 'M5Unified',
        'M5Unified@0.2.17', 'SCServo',
        'SCServo@src-8a1b26565e1a43aa7e250db85a311724', 'ServoEasing',
        'stackchan-arduino', 'YAMLDuino'
      )
      requirements = $legacyRequirements
      gitSources = @{
        'SCServo' = [pscustomobject]@{
          packageName = 'SCServo'
          uri = 'git+https://github.com/mongonta0716/SCServo.git#ee6ee4a'
          commit = 'ee6ee4a014ed7068025637bf6a1da66c7b4153c3'
        }
        'SCServo@src-8a1b26565e1a43aa7e250db85a311724' = [pscustomobject]@{
          packageName = 'SCServo'
          uri = 'git+https://github.com/mongonta0716/SCServo.git'
          commit = 'ee6ee4a014ed7068025637bf6a1da66c7b4153c3'
        }
        'stackchan-arduino' = [pscustomobject]@{
          packageName = 'stackchan-arduino'
          uri = 'git+https://github.com/stack-chan/stackchan-arduino.git#b7b98f5'
          commit = 'b7b98f5b19c6cae581782fc127f1fa1274b035a8'
        }
      }
    }
  }
  if ($Environment -ceq 'stackchan_release_full') {
    return [pscustomobject][ordered]@{
      leaves = @(
        'ArduinoJson', 'esp-micro-speech-features', 'M5GFX', 'M5GFX@0.2.24',
        'M5Unified', 'SCServo', 'YAMLDuino'
      )
      requirements = @(
        'bblanchon/ArduinoJson@7.4.3',
        'M5Stack/M5Unified@0.2.17',
        'tobozo/YAMLDuino@1.5.0',
        'M5GFX@0.2.24',
        'https://github.com/esphome-libs/esp-micro-speech-features.git#351c4c69530f5a802da5433581c4863afadf0a00',
        'https://github.com/mongonta0716/SCServo.git#ee6ee4a'
      )
      gitSources = @{
        'esp-micro-speech-features' = [pscustomobject]@{
          packageName = 'esp-micro-speech-features'
          uri = 'git+https://github.com/esphome-libs/esp-micro-speech-features.git#351c4c69530f5a802da5433581c4863afadf0a00'
          commit = '351c4c69530f5a802da5433581c4863afadf0a00'
        }
        'SCServo' = [pscustomobject]@{
          packageName = 'SCServo'
          uri = 'git+https://github.com/mongonta0716/SCServo.git#ee6ee4a'
          commit = 'ee6ee4a014ed7068025637bf6a1da66c7b4153c3'
        }
      }
    }
  }
  throw "No exact fresh-libdeps policy exists for environment: $Environment"
}

function Get-StackchanCanonicalLibdepsIdentity {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Environment,
    [switch]$IncludeRecords
  )

  $policy = Get-StackchanExpectedLibdepsPolicy -Environment $Environment
  $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
  if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "Canonical libdeps root is not a real directory: $Root"
  }
  $topItems = @(Get-ChildItem -LiteralPath $rootItem.FullName -Force -ErrorAction Stop)
  $topFiles = @($topItems | Where-Object { -not $_.PSIsContainer })
  $topLeaves = [string[]]@($topItems | Where-Object PSIsContainer | ForEach-Object Name)
  [Array]::Sort($topLeaves, [StringComparer]::Ordinal)
  $expectedLeaves = [string[]]@($policy.leaves)
  [Array]::Sort($expectedLeaves, [StringComparer]::Ordinal)
  if ($topFiles.Count -ne 1 -or $topFiles[0].Name -cne 'integrity.dat' -or
      ($topLeaves -join "`n") -cne ($expectedLeaves -join "`n")) {
    throw "Libdeps tree is stale or has unexpected packages/files: $Environment"
  }
  $integrityLines = @([IO.File]::ReadAllLines($topFiles[0].FullName) | ForEach-Object { $_.Trim() })
  if ($integrityLines.Count -ne @($policy.requirements).Count -or
      @($integrityLines | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -match '[\x00-\x1F\x7F]' }).Count -ne 0 -or
      @($integrityLines | Sort-Object -Unique).Count -ne $integrityLines.Count) {
    throw "Libdeps integrity inventory is malformed or duplicated: $Environment"
  }
  $actualRequirements = [string[]]$integrityLines
  $expectedRequirements = [string[]]@($policy.requirements)
  [Array]::Sort($actualRequirements, [StringComparer]::Ordinal)
  [Array]::Sort($expectedRequirements, [StringComparer]::Ordinal)
  if (($actualRequirements -join "`n") -cne ($expectedRequirements -join "`n")) {
    throw "Libdeps integrity requirements do not match exact policy: $Environment"
  }

  $canonicalRecords = [Collections.Generic.List[object]]::new()
  $canonicalRecords.Add((New-StackchanCanonicalIdentityRecord -RelativePath 'integrity.dat' `
    -CanonicalText ("platformio-integrity-set-v1`n" + (($actualRequirements | ForEach-Object { "$_`n" }) -join '')))) | Out-Null
  $rawFileCount = 1
  $rawBytes = [long]$topFiles[0].Length
  foreach ($leaf in $topLeaves) {
    $libraryRoot = Join-Path $rootItem.FullName $leaf
    $hasGit = Test-Path -LiteralPath (Join-Path $libraryRoot '.git') -PathType Container
    if ($hasGit) {
      if (-not $policy.gitSources.ContainsKey($leaf)) {
        throw "Unreviewed Git dependency appeared in libdeps: $Environment/$leaf"
      }
      $sourcePolicy = $policy.gitSources[$leaf]
      $libraryTree = Get-StackchanCanonicalGitLibraryTreeIdentity `
        -LibraryRoot $libraryRoot -LibraryLeaf $leaf `
        -ExpectedPackageName ([string]$sourcePolicy.packageName) `
        -ExpectedSourceUri ([string]$sourcePolicy.uri) `
        -ExpectedCommit ([string]$sourcePolicy.commit) -IncludeRecords
      foreach ($record in $libraryTree.records) { $canonicalRecords.Add($record) | Out-Null }
    } else {
      if ($policy.gitSources.ContainsKey($leaf)) {
        throw "Reviewed Git dependency lost its Git source evidence: $Environment/$leaf"
      }
      $libraryTree = Get-StackchanToolchainTreeIdentity -Root $libraryRoot -IncludeRecords
      foreach ($record in $libraryTree.records) {
        $canonicalRecords.Add([pscustomobject][ordered]@{
          relativePath = "$leaf/$([string]$record.relativePath)"
          bytes = [long]$record.bytes
          sha256 = [string]$record.sha256
        }) | Out-Null
      }
    }
    if ($null -ne $libraryTree.PSObject.Properties['rawFileCount']) {
      $rawFileCount += [int]$libraryTree.rawFileCount
    } else {
      $rawFileCount += [int]$libraryTree.fileCount
    }
    $rawBytes += if ($null -ne $libraryTree.PSObject.Properties['rawBytes']) {
      [long]$libraryTree.rawBytes
    } else {
      [long]$libraryTree.bytes
    }
  }
  $identity = Get-StackchanIdentityFromRecords -Records @($canonicalRecords) `
    -Schema $script:StackchanCanonicalLibdepsSchema -IncludeRecords:$IncludeRecords
  $identity | Add-Member -NotePropertyName rawFileCount -NotePropertyValue $rawFileCount
  $identity | Add-Member -NotePropertyName rawBytes -NotePropertyValue $rawBytes
  return $identity
}

function Get-StackchanReleaseToolchainComponentPolicy {
  param([Parameter(Mandatory = $true)][string]$PlatformKey)

  if ($PlatformKey -cne 'windows_amd64') {
    throw "No reviewed release toolchain component policy exists for platform: $PlatformKey"
  }

  $components = [System.Collections.Generic.List[object]]::new()
  function Add-PolicyComponent {
    param(
      [string]$Name,
      [string]$Phase,
      [string]$RootKey,
      [string]$RelativePath
    )
    $components.Add([pscustomobject][ordered]@{
      name = $Name
      phase = $Phase
      rootKey = $RootKey
      relativePath = $RelativePath
    }) | Out-Null
  }

  # Hash the entire Python installation as one closed root, including
  # python312.zip, DLLs, Lib, site-packages, and every Scripts launcher.
  Add-PolicyComponent 'python-installation' 'preBuild' 'pythonHome' '@root'

  Add-PolicyComponent 'legacy-core-penv' 'preBuild' 'legacyCore' 'penv'
  Add-PolicyComponent 'legacy-platform-espressif32-7.0.1' 'preBuild' 'legacyCore' 'platforms/espressif32@7.0.1'
  foreach ($package in @(
      'framework-arduinoespressif32', 'toolchain-riscv32-esp',
      'toolchain-xtensa-esp32s3', 'tool-esptoolpy', 'tool-mkfatfs',
      'tool-mklittlefs', 'tool-mkspiffs')) {
    Add-PolicyComponent "legacy-package-$package" 'preBuild' 'legacyCore' "packages/$package"
  }

  Add-PolicyComponent 'release-core-penv' 'preBuild' 'releaseCore' 'penv'
  Add-PolicyComponent 'release-platform-espressif32' 'preBuild' 'releaseCore' 'platforms/espressif32'
  foreach ($package in @(
      'contrib-piohome', 'framework-arduinoespressif32',
      'framework-arduinoespressif32-libs', 'toolchain-xtensa-esp-elf',
      'tool-esptoolpy', 'tool-scons')) {
    Add-PolicyComponent "release-package-$package" 'preBuild' 'releaseCore' "packages/$package"
  }

  foreach ($environment in @('stackchan', 'stackchan_servo_calibration', 'stackchan_release_full')) {
    Add-PolicyComponent "project-libdeps-$environment" 'postBuild' 'projectRoot' ".pio/libdeps/$environment"
  }
  return @($components)
}

function Resolve-StackchanIdentityComponentPath {
  param(
    [Parameter(Mandatory = $true)][hashtable]$RootMap,
    [Parameter(Mandatory = $true)]$Component
  )

  $rootKey = [string]$Component.rootKey
  if (-not $RootMap.ContainsKey($rootKey) -or
      [string]::IsNullOrWhiteSpace([string]$RootMap[$rootKey])) {
    throw "Release toolchain identity root map is missing: $rootKey"
  }
  $rootItem = Get-Item -LiteralPath ([string]$RootMap[$rootKey]) -Force -ErrorAction Stop
  if (-not $rootItem.PSIsContainer -or
      ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "Release toolchain identity root is not a real directory: $rootKey"
  }
  $root = $rootItem.FullName.TrimEnd('\', '/')
  $relative = ConvertTo-StackchanSafeIdentityRelativePath ([string]$Component.relativePath)
  if ($relative -ceq '@root') { return $root }
  $candidate = [IO.Path]::GetFullPath((Join-Path $root ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)))
  $comparison = if ($env:OS -eq 'Windows_NT') {
    [StringComparison]::OrdinalIgnoreCase
  } else {
    [StringComparison]::Ordinal
  }
  if (-not $candidate.StartsWith($root + [IO.Path]::DirectorySeparatorChar, $comparison)) {
    throw "Toolchain identity component escaped root $rootKey`: $relative"
  }
  return $candidate
}

function Get-StackchanReleaseToolchainObservedComponents {
  param(
    [Parameter(Mandatory = $true)][hashtable]$RootMap,
    [Parameter(Mandatory = $true)][ValidateSet('PreBuild', 'PostBuild')][string]$Phase,
    [string]$PlatformKey = (Get-StackchanReleaseToolchainPlatformKey)
  )

  if ($Phase -ceq 'PostBuild') {
    throw 'PostBuild toolchain eligibility is disabled: canonical libdeps analysis does not yet prove Git pack object-to-offset mappings with an independently trusted Git/runtime, and fresh evidence does not yet cover all three environments.'
  }

  $policy = @(Get-StackchanReleaseToolchainComponentPolicy -PlatformKey $PlatformKey)
  $selected = @($policy | Where-Object {
    [string]$_.phase -ceq 'preBuild' -or $Phase -ceq 'PostBuild'
  })
  $observed = [System.Collections.Generic.List[object]]::new()
  foreach ($component in $selected) {
    $path = Resolve-StackchanIdentityComponentPath -RootMap $RootMap -Component $component
    if ([string]$component.phase -ceq 'postBuild') {
      $environment = ([string]$component.name).Substring('project-libdeps-'.Length)
      $identity = Get-StackchanCanonicalLibdepsIdentity -Root $path -Environment $environment
    } elseif (Test-Path -LiteralPath $path -PathType Leaf) {
      $leaf = Split-Path -Leaf $path
      $sha256 = Get-StackchanFileSha256 -LiteralPath $path
      $length = [long](Get-Item -LiteralPath $path -Force).Length
      $recordText = "$script:StackchanToolchainInventorySchema`nF`0$leaf`0$length`0$sha256`n"
      $recordHasher = [Security.Cryptography.SHA256]::Create()
      try {
        $treeHash = ([BitConverter]::ToString(
          $recordHasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($recordText))) -replace '-', '').ToUpperInvariant()
      } finally {
        $recordHasher.Dispose()
      }
      $identity = [pscustomobject][ordered]@{
        schema = $script:StackchanToolchainInventorySchema
        treeSha256 = $treeHash
        fileCount = 1
        bytes = $length
      }
    } elseif (Test-Path -LiteralPath $path -PathType Container) {
      $identity = Get-StackchanToolchainTreeIdentity -Root $path
    } else {
      throw "Required release toolchain component is missing: $($component.name) ($path)"
    }
    $observed.Add([pscustomobject][ordered]@{
      name = [string]$component.name
      phase = [string]$component.phase
      identitySchema = [string]$identity.schema
      treeSha256 = [string]$identity.treeSha256
      fileCount = [int]$identity.fileCount
      bytes = [long]$identity.bytes
    }) | Out-Null
  }
  return @($observed)
}

function New-StackchanReleaseToolchainIdentityCandidate {
  param(
    [Parameter(Mandatory = $true)][hashtable]$RootMap,
    [Parameter(Mandatory = $true)][string]$PlatformioExecutable,
    [Parameter(Mandatory = $true)][string]$PythonExecutable,
    [string]$PlatformKey = (Get-StackchanReleaseToolchainPlatformKey)
  )

  $pythonHome = (Get-Item -LiteralPath ([string]$RootMap.pythonHome) -Force -ErrorAction Stop).FullName.TrimEnd('\', '/')
  $expectedPio = @('Scripts/pio.exe', 'Scripts/platformio.exe') | ForEach-Object {
    [IO.Path]::GetFullPath((Join-Path $pythonHome $_))
  }
  $resolvedPio = (Get-Item -LiteralPath $PlatformioExecutable -Force -ErrorAction Stop).FullName
  $resolvedPython = (Get-Item -LiteralPath $PythonExecutable -Force -ErrorAction Stop).FullName
  $comparison = if ($env:OS -eq 'Windows_NT') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
  if (@($expectedPio | Where-Object { $_.Equals($resolvedPio, $comparison) }).Count -ne 1) {
    throw 'PlatformIO executable is outside the reviewed Python installation.'
  }
  $expectedPython = [IO.Path]::GetFullPath((Join-Path $pythonHome 'python.exe'))
  if (-not $expectedPython.Equals($resolvedPython, $comparison)) {
    throw 'Python executable is outside the reviewed Python installation.'
  }
  Assert-StackchanPythonImportIsolation `
    -PythonHome $pythonHome -PythonExecutable $resolvedPython
  $components = @(Get-StackchanReleaseToolchainObservedComponents `
    -RootMap $RootMap -Phase PostBuild -PlatformKey $PlatformKey)
  return [pscustomobject][ordered]@{
    schema = $script:StackchanToolchainIdentitySchema
    platformKey = $PlatformKey
    platformioCoreVersion = '6.1.19'
    pythonVersion = '3.12.10'
    identityScope = 'exact-host-installed-bytes'
    portableAcrossHosts = $false
    canonicalLibdepsSchema = $script:StackchanCanonicalLibdepsSchema
    platformioExecutableRelativePaths = @('Scripts/pio.exe', 'Scripts/platformio.exe')
    pythonExecutableRelativePath = 'python.exe'
    generatedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    review = [ordered]@{
      status = 'candidate-unreviewed'
      instructions = 'Review package sources, component inventory, and hashes; then set status=reviewed and record reviewer/reason in the committed allowlist.'
    }
    components = $components
  }
}

function Assert-StackchanReleaseToolchainIdentity {
  param(
    [Parameter(Mandatory = $true)][string]$AllowlistPath,
    [Parameter(Mandatory = $true)][hashtable]$RootMap,
    [Parameter(Mandatory = $true)][string]$PlatformioExecutable,
    [Parameter(Mandatory = $true)][string]$PythonExecutable,
    [Parameter(Mandatory = $true)][ValidateSet('PreBuild', 'PostBuild')][string]$Phase,
    [string]$PlatformKey = (Get-StackchanReleaseToolchainPlatformKey)
  )

  $allowlist = Get-Content -LiteralPath $AllowlistPath -Raw -ErrorAction Stop | ConvertFrom-Json
  if ([string]$allowlist.schema -cne $script:StackchanToolchainIdentitySchema -or
      [string]$allowlist.platformKey -cne $PlatformKey -or
      [string]$allowlist.review.status -cne 'reviewed' -or
      [string]::IsNullOrWhiteSpace([string]$allowlist.review.reviewer) -or
      [string]::IsNullOrWhiteSpace([string]$allowlist.review.reason)) {
    throw "Release toolchain allowlist is absent, unreviewed, or for another platform: $PlatformKey"
  }
  if ([string]$allowlist.platformioCoreVersion -cne '6.1.19' -or
      [string]$allowlist.pythonVersion -cne '3.12.10' -or
      [string]$allowlist.identityScope -cne 'exact-host-installed-bytes' -or
      [bool]$allowlist.portableAcrossHosts -or
      [string]$allowlist.canonicalLibdepsSchema -cne $script:StackchanCanonicalLibdepsSchema) {
    throw 'Release toolchain allowlist version policy mismatch.'
  }
  $canonicalLaunchers = @('Scripts/pio.exe', 'Scripts/platformio.exe')
  $allowlistedLaunchers = @($allowlist.platformioExecutableRelativePaths)
  if ($allowlistedLaunchers.Count -ne $canonicalLaunchers.Count -or
      ($allowlistedLaunchers -join "`n") -cne ($canonicalLaunchers -join "`n") -or
      [string]$allowlist.pythonExecutableRelativePath -cne 'python.exe') {
    throw 'Release toolchain allowlist executable paths are not the canonical policy.'
  }

  $pythonHome = (Get-Item -LiteralPath ([string]$RootMap.pythonHome) -Force -ErrorAction Stop).FullName.TrimEnd('\', '/')
  $comparison = if ($env:OS -eq 'Windows_NT') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
  $resolvedPio = (Get-Item -LiteralPath $PlatformioExecutable -Force -ErrorAction Stop).FullName
  $expectedPio = @($allowlist.platformioExecutableRelativePaths | ForEach-Object {
    $relative = ConvertTo-StackchanSafeIdentityRelativePath ([string]$_)
    [IO.Path]::GetFullPath((Join-Path $pythonHome ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)))
  })
  if (@($expectedPio | Where-Object { $_.Equals($resolvedPio, $comparison) }).Count -ne 1) {
    throw 'Selected PlatformIO executable is not one of the byte-allowlisted launchers.'
  }
  $pythonRelative = ConvertTo-StackchanSafeIdentityRelativePath ([string]$allowlist.pythonExecutableRelativePath)
  $expectedPython = [IO.Path]::GetFullPath((Join-Path $pythonHome $pythonRelative))
  $resolvedPython = (Get-Item -LiteralPath $PythonExecutable -Force -ErrorAction Stop).FullName
  if (-not $expectedPython.Equals($resolvedPython, $comparison)) {
    throw 'Selected Python executable is not the byte-allowlisted runtime.'
  }

  Assert-StackchanPythonImportIsolation `
    -PythonHome $pythonHome -PythonExecutable $resolvedPython

  $observed = @(Get-StackchanReleaseToolchainObservedComponents `
    -RootMap $RootMap -Phase $Phase -PlatformKey $PlatformKey)
  $expected = @($allowlist.components | Where-Object {
    [string]$_.phase -ceq 'preBuild' -or $Phase -ceq 'PostBuild'
  })
  if ($expected.Count -ne $observed.Count) {
    throw "Release toolchain allowlist component count mismatch for phase $Phase."
  }
  $expectedNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($entry in $expected) {
    $name = [string]$entry.name
    if ([string]::IsNullOrWhiteSpace($name) -or -not $expectedNames.Add($name)) {
      throw "Release toolchain allowlist has an invalid or duplicate component: $name"
    }
    $matches = @($observed | Where-Object { [string]$_.name -ceq $name })
    if ($matches.Count -ne 1 -or
        [string]$entry.phase -cne [string]$matches[0].phase -or
        [string]$entry.identitySchema -cne [string]$matches[0].identitySchema -or
        [string]$entry.treeSha256 -cne [string]$matches[0].treeSha256 -or
        [int]$entry.fileCount -ne [int]$matches[0].fileCount -or
        [long]$entry.bytes -ne [long]$matches[0].bytes) {
      throw "Release toolchain byte identity mismatch: $name"
    }
  }
  return [pscustomobject][ordered]@{
    schema = $script:StackchanToolchainIdentitySchema
    status = 'verified'
    platformKey = $PlatformKey
    phase = $Phase
    componentCount = $observed.Count
  }
}
