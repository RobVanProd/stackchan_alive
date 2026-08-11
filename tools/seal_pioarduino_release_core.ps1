[CmdletBinding(DefaultParameterSetName = 'Seal')]
param(
  [Parameter(Mandatory = $true, ParameterSetName = 'Seal')][string]$ReleaseCoreDir,
  [Parameter(Mandatory = $true, ParameterSetName = 'SelfTest')][switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$utf8 = [Text.UTF8Encoding]::new($false, $true)

function Get-NormalizedFullPath {
  param([Parameter(Mandatory = $true)][string]$LiteralPath)
  $fullPath = [IO.Path]::GetFullPath($LiteralPath)
  $volumeRoot = [IO.Path]::GetPathRoot($fullPath)
  if ($fullPath.Equals($volumeRoot, [StringComparison]::OrdinalIgnoreCase)) {
    return $volumeRoot
  }
  return $fullPath.TrimEnd('\', '/')
}

function Get-PathVolumeRoot {
  param([Parameter(Mandatory = $true)][string]$LiteralPath)
  $root = [IO.Path]::GetPathRoot((Get-NormalizedFullPath -LiteralPath $LiteralPath))
  if ([string]::IsNullOrWhiteSpace($root)) {
    throw "Path has no volume root: $LiteralPath"
  }
  return Get-NormalizedFullPath -LiteralPath $root
}

function Assert-PathContained {
  param(
    [Parameter(Mandatory = $true)][string]$LiteralPath,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Label
  )
  $fullPath = Get-NormalizedFullPath -LiteralPath $LiteralPath
  $fullRoot = Get-NormalizedFullPath -LiteralPath $Root
  $rootPrefix = if ($fullRoot.EndsWith([IO.Path]::DirectorySeparatorChar)) {
    $fullRoot
  } else {
    $fullRoot + [IO.Path]::DirectorySeparatorChar
  }
  if (-not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw "$Label is outside its reviewed root: $fullPath"
  }
  return $fullPath
}

function Assert-ExistingPathChainReal {
  param(
    [Parameter(Mandatory = $true)][string]$LiteralPath,
    [Parameter(Mandatory = $true)][string]$StopAt,
    [Parameter(Mandatory = $true)][string]$Label
  )
  $cursor = Get-NormalizedFullPath -LiteralPath $LiteralPath
  $stop = Get-NormalizedFullPath -LiteralPath $StopAt
  if ($cursor -cne $stop) {
    [void](Assert-PathContained -LiteralPath $cursor -Root $stop -Label $Label)
  }
  while ($true) {
    if (Test-Path -LiteralPath $cursor) {
      $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
      if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "$Label contains a reparse point: $cursor"
      }
    }
    if ($cursor.Equals($stop, [StringComparison]::OrdinalIgnoreCase)) { break }
    $parent = [IO.Path]::GetDirectoryName($cursor)
    if ([string]::IsNullOrWhiteSpace($parent) -or $parent -ceq $cursor) {
      throw "$Label path chain did not reach its reviewed root."
    }
    $cursor = Get-NormalizedFullPath -LiteralPath $parent
  }
}

$targets = @(
  [ordered]@{
    label = 'pioarduino penv setup'
    relative = 'platforms/espressif32/builder/penv_setup.py'
    originalSha256 = '6FC4C8912CBB1FA65A84A527EC5A3CB1280BBA399B02D4885C8C1D91AB7CC9D0'
    sealedSha256 = 'D16479CFAD23EF7C392B48C66B9E2422C0294E185746814ED4F7F9E4EFFACB60'
    backupLeaf = 'penv_setup.py.6FC4C8912CBB1FA65A84A527EC5A3CB1280BBA399B02D4885C8C1D91AB7CC9D0.bak'
    mode = 'penv-distribution-name'
  },
  [ordered]@{
    label = 'pioarduino component manager'
    relative = 'platforms/espressif32/builder/frameworks/component_manager.py'
    originalSha256 = '756B5AAF863F0BCC0E7CB88C9DDBA3FCE2055E1DC6A4D7362ADC057F813324F8'
    sealedSha256 = 'DCABDC11CA1DEA4FBF3854811BF24CD2ADC9AD692785FB27B1EBA0CF41C924E7'
    backupLeaf = 'component_manager.py.756B5AAF863F0BCC0E7CB88C9DDBA3FCE2055E1DC6A4D7362ADC057F813324F8.bak'
    mode = 'component-manager-noop-and-lto'
  }
)

function Get-SealedTargetBytes {
  param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][byte[]]$OriginalBytes
  )

  $originalText = $utf8.GetString($OriginalBytes)
  if ($Mode -ceq 'penv-distribution-name') {
    $oldDependency = '    "platformio": "https://github.com/pioarduino/platformio-core/archive/refs/tags/v6.1.18.zip",'
    $newDependency = '    "pioarduino-core": "https://github.com/pioarduino/platformio-core/archive/refs/tags/v6.1.18.zip",'
    $oldBranch = '        elif name == "platformio":'
    $newBranch = '        elif name in ("platformio", "pioarduino-core"):'
    foreach ($anchor in @($oldDependency, $oldBranch)) {
      if ([regex]::Matches($originalText, [regex]::Escape($anchor)).Count -ne 1) {
        throw 'Reviewed pioarduino penv seal anchors are missing or ambiguous.'
      }
    }
    # The reviewed installed identity predates this sealer and has LF only on
    # these two corrected lines. Reproduce those exact bytes rather than
    # silently promoting a whole-file or all-CRLF variant.
    $oldDependencyLine = $oldDependency + "`r`n"
    $newDependencyLine = $newDependency + "`n"
    $oldBranchLine = $oldBranch + "`r`n"
    $newBranchLine = $newBranch + "`n"
    if ([regex]::Matches($originalText, [regex]::Escape($oldDependencyLine)).Count -ne 1 -or
        [regex]::Matches($originalText, [regex]::Escape($oldBranchLine)).Count -ne 1) {
      throw 'Reviewed pioarduino penv line-ending anchors are missing or ambiguous.'
    }
    return $utf8.GetBytes($originalText.Replace($oldDependencyLine, $newDependencyLine).
      Replace($oldBranchLine, $newBranchLine))
  }

  if ($Mode -ceq 'component-manager-noop-and-lto') {
    $oldIgnoreBlock = (
      "        # Create backup before processing lib_ignore`r`n" +
      "        if not self.ignored_libs:`r`n" +
      "            self._backup_pioarduino_build_py()`r`n`r`n" +
      "        # Get lib_ignore entries from current environment only`r`n" +
      "        lib_ignore_entries = self._get_lib_ignore_entries()`r`n`r`n" +
      "        if lib_ignore_entries:`r`n" +
      "            self.ignored_libs.update(lib_ignore_entries)`r`n")
    $newIgnoreBlock = (
      "        # Get lib_ignore entries from current environment only`r`n" +
      "        lib_ignore_entries = self._get_lib_ignore_entries()`r`n`r`n" +
      "        if lib_ignore_entries:`r`n" +
      "            self._backup_pioarduino_build_py()`r`n" +
      "            self.ignored_libs.update(lib_ignore_entries)`r`n")
    $oldLtoBlock = (
      '    def remove_no_lto_flags(self) -> bool:' + "`r`n" +
      '        """' + "`r`n" +
      '        Remove all -fno-lto flags from pioarduino-build.py.' + "`r`n`r`n" +
      '        Removes all occurrences of -fno-lto from CCFLAGS, CFLAGS, CXXFLAGS,' + "`r`n" +
      '        and LINKFLAGS in the Arduino build script.' + "`r`n`r`n" +
      '        Returns:' + "`r`n" +
      '            bool: True if successful, False otherwise' + "`r`n" +
      '        """' + "`r`n" +
      '        build_py_path = str(Path(self.config.arduino_libs_mcu) / "pioarduino-build.py")' +
        "`r`n`r`n" +
      '        if not os.path.exists(build_py_path):' + "`r`n" +
      '            print(f"Warning: pioarduino-build.py not found at {build_py_path}")' + "`r`n" +
      '            return False' + "`r`n`r`n" +
      '        try:' + "`r`n")
    $newLtoBlock = $oldLtoBlock.Replace(
      "            return False`r`n`r`n        try:`r`n",
      ("            return False`r`n`r`n" +
       "        self.backup_manager.backup_pioarduino_build_py()`r`n`r`n" +
       "        try:`r`n"))
    if ([regex]::Matches($originalText, [regex]::Escape($oldIgnoreBlock)).Count -ne 1 -or
        [regex]::Matches($originalText, [regex]::Escape($newIgnoreBlock)).Count -ne 0 -or
        [regex]::Matches($originalText, [regex]::Escape($oldLtoBlock)).Count -ne 1 -or
        [regex]::Matches($originalText, [regex]::Escape($newLtoBlock)).Count -ne 0) {
      throw 'Reviewed pioarduino component-manager seal anchors are missing or ambiguous.'
    }
    $sealedText = $originalText.Replace($oldIgnoreBlock, $newIgnoreBlock).
      Replace($oldLtoBlock, $newLtoBlock)
    return $utf8.GetBytes($sealedText)
  }

  throw "Unknown pioarduino seal mode: $Mode"
}

