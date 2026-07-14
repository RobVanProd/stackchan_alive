param(
  [ValidateSet("windows", "linux", "macos")]
  [string]$Platform,
  [string]$PackagePath,
  [string]$RuntimePrepareJsonPath,
  [string]$ProcessedRuntimeRoot,
  [string]$PackageExtractionRoot = "",
  [string]$LaunchEvidencePath = "",
  [string]$Version = "",
  [string]$Commit = "",
  [string]$OutPath = "",
  [switch]$RequireInstallerPayload,
  [switch]$RequireLaunchEvidence,
  [switch]$UseExistingPackageExtraction,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

function Get-Sha256Text {
  param([string]$Path)
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $ioPath = if ($env:OS -eq "Windows_NT" -and -not $fullPath.StartsWith("\\?\")) { "\\?\$fullPath" } else { $fullPath }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $stream = [System.IO.File]::OpenRead($ioPath)
  try {
    return (($sha.ComputeHash($stream) | ForEach-Object { $_.ToString("x2") }) -join "")
  } finally {
    $stream.Dispose()
    $sha.Dispose()
  }
}

function Test-Sha256Text {
  param([string]$Value)
  return $Value -match '^[a-fA-F0-9]{64}$'
}

function Get-NormalizedZipEntryName {
  param($Entry)
  return ([string]$Entry.FullName).Replace("\", "/")
}

function Get-ZipEntriesByName {
  param(
    $Archive,
    [string]$Name
  )
  return @($Archive.Entries | Where-Object { (Get-NormalizedZipEntryName $_) -eq $Name })
}

function Get-HostPlatform {
  if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) { return "windows" }
  if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)) { return "linux" }
  if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) { return "macos" }
  return "unknown"
}

function Expand-DesktopPackage {
  param(
    [string]$TargetPlatform,
    [string]$SourcePackage,
    [string]$DestinationRoot
  )

  New-Item -ItemType Directory -Force -Path $DestinationRoot | Out-Null
  switch ($TargetPlatform) {
    "windows" {
      $msiexec = Get-Command msiexec.exe -ErrorAction SilentlyContinue
      if ($null -eq $msiexec) { throw "msiexec.exe is required to inspect the Windows installer payload." }
      $logPath = Join-Path $DestinationRoot "msiexec-admin.log"
      $arguments = @('/a', "`"$SourcePackage`"", '/qn', "TARGETDIR=`"$DestinationRoot`"", '/L*v', "`"$logPath`"")
      $process = Start-Process -FilePath $msiexec.Source -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
      if ($process.ExitCode -ne 0) { throw "MSI administrative extraction failed with exit code $($process.ExitCode). See $logPath" }
    }
    "linux" {
      $dpkg = Get-Command dpkg-deb -ErrorAction SilentlyContinue
      if ($null -eq $dpkg) { throw "dpkg-deb is required to inspect the Linux installer payload." }
      & $dpkg.Source -x $SourcePackage $DestinationRoot
      if ($LASTEXITCODE -ne 0) { throw "DEB extraction failed with exit code $LASTEXITCODE." }
    }
    "macos" {
      $hdiutil = Get-Command hdiutil -ErrorAction SilentlyContinue
      if ($null -eq $hdiutil) { throw "hdiutil is required to inspect the macOS installer payload." }
      $mountPoint = "$DestinationRoot-mount"
      New-Item -ItemType Directory -Force -Path $mountPoint | Out-Null
      $attached = $false
      try {
        & $hdiutil.Source attach $SourcePackage -readonly -nobrowse -mountpoint $mountPoint | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "DMG mount failed with exit code $LASTEXITCODE." }
        $attached = $true
        $mountedApps = @(Get-ChildItem -LiteralPath $mountPoint -Directory -Filter "*.app" -ErrorAction Stop)
        if ($mountedApps.Count -ne 1) { throw "Expected one application bundle in mounted DMG; found $($mountedApps.Count)." }
        & (Get-Command ditto -ErrorAction Stop).Source $mountedApps[0].FullName (Join-Path $DestinationRoot $mountedApps[0].Name)
        if ($LASTEXITCODE -ne 0) { throw "Application bundle copy failed with exit code $LASTEXITCODE." }
      } finally {
        if ($attached) {
          & $hdiutil.Source detach $mountPoint -force | Out-Null
        }
      }
    }
  }
}