function Get-BytesSha256 {
  param([Parameter(Mandatory = $true)][byte[]]$Bytes)
  $hasher = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($hasher.ComputeHash($Bytes)) -replace '-', '')
  } finally {
    $hasher.Dispose()
  }
}

function New-SealTransactionPlanSet {
  param(
    [Parameter(Mandatory = $true)][string]$CoreRoot,
    [Parameter(Mandatory = $true)][string]$BackupRoot,
    [Parameter(Mandatory = $true)][string]$BackupAuthorityRoot,
    [Parameter(Mandatory = $true)][object[]]$Targets,
    [Parameter(Mandatory = $true)][string]$TransactionId
  )

  $normalizedCoreRoot = Get-NormalizedFullPath -LiteralPath $CoreRoot
  $normalizedBackupRoot = Get-NormalizedFullPath -LiteralPath $BackupRoot
  $normalizedBackupAuthorityRoot = Get-NormalizedFullPath -LiteralPath $BackupAuthorityRoot
  $coreVolumeRoot = Get-PathVolumeRoot -LiteralPath $normalizedCoreRoot
  $backupVolumeRoot = Get-PathVolumeRoot -LiteralPath $normalizedBackupAuthorityRoot
  [void](Assert-ExistingPathChainReal -LiteralPath $normalizedCoreRoot `
    -StopAt $coreVolumeRoot -Label 'pioarduino release core ancestry')
  [void](Assert-ExistingPathChainReal -LiteralPath $normalizedBackupAuthorityRoot `
    -StopAt $backupVolumeRoot -Label 'backup authority ancestry')
  [void](Assert-PathContained -LiteralPath $normalizedBackupRoot `
    -Root $normalizedBackupAuthorityRoot -Label 'private toolchain backup root')
  [void](Assert-ExistingPathChainReal -LiteralPath $normalizedBackupRoot `
    -StopAt $backupVolumeRoot -Label 'private toolchain backup root ancestry')

  $safeTransactionId = $TransactionId -replace '[^A-Za-z0-9._-]', '-'
  if ([string]::IsNullOrWhiteSpace($safeTransactionId)) {
    throw 'Seal transaction identifier is empty after normalization.'
  }
  $plans = [Collections.Generic.List[object]]::new()
  $alreadySealed = [Collections.Generic.List[string]]::new()
  foreach ($target in $Targets) {
    $targetPath = Assert-PathContained `
      -LiteralPath (Join-Path $normalizedCoreRoot ([string]$target.relative)) `
      -Root $normalizedCoreRoot -Label ([string]$target.label)
    [void](Assert-ExistingPathChainReal -LiteralPath $targetPath -StopAt $normalizedCoreRoot `
      -Label ([string]$target.label))
    $targetItem = Get-Item -LiteralPath $targetPath -Force -ErrorAction Stop
    if ($targetItem.PSIsContainer -or
        ($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
      throw "$([string]$target.label) target must be one real file."
    }
    $targetDirectory = Split-Path -Parent $targetPath
    $targetLeaf = Split-Path -Leaf $targetPath
    foreach ($transactionKind in @('sealed', 'displaced', 'rollback')) {
      $staleTransactions = @(Get-ChildItem -LiteralPath $targetDirectory -Force `
          -Filter "$targetLeaf.stackchan-$transactionKind-*.tmp" -ErrorAction Stop)
      if ($staleTransactions.Count -gt 0) {
        throw "Refusing stale $([string]$target.label) transaction artifact: $($staleTransactions[0].FullName)"
      }
    }
    $backupPath = Assert-PathContained `
      -LiteralPath (Join-Path $normalizedBackupRoot ([string]$target.backupLeaf)) `
      -Root $normalizedBackupRoot -Label "$([string]$target.label) backup"
    [void](Assert-ExistingPathChainReal -LiteralPath $backupPath -StopAt $backupVolumeRoot `
      -Label "$([string]$target.label) backup")
    $actualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $targetPath).Hash
    if ($actualSha256 -ceq [string]$target.sealedSha256) {
      if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf) -or
          (Get-FileHash -Algorithm SHA256 -LiteralPath $backupPath).Hash -cne
            [string]$target.originalSha256) {
        throw "Sealed $([string]$target.label) is missing its exact private original-byte backup."
      }
      $alreadySealed.Add($targetPath) | Out-Null
      continue
    }
    if ($actualSha256 -cne [string]$target.originalSha256) {
      throw "Refusing unreviewed $([string]$target.label) bytes: $actualSha256"
    }

    $originalBytes = [IO.File]::ReadAllBytes($targetPath)
    if ((Get-BytesSha256 -Bytes $originalBytes) -cne [string]$target.originalSha256) {
      throw "$([string]$target.label) changed while its original bytes were read."
    }
    $sealedBytes = if ($target -is [Collections.IDictionary] -and
        $target.Contains('sealedBytes')) {
      [byte[]]$target.sealedBytes
    } else {
      Get-SealedTargetBytes -Mode ([string]$target.mode) -OriginalBytes $originalBytes
    }
    if ((Get-BytesSha256 -Bytes $sealedBytes) -cne [string]$target.sealedSha256) {
      throw "Generated $([string]$target.label) bytes do not match the reviewed sealed identity."
    }
    if (Test-Path -LiteralPath $backupPath) {
      $backupItem = Get-Item -LiteralPath $backupPath -Force -ErrorAction Stop
      if ($backupItem.PSIsContainer -or
          ($backupItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
          (Get-FileHash -Algorithm SHA256 -LiteralPath $backupPath).Hash -cne
            [string]$target.originalSha256) {
        throw "Private $([string]$target.label) backup is not the reviewed original file."
      }
    }
    $tempPath = Assert-PathContained `
      -LiteralPath "$targetPath.stackchan-sealed-$safeTransactionId.tmp" `
      -Root $normalizedCoreRoot -Label "$([string]$target.label) seal temporary"
    $displacedPath = Assert-PathContained `
      -LiteralPath "$targetPath.stackchan-displaced-$safeTransactionId.tmp" `
      -Root $normalizedCoreRoot -Label "$([string]$target.label) displaced temporary"
    $rollbackPath = Assert-PathContained `
      -LiteralPath "$targetPath.stackchan-rollback-$safeTransactionId.tmp" `
      -Root $normalizedCoreRoot -Label "$([string]$target.label) rollback temporary"
    foreach ($transactionPath in @($tempPath, $displacedPath, $rollbackPath)) {
      [void](Assert-ExistingPathChainReal -LiteralPath $transactionPath `
        -StopAt $normalizedCoreRoot -Label "$([string]$target.label) transaction path")
      if (Test-Path -LiteralPath $transactionPath) {
        throw "Refusing pre-existing seal transaction path for $([string]$target.label): $transactionPath"
      }
    }
    $plans.Add([pscustomobject][ordered]@{
        label = [string]$target.label
        targetPath = $targetPath
        backupPath = $backupPath
        tempPath = $tempPath
        displacedPath = $displacedPath
        rollbackPath = $rollbackPath
        originalBytes = $originalBytes
        originalSha256 = [string]$target.originalSha256
        sealedBytes = $sealedBytes
        sealedSha256 = [string]$target.sealedSha256
      }) | Out-Null
  }
  return [pscustomobject][ordered]@{
    coreRoot = $normalizedCoreRoot
    backupRoot = $normalizedBackupRoot
    backupVolumeRoot = $backupVolumeRoot
    plans = @($plans)
    alreadySealed = @($alreadySealed)
  }
}

function Invoke-SealTargetTransaction {
  param(
    [Parameter(Mandatory = $true)]$PlanSet,
    [ValidateSet('none', 'prepare-second', 'install-second')]
    [string]$FailureInjection = 'none'
  )

  $plans = @($PlanSet.plans)
  if ($plans.Count -eq 0) {
    return [pscustomobject][ordered]@{
      status = 'already-sealed'
      plannedCount = 0
      installedCount = 0
      alreadySealedCount = @($PlanSet.alreadySealed).Count
      installedPaths = @()
    }
  }

  [void][IO.Directory]::CreateDirectory([string]$PlanSet.backupRoot)
  [void](Assert-ExistingPathChainReal -LiteralPath ([string]$PlanSet.backupRoot) `
    -StopAt ([string]$PlanSet.backupVolumeRoot) `
    -Label 'private toolchain backup root after creation')
  foreach ($plan in $plans) {
    if (-not (Test-Path -LiteralPath ([string]$plan.backupPath))) {
      [IO.File]::WriteAllBytes([string]$plan.backupPath, [byte[]]$plan.originalBytes)
    }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath ([string]$plan.backupPath)).Hash -cne
        [string]$plan.originalSha256) {
      throw "Private $([string]$plan.label) backup does not match the reviewed original bytes."
    }
  }

  $preparedPlans = [Collections.Generic.List[object]]::new()
  try {
    for ($index = 0; $index -lt $plans.Count; $index++) {
      $plan = $plans[$index]
      if ($FailureInjection -ceq 'prepare-second' -and $index -eq 1) {
        throw 'Injected second-target preparation failure.'
      }
      [IO.File]::WriteAllBytes([string]$plan.tempPath, [byte[]]$plan.sealedBytes)
      $preparedPlans.Add($plan) | Out-Null
      if ((Get-FileHash -Algorithm SHA256 -LiteralPath ([string]$plan.tempPath)).Hash -cne
          [string]$plan.sealedSha256) {
        throw "Temporary $([string]$plan.label) seal bytes changed before installation."
      }
    }
  } catch {
    foreach ($plan in $plans) {
      if (Test-Path -LiteralPath ([string]$plan.tempPath)) {
        Remove-Item -LiteralPath ([string]$plan.tempPath) -Force
      }
    }
    throw
  }

  $installedPlans = [object[]]::new($plans.Count)
  $installedCount = 0
  try {
    for ($index = 0; $index -lt $plans.Count; $index++) {
      $plan = $plans[$index]
      [IO.File]::Replace([string]$plan.tempPath, [string]$plan.targetPath,
        [string]$plan.displacedPath, $true)
      $installedPlans[$installedCount] = $plan
      $installedCount++
      if ($FailureInjection -ceq 'install-second' -and $index -eq 1) {
        throw 'Injected second-target installation failure.'
      }
      if ((Get-FileHash -Algorithm SHA256 -LiteralPath ([string]$plan.targetPath)).Hash -cne
          [string]$plan.sealedSha256) {
        throw "$([string]$plan.label) seal did not persist the reviewed bytes."
      }
      if ((Get-FileHash -Algorithm SHA256 -LiteralPath ([string]$plan.displacedPath)).Hash -cne
          [string]$plan.originalSha256) {
        throw "$([string]$plan.label) displaced bytes do not match the reviewed original."
      }
    }
  } catch {
    $installError = $_
    $rollbackFailures = [Collections.Generic.List[string]]::new()
    for ($index = $installedCount - 1; $index -ge 0; $index--) {
      $installedPlan = $installedPlans[$index]
      try {
        [IO.File]::Replace([string]$installedPlan.displacedPath,
          [string]$installedPlan.targetPath, [string]$installedPlan.rollbackPath, $true)
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath ([string]$installedPlan.targetPath)).Hash -cne
            [string]$installedPlan.originalSha256) {
          throw 'Rollback target does not match the reviewed original bytes.'
        }
        if ((Get-FileHash -Algorithm SHA256 -LiteralPath ([string]$installedPlan.rollbackPath)).Hash -cne
            [string]$installedPlan.sealedSha256) {
          throw 'Rollback-displaced target does not match the reviewed sealed bytes.'
        }
        Remove-Item -LiteralPath ([string]$installedPlan.rollbackPath) -Force
      } catch {
        $rollbackFailures.Add("$([string]$installedPlan.label): $($_.Exception.Message)") | Out-Null
      }
    }
    if ($rollbackFailures.Count -gt 0) {
      throw "Pioarduino seal failed and rollback was incomplete. Original error: $($installError.Exception.Message) Rollback: $($rollbackFailures -join '; ')"
    }
    throw $installError
  } finally {
    foreach ($plan in $plans) {
      if (Test-Path -LiteralPath ([string]$plan.tempPath)) {
        Remove-Item -LiteralPath ([string]$plan.tempPath) -Force
      }
    }
  }

  $installedPaths = [Collections.Generic.List[string]]::new()
  for ($index = 0; $index -lt $installedCount; $index++) {
    $installedPlan = $installedPlans[$index]
    Remove-Item -LiteralPath ([string]$installedPlan.displacedPath) -Force
    $installedPaths.Add([string]$installedPlan.targetPath) | Out-Null
  }
  return [pscustomobject][ordered]@{
    status = 'pass'
    plannedCount = $plans.Count
    installedCount = $installedCount
    alreadySealedCount = @($PlanSet.alreadySealed).Count
    installedPaths = @($installedPaths)
  }
}