function Get-RuntimePayloadHash {
  param([string]$Root)

  $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd("\", "/")
  $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $utf8 = [System.Text.Encoding]::UTF8
  $files = Get-ChildItem -LiteralPath $Root -File -Recurse -Force |
    Where-Object {
      $_.Name -ne "stackchan-python-runtime.json" -and
      $_.FullName -notmatch "([\\/])__pycache__([\\/])"
    } |
    Sort-Object FullName

  foreach ($file in $files) {
    $full = [System.IO.Path]::GetFullPath($file.FullName)
    if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to hash a processed runtime file outside its root: $full"
    }
    $relative = $full.Substring($prefix.Length).Replace("\", "/")
    $pathBytes = $utf8.GetBytes("$relative`n")
    $null = $sha.TransformBlock($pathBytes, 0, $pathBytes.Length, $pathBytes, 0)
    $fileHash = Get-Sha256Text $full
    $hashBytes = $utf8.GetBytes("$fileHash`n")
    $null = $sha.TransformBlock($hashBytes, 0, $hashBytes.Length, $hashBytes, 0)
  }

  $empty = [byte[]]@()
  $null = $sha.TransformFinalBlock($empty, 0, 0)
  return (($sha.Hash | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Get-RuntimeFileInventory {
  param([string]$Root)

  $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd("\", "/")
  $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
  $inventory = @{}
  Get-ChildItem -LiteralPath $Root -File -Recurse -Force |
    Where-Object {
      $_.Name -ne "stackchan-python-runtime.json" -and
      $_.FullName -notmatch "([\\/])__pycache__([\\/])"
    } |
    ForEach-Object {
      $full = [System.IO.Path]::GetFullPath($_.FullName)
      $relative = $full.Substring($prefix.Length).Replace("\", "/")
      $inventory[$relative] = [ordered]@{
        fullPath = $full
        bytes = [int64]$_.Length
        sha256 = Get-Sha256Text $full
      }
    }
  return $inventory
}

function Compare-RuntimeFileInventories {
  param(
    [hashtable]$Expected,
    [hashtable]$Actual,
    [int]$Limit = 12
  )

  $differences = New-Object System.Collections.Generic.List[string]
  $paths = @($Expected.Keys + $Actual.Keys | Sort-Object -Unique)
  foreach ($path in $paths) {
    $expectedEntry = $Expected[$path]
    $actualEntry = $Actual[$path]
    if ($null -eq $expectedEntry) {
      $differences.Add("added $path ($($actualEntry.bytes) bytes, $(([string]$actualEntry.sha256).Substring(0, 12)))...)")
    } elseif ($null -eq $actualEntry) {
      $differences.Add("missing $path ($($expectedEntry.bytes) bytes, $(([string]$expectedEntry.sha256).Substring(0, 12)))...)")
    } elseif ([int64]$expectedEntry.bytes -ne [int64]$actualEntry.bytes -or [string]$expectedEntry.sha256 -ne [string]$actualEntry.sha256) {
      $differences.Add("changed $path (expected $($expectedEntry.bytes)/$(([string]$expectedEntry.sha256).Substring(0, 12))..., actual $($actualEntry.bytes)/$(([string]$actualEntry.sha256).Substring(0, 12))...)")
    }
    if ($differences.Count -ge $Limit) { break }
  }
  return @($differences)
}

function Invoke-NativeCommandCapture {
  param(
    [string]$Command,
    [string[]]$Arguments
  )

  $oldPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & $Command @Arguments 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldPreference
  }
  return [pscustomobject]@{ exitCode = $exitCode; output = $output.Trim() }
}

function Get-Sha256Bytes {
  param([byte[]]$Bytes)

  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    return (($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString("x2") }) -join "")
  } finally {
    $sha.Dispose()
  }
}

function Get-Sha256Utf8Text {
  param([string]$Value)
  return Get-Sha256Bytes ([System.Text.Encoding]::UTF8.GetBytes($Value))
}

function Get-ByteDifferenceSummary {
  param(
    [byte[]]$Expected,
    [byte[]]$Actual,
    [int]$Limit = 8
  )

  $differences = New-Object System.Collections.Generic.List[string]
  $sharedLength = [Math]::Min($Expected.Length, $Actual.Length)
  for ($offset = 0; $offset -lt $sharedLength -and $differences.Count -lt $Limit; $offset++) {
    if ($Expected[$offset] -ne $Actual[$offset]) {
      $differences.Add(("0x{0:x}:0x{1:x2}/0x{2:x2}" -f $offset, $Expected[$offset], $Actual[$offset]))
    }
  }
  if ($differences.Count -lt $Limit -and $Expected.Length -ne $Actual.Length) {
    $differences.Add("length:$($Expected.Length)/$($Actual.Length)")
  }
  if ($differences.Count -eq 0) { return "none" }
  return ($differences -join ",")
}

function Read-MachOUInt32 {
  param(
    [byte[]]$Bytes,
    [int]$Offset,
    [bool]$LittleEndian
  )

  if ($Offset -lt 0 -or $Offset + 4 -gt $Bytes.Length) {
    throw "Mach-O uint32 offset is outside the file."
  }
  $valueBytes = [byte[]]::new(4)
  [Array]::Copy($Bytes, $Offset, $valueBytes, 0, 4)
  if ([BitConverter]::IsLittleEndian -ne $LittleEndian) {
    [Array]::Reverse($valueBytes)
  }
  return [BitConverter]::ToUInt32($valueBytes, 0)
}

function Read-MachOUInt64 {
  param(
    [byte[]]$Bytes,
    [int]$Offset,
    [bool]$LittleEndian
  )

  if ($Offset -lt 0 -or $Offset + 8 -gt $Bytes.Length) {
    throw "Mach-O uint64 offset is outside the file."
  }
  $valueBytes = [byte[]]::new(8)
  [Array]::Copy($Bytes, $Offset, $valueBytes, 0, 8)
  if ([BitConverter]::IsLittleEndian -ne $LittleEndian) {
    [Array]::Reverse($valueBytes)
  }
  return [BitConverter]::ToUInt64($valueBytes, 0)
}

function Get-MachOCodeContentIdentity {
  param([string]$Path)

  $bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -lt 32) { throw "Mach-O file is too short." }
  $rawMagic = [BitConverter]::ToUInt32($bytes, 0)
  switch ($rawMagic) {
    4277009102 { $littleEndian = $true; $headerSize = 28 }
    4277009103 { $littleEndian = $true; $headerSize = 32 }
    3472551422 { $littleEndian = $false; $headerSize = 28 }
    3489328638 { $littleEndian = $false; $headerSize = 32 }
    default { throw "Mach-O file has an unsupported magic value." }
  }

  $commandCount = [int](Read-MachOUInt32 -Bytes $bytes -Offset 16 -LittleEndian $littleEndian)
  $commandBytes = [int](Read-MachOUInt32 -Bytes $bytes -Offset 20 -LittleEndian $littleEndian)
  if ($commandCount -lt 1 -or $headerSize + $commandBytes -gt $bytes.Length) {
    throw "Mach-O load-command table is invalid."
  }

  $commandOffset = $headerSize
  $signatureCommandOffset = -1
  $signatureDataOffset = 0
  $signatureDataSize = 0
  $linkEditVirtualSizeOffset = -1
  $linkEditFileSizeOffset = -1
  $linkEditSizeFieldBytes = 0
  $linkEditFileOffset = 0
  $linkEditFileSize = 0
  $linkEditVirtualSize = 0
  for ($index = 0; $index -lt $commandCount; $index++) {
    $command = Read-MachOUInt32 -Bytes $bytes -Offset $commandOffset -LittleEndian $littleEndian
    $commandSize = [int](Read-MachOUInt32 -Bytes $bytes -Offset ($commandOffset + 4) -LittleEndian $littleEndian)
    if ($commandSize -lt 8 -or $commandOffset + $commandSize -gt $headerSize + $commandBytes) {
      throw "Mach-O load command is invalid."
    }
    if ($command -eq 0x1d) {
      if ($signatureCommandOffset -ge 0 -or $commandSize -ne 16) {
        throw "Mach-O LC_CODE_SIGNATURE command is invalid or duplicated."
      }
      $signatureCommandOffset = $commandOffset
      $signatureDataOffset = [int](Read-MachOUInt32 -Bytes $bytes -Offset ($commandOffset + 8) -LittleEndian $littleEndian)
      $signatureDataSize = [int](Read-MachOUInt32 -Bytes $bytes -Offset ($commandOffset + 12) -LittleEndian $littleEndian)
    }
    if ($command -eq 0x19 -or $command -eq 0x1) {
      $segmentName = [System.Text.Encoding]::ASCII.GetString($bytes, $commandOffset + 8, 16).Trim([char]0)
      if ($segmentName -eq "__LINKEDIT") {
        if ($linkEditFileSizeOffset -ge 0) { throw "Mach-O has duplicate __LINKEDIT segments." }
        if ($command -eq 0x19) {
          if ($commandSize -lt 72) { throw "Mach-O __LINKEDIT segment command is too short." }
          $linkEditVirtualSizeOffset = $commandOffset + 32
          $linkEditFileSizeOffset = $commandOffset + 48
          $linkEditSizeFieldBytes = 8
          $linkEditVirtualSize = [int64](Read-MachOUInt64 -Bytes $bytes -Offset $linkEditVirtualSizeOffset -LittleEndian $littleEndian)
          $linkEditFileOffset = [int64](Read-MachOUInt64 -Bytes $bytes -Offset ($commandOffset + 40) -LittleEndian $littleEndian)
          $linkEditFileSize = [int64](Read-MachOUInt64 -Bytes $bytes -Offset $linkEditFileSizeOffset -LittleEndian $littleEndian)
        } else {
          if ($commandSize -lt 56) { throw "Mach-O __LINKEDIT segment command is too short." }
          $linkEditVirtualSizeOffset = $commandOffset + 28
          $linkEditFileSizeOffset = $commandOffset + 36
          $linkEditSizeFieldBytes = 4
          $linkEditVirtualSize = [int64](Read-MachOUInt32 -Bytes $bytes -Offset $linkEditVirtualSizeOffset -LittleEndian $littleEndian)
          $linkEditFileOffset = [int64](Read-MachOUInt32 -Bytes $bytes -Offset ($commandOffset + 32) -LittleEndian $littleEndian)
          $linkEditFileSize = [int64](Read-MachOUInt32 -Bytes $bytes -Offset $linkEditFileSizeOffset -LittleEndian $littleEndian)
        }
      }
    }
    $commandOffset += $commandSize
  }
  if ($signatureCommandOffset -lt 0 -or $signatureDataOffset -lt $headerSize + $commandBytes -or
      $signatureDataSize -lt 1 -or $signatureDataOffset + $signatureDataSize -gt $bytes.Length) {
    throw "Mach-O embedded code-signature range is invalid."
  }
  if ($linkEditFileSizeOffset -lt 0 -or $linkEditFileOffset -lt 0 -or $linkEditFileSize -lt 1 -or
      $signatureDataOffset -lt $linkEditFileOffset -or
      $signatureDataOffset + $signatureDataSize -ne $linkEditFileOffset + $linkEditFileSize -or
      $linkEditFileOffset + $linkEditFileSize -gt $bytes.Length) {
    throw "Mach-O code signature is not the validated tail of __LINKEDIT."
  }

  $canonical = [byte[]]::new($signatureDataOffset)
  [Array]::Copy($bytes, 0, $canonical, 0, $signatureDataOffset)
  [Array]::Clear($canonical, $signatureCommandOffset, 16)
  [Array]::Clear($canonical, $linkEditVirtualSizeOffset, $linkEditSizeFieldBytes)
  [Array]::Clear($canonical, $linkEditFileSizeOffset, $linkEditSizeFieldBytes)
  return [pscustomobject]@{
    sha256 = Get-Sha256Bytes $canonical
    codeBytes = $signatureDataOffset
    signatureBytes = $signatureDataSize
    linkEditFileBytes = $linkEditFileSize
    linkEditVirtualBytes = $linkEditVirtualSize
    canonicalBytes = $canonical
  }
}

function Test-MacOSSignatureNormalizedRuntimeIdentity {
  param(
    [hashtable]$Expected,
    [hashtable]$Actual,
    [string]$ExpectedPayloadSha256,
    [string]$ActualPayloadSha256
  )

  $result = [ordered]@{
    status = "not-ready"
    tool = "codesign"
    processedPayloadSha256 = $ExpectedPayloadSha256
    installerPayloadSha256 = $ActualPayloadSha256
    changedFileCount = 0
    files = @()
    issue = ""
  }
  if ((Get-HostPlatform) -ne "macos" -or $Platform -ne "macos") {
    $result.issue = "macOS signature normalization requires a native macOS host."
    return [pscustomobject]$result
  }

  $codesign = Get-Command codesign -ErrorAction SilentlyContinue
  $fileCommand = Get-Command file -ErrorAction SilentlyContinue
  $lipo = Get-Command lipo -ErrorAction SilentlyContinue
  if ($null -eq $codesign -or $null -eq $fileCommand -or $null -eq $lipo) {
    $result.issue = "macOS signature normalization requires codesign, file, and lipo."
    return [pscustomobject]$result
  }

  $expectedPaths = @($Expected.Keys | Sort-Object)
  $actualPaths = @($Actual.Keys | Sort-Object)
  if ($expectedPaths.Count -ne $actualPaths.Count -or
      (Compare-Object -ReferenceObject $expectedPaths -DifferenceObject $actualPaths).Count -ne 0) {
    $result.issue = "Processed and installer runtime path sets differ."
    return [pscustomobject]$result
  }

  $changedPaths = @($expectedPaths | Where-Object {
    [int64]$Expected[$_].bytes -ne [int64]$Actual[$_].bytes -or
    [string]$Expected[$_].sha256 -ne [string]$Actual[$_].sha256
  })
  if ($changedPaths.Count -lt 1) {
    $result.issue = "No changed runtime files require signature normalization."
    return [pscustomobject]$result
  }

  $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-codesign-normalize-" + [guid]::NewGuid().ToString("N"))
  New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
  try {
    $proofs = New-Object System.Collections.Generic.List[object]
    $index = 0
    foreach ($path in $changedPaths) {
      $expectedPath = [string]$Expected[$path].fullPath
      $actualPath = [string]$Actual[$path].fullPath
      $expectedFileType = Invoke-NativeCommandCapture -Command $fileCommand.Source -Arguments @("-b", $expectedPath)
      $actualFileType = Invoke-NativeCommandCapture -Command $fileCommand.Source -Arguments @("-b", $actualPath)
      if ($expectedFileType.exitCode -ne 0 -or $actualFileType.exitCode -ne 0 -or
          $expectedFileType.output -notmatch "Mach-O" -or $actualFileType.output -notmatch "Mach-O") {
        $result.issue = "Changed runtime file is not Mach-O on both sides: $path"
        return [pscustomobject]$result
      }

      $expectedVerify = Invoke-NativeCommandCapture -Command $codesign.Source -Arguments @("--verify", "--strict", "--verbose=2", $expectedPath)
      $actualVerify = Invoke-NativeCommandCapture -Command $codesign.Source -Arguments @("--verify", "--strict", "--verbose=2", $actualPath)
      if ($expectedVerify.exitCode -ne 0 -or $actualVerify.exitCode -ne 0) {
        $result.issue = "Processed and installer runtime files must both have valid strict code signatures: $path"
        return [pscustomobject]$result
      }

      $expectedArchResult = Invoke-NativeCommandCapture -Command $lipo.Source -Arguments @("-archs", $expectedPath)
      $actualArchResult = Invoke-NativeCommandCapture -Command $lipo.Source -Arguments @("-archs", $actualPath)
      $expectedArchitectures = @($expectedArchResult.output -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
      $actualArchitectures = @($actualArchResult.output -split '\s+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)
      if ($expectedArchResult.exitCode -ne 0 -or $actualArchResult.exitCode -ne 0 -or
          $expectedArchitectures.Count -lt 1 -or $expectedArchitectures.Count -ne $actualArchitectures.Count -or
          (Compare-Object -ReferenceObject $expectedArchitectures -DifferenceObject $actualArchitectures).Count -ne 0) {
        $result.issue = "Processed and installer runtime architecture sets differ: $path"
        return [pscustomobject]$result
      }

      $architectureProofs = New-Object System.Collections.Generic.List[object]
      foreach ($architecture in $expectedArchitectures) {
        $expectedCopy = Join-Path $tempRoot ("expected-{0:D3}-{1}" -f $index, $architecture)
        $actualCopy = Join-Path $tempRoot ("actual-{0:D3}-{1}" -f $index, $architecture)
        if ($expectedArchitectures.Count -eq 1) {
          Copy-Item -LiteralPath $expectedPath -Destination $expectedCopy
          Copy-Item -LiteralPath $actualPath -Destination $actualCopy
        } else {
          $expectedThin = Invoke-NativeCommandCapture -Command $lipo.Source -Arguments @("-thin", $architecture, $expectedPath, "-output", $expectedCopy)
          $actualThin = Invoke-NativeCommandCapture -Command $lipo.Source -Arguments @("-thin", $architecture, $actualPath, "-output", $actualCopy)
          if ($expectedThin.exitCode -ne 0 -or $actualThin.exitCode -ne 0) {
            $result.issue = "Could not extract matching Mach-O architecture '$architecture': $path"
            return [pscustomobject]$result
          }
        }

        try {
          $expectedIdentity = Get-MachOCodeContentIdentity $expectedCopy
          $actualIdentity = Get-MachOCodeContentIdentity $actualCopy
        } catch {
          $result.issue = "Could not parse Mach-O code-signature boundaries for '$architecture': $path ($($_.Exception.Message))"
          return [pscustomobject]$result
        }
        if ($expectedIdentity.sha256 -ne $actualIdentity.sha256 -or $expectedIdentity.codeBytes -ne $actualIdentity.codeBytes) {
          $byteDifferences = Get-ByteDifferenceSummary -Expected $expectedIdentity.canonicalBytes -Actual $actualIdentity.canonicalBytes
          $result.issue = "Mach-O code content differs outside LC_CODE_SIGNATURE for '$architecture': $path (codeBytes $($expectedIdentity.codeBytes)/$($actualIdentity.codeBytes); signatureBytes $($expectedIdentity.signatureBytes)/$($actualIdentity.signatureBytes); firstDiffs $byteDifferences)"
          return [pscustomobject]$result
        }
        $architectureProofs.Add([ordered]@{
          architecture = $architecture
          codeContentSha256 = [string]$expectedIdentity.sha256
          codeBytes = [int64]$expectedIdentity.codeBytes
          processedSignatureBytes = [int64]$expectedIdentity.signatureBytes
          installerSignatureBytes = [int64]$actualIdentity.signatureBytes
          processedLinkEditFileBytes = [int64]$expectedIdentity.linkEditFileBytes
          installerLinkEditFileBytes = [int64]$actualIdentity.linkEditFileBytes
          processedLinkEditVirtualBytes = [int64]$expectedIdentity.linkEditVirtualBytes
          installerLinkEditVirtualBytes = [int64]$actualIdentity.linkEditVirtualBytes
        })
      }
      $normalizedFileSha = Get-Sha256Utf8Text (($architectureProofs | ForEach-Object {
        "$($_.architecture)`n$($_.codeContentSha256)`n$($_.codeBytes)`n"
      }) -join "")
      $proofs.Add([ordered]@{
        path = $path
        processedFileSha256 = [string]$Expected[$path].sha256
        installerFileSha256 = [string]$Actual[$path].sha256
        normalizedFileSha256 = $normalizedFileSha
        architectures = $architectureProofs.ToArray()
      })
      $index++
    }

    $result.status = "ready"
    $result.changedFileCount = $proofs.Count
    $result.files = $proofs.ToArray()
    return [pscustomobject]$result
  } finally {
    if (Test-Path -LiteralPath $tempRoot) {
      Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
  }
}

function Add-Issue {
  param([string]$Message)
  $script:issues += $Message
}

$issues = @()
$expectedExtension = @{ windows = ".msi"; linux = ".deb"; macos = ".dmg" }[$Platform]
$package = $null
$prepare = $null
$manifest = $null
$processedHash = ""
$processedFiles = @()
$processedInventory = $null
$installerInventory = $null
$installerPayload = [ordered]@{
  required = [bool]$RequireInstallerPayload
  status = if ($RequireInstallerPayload) { "not-ready" } else { "not-required" }
  extractionMethod = ""
  extractionRoot = ""
  appJarName = ""
  appJarSha256 = ""
  packageSha256 = ""
  runtimeLocation = ""
  runtimeRootRelative = ""
  runtimePayloadSha256 = ""
  runtimeFileCount = 0
  runtimeBytes = 0
  runtimeManifestSchema = ""
  runtimeManifestPlatform = ""
  runtimeManifestSha256 = ""
  contentIdentityStatus = "not-ready"
  signatureNormalization = [ordered]@{
    status = "not-required"
    tool = ""
    processedPayloadSha256 = ""
    installerPayloadSha256 = ""
    changedFileCount = 0
    files = @()
  }
  requiredBrainFiles = @()
}
$launchEvidence = [ordered]@{
  required = [bool]$RequireLaunchEvidence
  status = if ($RequireLaunchEvidence) { "not-ready" } else { "not-required" }
  path = $LaunchEvidencePath
  packageSha256 = ""
  extractionMethod = ""
  extractionRoot = ""
  launcherPath = ""
  processExitCode = $null
  pythonVersion = ""
  scope = ""
}

if ([string]::IsNullOrWhiteSpace($PackagePath) -or -not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
  Add-Issue "Desktop package is missing: $PackagePath"
} else {
  $package = Get-Item -LiteralPath $PackagePath
  if ($package.Extension.ToLowerInvariant() -ne $expectedExtension) {
    Add-Issue "Desktop package for $Platform must use $expectedExtension, got $($package.Extension)."
  }
}

if ([string]::IsNullOrWhiteSpace($RuntimePrepareJsonPath) -or -not (Test-Path -LiteralPath $RuntimePrepareJsonPath -PathType Leaf)) {
  Add-Issue "Managed runtime prepare JSON is missing: $RuntimePrepareJsonPath"
} else {
  try {
    $prepare = Get-Content -LiteralPath $RuntimePrepareJsonPath -Raw | ConvertFrom-Json
  } catch {
    Add-Issue "Managed runtime prepare JSON is invalid: $($_.Exception.Message)"
  }
}

if ($null -ne $prepare) {
  if ([string]$prepare.schema -ne "stackchan.desktop-python-runtime-prepare.v1") { Add-Issue "Unexpected runtime prepare schema: $($prepare.schema)" }
  if ([string]$prepare.status -ne "ready") { Add-Issue "Runtime prepare status must be ready, got $($prepare.status)." }
  if ([string]$prepare.platform -ne $Platform) { Add-Issue "Runtime prepare platform must be $Platform, got $($prepare.platform)." }
  if (-not (Test-Sha256Text ([string]$prepare.payloadSha256))) { Add-Issue "Runtime prepare payloadSha256 is invalid." }
  if ($null -eq $prepare.validation) {
    Add-Issue "Runtime prepare validation report is missing."
  } else {
    if ([string]$prepare.validation.schema -ne "stackchan.desktop-python-runtime-payload.v1") { Add-Issue "Unexpected runtime validation schema: $($prepare.validation.schema)" }
    if ([string]$prepare.validation.status -ne "ready") { Add-Issue "Runtime validation status must be ready, got $($prepare.validation.status)." }
    if ([string]$prepare.validation.platform -ne $Platform) { Add-Issue "Runtime validation platform must be $Platform, got $($prepare.validation.platform)." }
    if ([string]$prepare.validation.runtimeSha256 -ne [string]$prepare.payloadSha256) { Add-Issue "Runtime prepare and validation SHA-256 values disagree." }
    if ([string]::IsNullOrWhiteSpace([string]$prepare.validation.runtimeSource) -or [string]$prepare.validation.runtimeSource -match '<|>|pending|TBD') { Add-Issue "Runtime source is missing or placeholder text." }
    if ([string]::IsNullOrWhiteSpace([string]$prepare.validation.pythonVersion)) { Add-Issue "Runtime pythonVersion is missing." }
    if ([string]::IsNullOrWhiteSpace([string]$prepare.validation.probedPythonVersion)) { Add-Issue "Runtime probedPythonVersion is missing." }
  }
}

if ([string]::IsNullOrWhiteSpace($ProcessedRuntimeRoot) -or -not (Test-Path -LiteralPath $ProcessedRuntimeRoot -PathType Container)) {
  Add-Issue "Processed desktop runtime resource is missing: $ProcessedRuntimeRoot"
} else {
  $manifestPath = Join-Path $ProcessedRuntimeRoot "stackchan-python-runtime.json"
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Add-Issue "Processed desktop runtime manifest is missing."
  } else {
    try {
      $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    } catch {
      Add-Issue "Processed desktop runtime manifest is invalid JSON: $($_.Exception.Message)"
    }
  }
  $processedFiles = @(Get-ChildItem -LiteralPath $ProcessedRuntimeRoot -File -Recurse -Force)
  if ($processedFiles.Count -lt 2) { Add-Issue "Processed desktop runtime contains too few files." }
  try {
    $processedHash = Get-RuntimePayloadHash $ProcessedRuntimeRoot
    $processedInventory = Get-RuntimeFileInventory $ProcessedRuntimeRoot
  } catch {
    Add-Issue $_.Exception.Message
  }
}

if ($null -ne $manifest) {
  if ([string]$manifest.schema -ne "stackchan.desktop-python-runtime.v1") { Add-Issue "Unexpected processed runtime manifest schema: $($manifest.schema)" }
  if ([string]$manifest.platform -ne $Platform) { Add-Issue "Processed runtime platform must be $Platform, got $($manifest.platform)." }
  if ($null -ne $prepare -and [string]$manifest.sha256 -ne [string]$prepare.payloadSha256) { Add-Issue "Processed runtime manifest SHA-256 does not match runtime prepare evidence." }
}
if ($null -ne $prepare -and -not [string]::IsNullOrWhiteSpace($processedHash) -and $processedHash -ne [string]$prepare.payloadSha256) {
  Add-Issue "Processed runtime payload hash does not match runtime prepare evidence."
  if (-not [string]::IsNullOrWhiteSpace([string]$prepare.runtimeRoot) -and
      (Test-Path -LiteralPath ([string]$prepare.runtimeRoot) -PathType Container) -and
      $null -ne $processedInventory) {
    try {
      $prepareInventory = Get-RuntimeFileInventory ([string]$prepare.runtimeRoot)
      foreach ($difference in Compare-RuntimeFileInventories -Expected $prepareInventory -Actual $processedInventory) {
        Add-Issue "Prepare/processed runtime difference: $difference"
      }
    } catch {
      Add-Issue "Prepare/processed runtime inventory comparison failed: $($_.Exception.Message)"
    }
  }
}

if ($RequireInstallerPayload) {
  $installerIssueStart = $issues.Count
  if ($null -eq $package) {
    Add-Issue "Installer payload cannot be inspected because the desktop package is missing."
  } else {
    if ([string]::IsNullOrWhiteSpace($PackageExtractionRoot)) {
      $extractionId = [guid]::NewGuid().ToString("N").Substring(0, 12)
      $PackageExtractionRoot = Join-Path ([System.IO.Path]::GetTempPath()) "stackchan-package-extraction-$Platform-$extractionId"
    }
    $PackageExtractionRoot = [System.IO.Path]::GetFullPath($PackageExtractionRoot)
    $installerPayload.extractionRoot = $PackageExtractionRoot
    if ($UseExistingPackageExtraction) {
      if (-not (Test-Path -LiteralPath $PackageExtractionRoot -PathType Container)) {
        Add-Issue "Existing package extraction root was not found: $PackageExtractionRoot"
      } else {
        $installerPayload.extractionMethod = "existing"
      }
    } else {
      if ((Get-HostPlatform) -ne $Platform) {
        Add-Issue "Installer payload extraction for $Platform must run on a native $Platform host."
      } elseif (Test-Path -LiteralPath $PackageExtractionRoot) {
        Add-Issue "Package extraction root already exists; refusing to overwrite it: $PackageExtractionRoot"
      } else {
        try {
          Expand-DesktopPackage -TargetPlatform $Platform -SourcePackage $package.FullName -DestinationRoot $PackageExtractionRoot
          $installerPayload.extractionMethod = "native"
        } catch {
          Add-Issue $_.Exception.Message
        }
      }
    }

    if (Test-Path -LiteralPath $PackageExtractionRoot -PathType Container) {
      $appJars = @(Get-ChildItem -LiteralPath $PackageExtractionRoot -Recurse -File -Filter "app-desktop-*.jar" -ErrorAction SilentlyContinue)
      if ($appJars.Count -ne 1) {
        Add-Issue "Expected exactly one packaged application JAR; found $($appJars.Count)."
      } else {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $appJar = $appJars[0]
        $installerPayload.appJarName = $appJar.Name
        $installerPayload.appJarSha256 = Get-Sha256Text $appJar.FullName
        $installerPayload.packageSha256 = Get-Sha256Text $package.FullName
        $archive = [System.IO.Compression.ZipFile]::OpenRead($appJar.FullName)
        try {
          $jarRuntimeEntries = @($archive.Entries | Where-Object { (Get-NormalizedZipEntryName $_).StartsWith("python-runtime/") })
          if ($jarRuntimeEntries.Count -ne 0) { Add-Issue "Packaged application JAR must not contain the executable managed runtime." }

          $requiredBrainFiles = @(
            "brain/bridge/lan_service.py",
            "brain/bridge/reference_bridge.py",
            "brain/data/voice_source_provenance.yaml",
            "brain/docs/media/voice/stackchan_spark_greeting.wav"
          )
          $presentBrainFiles = @()
          foreach ($brainPath in $requiredBrainFiles) {
            if (@(Get-ZipEntriesByName $archive $brainPath).Count -eq 1) {
              $presentBrainFiles += $brainPath
            } else {
              Add-Issue "Packaged application JAR is missing required brain resource: $brainPath"
            }
          }
          $installerPayload.requiredBrainFiles = @($presentBrainFiles)
        } finally {
          $archive.Dispose()
        }
      }

      $runtimeRoots = @(Get-ChildItem -LiteralPath $PackageExtractionRoot -Recurse -Directory -Filter "python-runtime" -ErrorAction SilentlyContinue | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName "stackchan-python-runtime.json") -PathType Leaf
      })
      if ($runtimeRoots.Count -ne 1) {
        Add-Issue "Expected exactly one external managed runtime in native app resources; found $($runtimeRoots.Count)."
      } else {
        $runtimeRoot = $runtimeRoots[0].FullName
        $installerPayload.runtimeLocation = "native-app-resources"
        $extractionPrefix = $PackageExtractionRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
        $installerPayload.runtimeRootRelative = $runtimeRoot.Substring($extractionPrefix.Length).Replace("\", "/")
        $runtimeFiles = @(Get-ChildItem -LiteralPath $runtimeRoot -File -Recurse -Force)
        $installerPayload.runtimePayloadSha256 = Get-RuntimePayloadHash $runtimeRoot
        $installerInventory = Get-RuntimeFileInventory $runtimeRoot
        $installerPayload.runtimeFileCount = $runtimeFiles.Count
        $installerPayload.runtimeBytes = [int64](($runtimeFiles | Measure-Object -Property Length -Sum).Sum)
        $installerManifestPath = Join-Path $runtimeRoot "stackchan-python-runtime.json"
        try {
          $installerManifest = Get-Content -LiteralPath $installerManifestPath -Raw | ConvertFrom-Json
          $installerPayload.runtimeManifestSchema = [string]$installerManifest.schema
          $installerPayload.runtimeManifestPlatform = [string]$installerManifest.platform
          $installerPayload.runtimeManifestSha256 = [string]$installerManifest.sha256
          if ([string]$installerManifest.schema -ne "stackchan.desktop-python-runtime.v1") { Add-Issue "Packaged runtime manifest schema is invalid." }
          if ([string]$installerManifest.platform -ne $Platform) { Add-Issue "Packaged runtime manifest platform must be $Platform." }
          if ($null -ne $prepare -and [string]$installerManifest.sha256 -ne [string]$prepare.payloadSha256) { Add-Issue "Packaged runtime manifest SHA-256 does not match runtime prepare evidence." }
        } catch {
          Add-Issue "Packaged runtime manifest is invalid JSON: $($_.Exception.Message)"
        }
        $runtimeExecutables = switch ($Platform) {
          "windows" { @("python.exe", "python/python.exe") }
          default { @("bin/python3", "bin/python", "python3", "python") }
        }
        if (@($runtimeExecutables | Where-Object { Test-Path -LiteralPath (Join-Path $runtimeRoot $_) -PathType Leaf }).Count -lt 1) {
          Add-Issue "External managed runtime does not contain the expected $Platform Python executable."
        }
      }
    }
  }

  $installerRuntimeHash = [string]$installerPayload.runtimePayloadSha256
  $runtimeContentIdentityReady = $false
  if (-not [string]::IsNullOrWhiteSpace($processedHash) -and -not [string]::IsNullOrWhiteSpace($installerRuntimeHash) -and
      $installerRuntimeHash -eq $processedHash) {
    $installerPayload.contentIdentityStatus = "ready-exact"
    $runtimeContentIdentityReady = $true
  } elseif ($Platform -eq "macos" -and $null -ne $processedInventory -and $null -ne $installerInventory) {
    $signatureIdentity = Test-MacOSSignatureNormalizedRuntimeIdentity `
      -Expected $processedInventory `
      -Actual $installerInventory `
      -ExpectedPayloadSha256 $processedHash `
      -ActualPayloadSha256 $installerRuntimeHash
    $installerPayload.signatureNormalization = [ordered]@{
      status = [string]$signatureIdentity.status
      tool = [string]$signatureIdentity.tool
      processedPayloadSha256 = [string]$signatureIdentity.processedPayloadSha256
      installerPayloadSha256 = [string]$signatureIdentity.installerPayloadSha256
      changedFileCount = [int]$signatureIdentity.changedFileCount
      files = @($signatureIdentity.files)
    }
    if ($signatureIdentity.status -eq "ready") {
      $installerPayload.contentIdentityStatus = "ready-signature-normalized"
      $runtimeContentIdentityReady = $true
    } else {
      Add-Issue "Installer runtime signature-normalized identity was not proven: $($signatureIdentity.issue)"
    }
  }
  if (-not $runtimeContentIdentityReady -and
      -not [string]::IsNullOrWhiteSpace($processedHash) -and
      -not [string]::IsNullOrWhiteSpace($installerRuntimeHash)) {
    Add-Issue "Installer runtime payload hash does not match processed Gradle resources."
    if ($null -ne $processedInventory -and $null -ne $installerInventory) {
      foreach ($difference in Compare-RuntimeFileInventories -Expected $processedInventory -Actual $installerInventory) {
        Add-Issue "Processed/installer runtime difference: $difference"
      }
    }
  }
  if ($null -ne $prepare -and -not $runtimeContentIdentityReady) {
    Add-Issue "Installer runtime payload identity does not match runtime prepare evidence."
  }
  if ($processedFiles.Count -gt 0 -and [int]$installerPayload.runtimeFileCount -ne $processedFiles.Count) {
    Add-Issue "Installer runtime file count does not match processed Gradle resources."
  }
  $processedRuntimeBytes = [int64](($processedFiles | Measure-Object -Property Length -Sum).Sum)
  if ($installerPayload.contentIdentityStatus -ne "ready-signature-normalized" -and
      $processedRuntimeBytes -gt 0 -and [int64]$installerPayload.runtimeBytes -ne $processedRuntimeBytes) {
    Add-Issue "Installer runtime byte count does not match processed Gradle resources."
  }
  if ($issues.Count -eq $installerIssueStart) { $installerPayload.status = "ready" }
}

if ($RequireLaunchEvidence -or -not [string]::IsNullOrWhiteSpace($LaunchEvidencePath)) {
  $launchIssueStart = $issues.Count
  if ([string]::IsNullOrWhiteSpace($LaunchEvidencePath) -or -not (Test-Path -LiteralPath $LaunchEvidencePath -PathType Leaf)) {
    Add-Issue "Exact desktop package launch evidence is missing: $LaunchEvidencePath"
  } else {
    try {
      $launch = Get-Content -LiteralPath $LaunchEvidencePath -Raw | ConvertFrom-Json
      $launchEvidence.path = [System.IO.Path]::GetFullPath($LaunchEvidencePath)
      $launchEvidence.packageSha256 = ([string]$launch.package.sha256).ToLowerInvariant()
      $launchEvidence.extractionMethod = [string]$launch.extractionMethod
      $launchEvidence.extractionRoot = [string]$launch.extractionRoot
      $launchEvidence.launcherPath = [string]$launch.launcherPath
      $launchEvidence.processExitCode = $launch.processExitCode
      $launchEvidence.pythonVersion = [string]$launch.probe.pythonVersion
      $launchEvidence.scope = [string]$launch.scope
      if ([string]$launch.schema -ne "stackchan.desktop-package-launch-evidence.v1" -or [string]$launch.status -ne "ready") { Add-Issue "Exact desktop package launch evidence is not ready." }
      if ([string]$launch.platform -ne $Platform) { Add-Issue "Exact desktop package launch platform mismatch." }
      if ($null -eq $package -or $launchEvidence.packageSha256 -ne (Get-Sha256Text $package.FullName)) { Add-Issue "Exact desktop package launch hash does not match the package." }
      if ($launch.extractionMethod -ne "native" -or [int]$launch.processExitCode -ne 0) { Add-Issue "Exact desktop package was not natively extracted and launched successfully." }
      if ($UseExistingPackageExtraction) {
        $launchExtractionRoot = [System.IO.Path]::GetFullPath([string]$launch.extractionRoot).TrimEnd("\", "/")
        if ($launchExtractionRoot -ne $PackageExtractionRoot.TrimEnd("\", "/")) {
          Add-Issue "Exact desktop package launch used a different extraction root."
        } else {
          $installerPayload.extractionMethod = "native"
        }
      }
      if ([string]$launch.probe.schema -ne "stackchan.desktop-packaged-runtime-smoke.v1" -or [string]$launch.probe.status -ne "ready") { Add-Issue "Packaged runtime smoke probe is not ready." }
      if ($launch.probe.runtimePresent -ne $true -or $launch.probe.pythonAvailable -ne $true -or $launch.probe.brainScriptAvailable -ne $true) { Add-Issue "Packaged runtime smoke did not prove all runtime components." }
      if ([string]$launch.probe.launchContext -ne "package-extraction" -or [string]$launch.probe.scope -ne "extracted-native-package-headless-runtime-probe" -or $launch.probe.substitutesForTargetInstall -ne $false) { Add-Issue "Packaged runtime smoke probe context is invalid." }
      if (@($launch.probe.issues).Count -ne 0 -or $launch.substitutesForTargetInstall -ne $false) { Add-Issue "Exact desktop package launch evidence has invalid scope or issues." }
      if ([string]$launch.scope -ne "exact-native-package-extraction-and-headless-launch") { Add-Issue "Exact desktop package launch scope is invalid." }
    } catch {
      Add-Issue "Exact desktop package launch evidence is invalid JSON: $($_.Exception.Message)"
    }
  }
  if ($issues.Count -eq $launchIssueStart) { $launchEvidence.status = "ready" }
}

if ([string]::IsNullOrWhiteSpace($Commit)) {
  $Commit = ((& git -C $repoRoot rev-parse HEAD 2>$null) | Out-String).Trim()
}
if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = ((& git -C $repoRoot describe --tags --always --dirty 2>$null) | Out-String).Trim()
}

$packageEvidence = if ($null -eq $package) {
  [ordered]@{ name = ""; extension = $expectedExtension; bytes = 0; sha256 = "" }
} else {
  [ordered]@{ name = $package.Name; extension = $package.Extension.ToLowerInvariant(); bytes = [int64]$package.Length; sha256 = Get-Sha256Text $package.FullName }
}
$processedBytes = [int64](($processedFiles | Measure-Object -Property Length -Sum).Sum)
$report = [ordered]@{
  schema = "stackchan.desktop-package-evidence.v1"
  status = if ($issues.Count -eq 0) { "ready" } else { "not-ready" }
  platform = $Platform
  version = $Version
  commit = $Commit
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
  package = $packageEvidence
  runtime = [ordered]@{
    payloadSha256 = if ($null -eq $prepare) { "" } else { [string]$prepare.payloadSha256 }
    processedPayloadSha256 = $processedHash
    source = if ($null -eq $prepare -or $null -eq $prepare.validation) { "" } else { [string]$prepare.validation.runtimeSource }
    pythonVersion = if ($null -eq $prepare -or $null -eq $prepare.validation) { "" } else { [string]$prepare.validation.pythonVersion }
    probedPythonVersion = if ($null -eq $prepare -or $null -eq $prepare.validation) { "" } else { [string]$prepare.validation.probedPythonVersion }
    processedFileCount = $processedFiles.Count
    processedBytes = $processedBytes
  }
  installerPayload = $installerPayload
  launchEvidence = $launchEvidence
  issues = @($issues)
}

if ([string]::IsNullOrWhiteSpace($OutPath)) {
  $OutPath = Join-Path $repoRoot "output/companion/desktop-package-evidence/$Platform-package-evidence.json"
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutPath) | Out-Null
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutPath -Encoding UTF8

if ($Json) { $report | ConvertTo-Json -Depth 8 } else { Write-Host "Desktop package evidence: $($report.status) ($Platform)" }
if ($issues.Count -gt 0) { exit 1 }