function Test-NoSealTransactionArtifacts {
  param([Parameter(Mandatory = $true)][string]$CoreRoot)
  return @(Get-ChildItem -LiteralPath $CoreRoot -Recurse -Force -ErrorAction Stop |
      Where-Object { $_.Name -match '\.stackchan-(?:sealed|displaced|rollback)-.+\.tmp$' }).Count -eq 0
}

function Assert-SelfTestCondition {
  param([bool]$Condition, [Parameter(Mandatory = $true)][string]$Message)
  if (-not $Condition) { throw $Message }
}

function New-SyntheticTargets {
  $definitions = [Collections.Generic.List[object]]::new()
  foreach ($entry in @(
      [ordered]@{ label = 'synthetic one'; relative = 'builder/one.txt';
        original = "synthetic-one-original`n"; sealed = "synthetic-one-sealed`n" },
      [ordered]@{ label = 'synthetic two'; relative = 'builder/frameworks/two.txt';
        original = "synthetic-two-original`n"; sealed = "synthetic-two-sealed`n" }
    )) {
    $originalBytes = $utf8.GetBytes([string]$entry.original)
    $sealedBytes = $utf8.GetBytes([string]$entry.sealed)
    $originalSha256 = Get-BytesSha256 -Bytes $originalBytes
    $leaf = Split-Path -Leaf ([string]$entry.relative)
    $definitions.Add([ordered]@{
        label = [string]$entry.label
        relative = [string]$entry.relative
        originalSha256 = $originalSha256
        sealedSha256 = Get-BytesSha256 -Bytes $sealedBytes
        backupLeaf = "$leaf.$originalSha256.bak"
        sealedBytes = $sealedBytes
        originalBytes = $originalBytes
      }) | Out-Null
  }
  return @($definitions)
}

function New-SyntheticScenario {
  param(
    [Parameter(Mandatory = $true)][string]$SelfTestRoot,
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][object[]]$Targets
  )
  $root = Join-Path $SelfTestRoot $Name
  $coreRoot = Join-Path $root 'core'
  $backupAuthorityRoot = Join-Path $root 'authority'
  $backupRoot = Join-Path $backupAuthorityRoot 'private/backups'
  [void][IO.Directory]::CreateDirectory($coreRoot)
  [void][IO.Directory]::CreateDirectory($backupAuthorityRoot)
  foreach ($target in $Targets) {
    $targetPath = Join-Path $coreRoot ([string]$target.relative)
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $targetPath))
    [IO.File]::WriteAllBytes($targetPath, [byte[]]$target.originalBytes)
  }
  return [pscustomobject][ordered]@{
    root = $root
    coreRoot = $coreRoot
    backupAuthorityRoot = $backupAuthorityRoot
    backupRoot = $backupRoot
  }
}

function Test-SyntheticTargetHashes {
  param(
    [Parameter(Mandatory = $true)]$Scenario,
    [Parameter(Mandatory = $true)][object[]]$Targets,
    [Parameter(Mandatory = $true)][ValidateSet('original', 'sealed')][string]$State
  )
  foreach ($target in $Targets) {
    $expected = if ($State -ceq 'original') {
      [string]$target.originalSha256
    } else {
      [string]$target.sealedSha256
    }
    $path = Join-Path ([string]$Scenario.coreRoot) ([string]$target.relative)
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash -cne $expected) {
      return $false
    }
  }
  return $true
}

function Test-SyntheticBackups {
  param(
    [Parameter(Mandatory = $true)]$Scenario,
    [Parameter(Mandatory = $true)][object[]]$Targets
  )
  foreach ($target in $Targets) {
    $path = Join-Path ([string]$Scenario.backupRoot) ([string]$target.backupLeaf)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
        (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash -cne
          [string]$target.originalSha256) {
      return $false
    }
  }
  return $true
}

function Invoke-SealSelfTest {
  $systemTempRoot = Get-NormalizedFullPath -LiteralPath ([IO.Path]::GetTempPath())
  $systemTempVolumeRoot = Get-PathVolumeRoot -LiteralPath $systemTempRoot
  [void](Assert-ExistingPathChainReal -LiteralPath $systemTempRoot `
    -StopAt $systemTempVolumeRoot -Label 'system temporary root ancestry')
  $selfTestRoot = Join-Path $systemTempRoot `
    "stackchan-pioarduino-seal-selftest-$PID-$([guid]::NewGuid().ToString('N'))"
  if (Test-Path -LiteralPath $selfTestRoot) {
    throw "Synthetic seal self-test root already exists: $selfTestRoot"
  }
  [void][IO.Directory]::CreateDirectory($selfTestRoot)
  $selfTestRoot = Assert-PathContained -LiteralPath $selfTestRoot `
    -Root $systemTempRoot -Label 'synthetic seal self-test root'
  [void](Assert-ExistingPathChainReal -LiteralPath $selfTestRoot `
    -StopAt $systemTempVolumeRoot -Label 'synthetic seal self-test root ancestry')
  $targets = @(New-SyntheticTargets)
  $record = $null
  try {
    $prep = New-SyntheticScenario -SelfTestRoot $selfTestRoot -Name 'prep-failure' `
      -Targets $targets
    $prepPlan = New-SealTransactionPlanSet -CoreRoot $prep.coreRoot `
      -BackupRoot $prep.backupRoot -BackupAuthorityRoot $prep.backupAuthorityRoot `
      -Targets $targets -TransactionId 'selftest-prep'
    $prepFailureObserved = $false
    try {
      [void](Invoke-SealTargetTransaction -PlanSet $prepPlan `
        -FailureInjection 'prepare-second')
    } catch {
      $prepFailureObserved = $_.Exception.Message -match 'Injected second-target preparation failure'
    }
    Assert-SelfTestCondition $prepFailureObserved 'Synthetic preparation failure was not observed.'
    Assert-SelfTestCondition (Test-SyntheticTargetHashes -Scenario $prep -Targets $targets `
        -State original) 'Preparation failure changed a synthetic target.'
    Assert-SelfTestCondition (Test-NoSealTransactionArtifacts -CoreRoot $prep.coreRoot) `
      'Preparation failure left a transaction artifact.'

    $rollback = New-SyntheticScenario -SelfTestRoot $selfTestRoot -Name 'install-rollback' `
      -Targets $targets
    $rollbackPlan = New-SealTransactionPlanSet -CoreRoot $rollback.coreRoot `
      -BackupRoot $rollback.backupRoot -BackupAuthorityRoot $rollback.backupAuthorityRoot `
      -Targets $targets -TransactionId 'selftest-rollback'
    $installFailureObserved = $false
    try {
      [void](Invoke-SealTargetTransaction -PlanSet $rollbackPlan `
        -FailureInjection 'install-second')
    } catch {
      $installFailureObserved = $_.Exception.Message -match 'Injected second-target installation failure'
    }
    Assert-SelfTestCondition $installFailureObserved 'Synthetic installation failure was not observed.'
    Assert-SelfTestCondition (Test-SyntheticTargetHashes -Scenario $rollback -Targets $targets `
        -State original) 'Installation rollback did not restore both synthetic targets.'
    Assert-SelfTestCondition (Test-NoSealTransactionArtifacts -CoreRoot $rollback.coreRoot) `
      'Installation rollback left a transaction artifact.'
    Assert-SelfTestCondition (Test-SyntheticBackups -Scenario $rollback -Targets $targets) `
      'Installation rollback did not retain exact synthetic original backups.'

    $success = New-SyntheticScenario -SelfTestRoot $selfTestRoot -Name 'success-idempotence' `
      -Targets $targets
    $successPlan = New-SealTransactionPlanSet -CoreRoot $success.coreRoot `
      -BackupRoot $success.backupRoot -BackupAuthorityRoot $success.backupAuthorityRoot `
      -Targets $targets -TransactionId 'selftest-success'
    $successResult = Invoke-SealTargetTransaction -PlanSet $successPlan
    Assert-SelfTestCondition ($successResult.status -ceq 'pass' -and
        [int]$successResult.installedCount -eq 2) `
      'Synthetic success did not install exactly two targets.'
    Assert-SelfTestCondition (Test-SyntheticTargetHashes -Scenario $success -Targets $targets `
        -State sealed) 'Synthetic success did not persist both sealed targets.'
    Assert-SelfTestCondition (Test-SyntheticBackups -Scenario $success -Targets $targets) `
      'Synthetic success did not retain exact original backups.'
    Assert-SelfTestCondition (Test-NoSealTransactionArtifacts -CoreRoot $success.coreRoot) `
      'Synthetic success left a transaction artifact.'
    $idempotentPlan = New-SealTransactionPlanSet -CoreRoot $success.coreRoot `
      -BackupRoot $success.backupRoot -BackupAuthorityRoot $success.backupAuthorityRoot `
      -Targets $targets -TransactionId 'selftest-idempotent'
    $idempotentResult = Invoke-SealTargetTransaction -PlanSet $idempotentPlan
    Assert-SelfTestCondition ($idempotentResult.status -ceq 'already-sealed' -and
        [int]$idempotentResult.alreadySealedCount -eq 2) `
      'Synthetic already-sealed run was not exactly idempotent.'

    $mixed = New-SyntheticScenario -SelfTestRoot $selfTestRoot -Name 'mixed-state' `
      -Targets $targets
    [void][IO.Directory]::CreateDirectory([string]$mixed.backupRoot)
    $firstTarget = $targets[0]
    [IO.File]::WriteAllBytes(
      (Join-Path $mixed.backupRoot ([string]$firstTarget.backupLeaf)),
      [byte[]]$firstTarget.originalBytes)
    [IO.File]::WriteAllBytes(
      (Join-Path $mixed.coreRoot ([string]$firstTarget.relative)),
      [byte[]]$firstTarget.sealedBytes)
    $mixedPlan = New-SealTransactionPlanSet -CoreRoot $mixed.coreRoot `
      -BackupRoot $mixed.backupRoot -BackupAuthorityRoot $mixed.backupAuthorityRoot `
      -Targets $targets -TransactionId 'selftest-mixed'
    Assert-SelfTestCondition (@($mixedPlan.plans).Count -eq 1 -and
        @($mixedPlan.alreadySealed).Count -eq 1) `
      'Synthetic mixed-state policy did not isolate exactly one unsealed target.'
    $mixedResult = Invoke-SealTargetTransaction -PlanSet $mixedPlan
    Assert-SelfTestCondition ($mixedResult.status -ceq 'pass' -and
        [int]$mixedResult.installedCount -eq 1 -and
        [int]$mixedResult.alreadySealedCount -eq 1) `
      'Synthetic mixed-state run did not seal exactly its original target.'
    Assert-SelfTestCondition (Test-SyntheticTargetHashes -Scenario $mixed -Targets $targets `
        -State sealed) 'Synthetic mixed-state run did not finish fully sealed.'
    Assert-SelfTestCondition (Test-SyntheticBackups -Scenario $mixed -Targets $targets) `
      'Synthetic mixed-state run did not retain exact original backups.'
    Assert-SelfTestCondition (Test-NoSealTransactionArtifacts -CoreRoot $mixed.coreRoot) `
      'Synthetic mixed-state run left a transaction artifact.'

    $stale = New-SyntheticScenario -SelfTestRoot $selfTestRoot -Name 'stale-preflight' `
      -Targets $targets
    $stalePath = (Join-Path $stale.coreRoot ([string]$targets[0].relative)) +
      '.stackchan-displaced-prior.tmp'
    [IO.File]::WriteAllBytes($stalePath, $utf8.GetBytes("synthetic-stale`n"))
    $staleRejected = $false
    try {
      [void](New-SealTransactionPlanSet -CoreRoot $stale.coreRoot `
        -BackupRoot $stale.backupRoot -BackupAuthorityRoot $stale.backupAuthorityRoot `
        -Targets $targets -TransactionId 'selftest-stale')
    } catch {
      $staleRejected = $_.Exception.Message -match 'Refusing stale synthetic one transaction artifact'
    }
    Assert-SelfTestCondition $staleRejected 'Synthetic stale artifact was not rejected.'
    Assert-SelfTestCondition (Test-SyntheticTargetHashes -Scenario $stale -Targets $targets `
        -State original) 'Stale-artifact preflight changed a synthetic target.'
    Assert-SelfTestCondition (-not (Test-Path -LiteralPath $stale.backupRoot)) `
      'Stale-artifact preflight wrote a backup before rejection.'
    Assert-SelfTestCondition (@(Get-ChildItem -LiteralPath $stale.coreRoot -Recurse -Force |
        Where-Object { $_.Name -match '\.stackchan-(?:sealed|displaced|rollback)-.+\.tmp$' }).Count -eq 1) `
      'Stale-artifact preflight wrote an additional transaction artifact.'

    $record = [pscustomobject][ordered]@{
      schema = 'stackchan.pioarduino-seal-selftest.v1'
      status = 'pass'
      usedSystemTemp = $true
      tempRootRemoved = $false
      scenarios = [ordered]@{
        preparationFailure = 'pass'
        secondInstallRollback = 'pass'
        successfulCommit = 'pass'
        alreadySealedIdempotence = 'pass'
        mixedState = 'pass'
        staleArtifactPreflight = 'pass'
      }
    }
  } finally {
    $validatedSelfTestRoot = Assert-PathContained -LiteralPath $selfTestRoot `
      -Root $systemTempRoot -Label 'synthetic seal self-test cleanup root'
    if (Test-Path -LiteralPath $validatedSelfTestRoot) {
      [IO.Directory]::Delete($validatedSelfTestRoot, $true)
    }
  }
  Assert-SelfTestCondition (-not (Test-Path -LiteralPath $selfTestRoot)) `
    'Synthetic seal self-test root was not removed.'
  $record.tempRootRemoved = $true
  return $record
}

if ($SelfTest) {
  $selfTestRecord = Invoke-SealSelfTest
  [Console]::Out.WriteLine(($selfTestRecord | ConvertTo-Json -Depth 6 -Compress))
  exit 0
}

$coreItem = Get-Item -LiteralPath $ReleaseCoreDir -Force -ErrorAction Stop
if (-not $coreItem.PSIsContainer -or
    ($coreItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
  throw 'ReleaseCoreDir must be one real PlatformIO core directory.'
}
$coreRoot = Get-NormalizedFullPath -LiteralPath $coreItem.FullName
$repoRoot = Get-NormalizedFullPath -LiteralPath (Split-Path -Parent $PSScriptRoot)
$backupRoot = Get-NormalizedFullPath -LiteralPath (
  Join-Path $repoRoot 'output/private/toolchain-backups')
$planSet = New-SealTransactionPlanSet -CoreRoot $coreRoot -BackupRoot $backupRoot `
  -BackupAuthorityRoot $repoRoot -Targets $targets -TransactionId ([string]$PID)
foreach ($sealedPath in @($planSet.alreadySealed)) {
  Write-Output "Pioarduino release-core target is already sealed: $sealedPath"
}
$transactionResult = Invoke-SealTargetTransaction -PlanSet $planSet
if ($transactionResult.status -ceq 'already-sealed') {
  Write-Output "Pioarduino release core is already sealed: $coreRoot"
  exit 0
}
foreach ($installedPath in @($transactionResult.installedPaths)) {
  Write-Output "Sealed pioarduino release-core target: $installedPath"
}
