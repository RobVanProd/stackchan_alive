Set-StrictMode -Version Latest

$script:StackchanToolchainIdentitySchema = 'stackchan.release-toolchain-identity.v3'
$script:StackchanToolchainInventorySchema = 'stackchan.byte-tree.v1'
$script:StackchanCanonicalLibdepsSchema = 'stackchan.canonical-libdeps.v1'
$script:StackchanCanonicalGitLibrarySchema = 'stackchan.canonical-git-library.v1'
$script:StackchanGitPackSemanticVerifierPath = Join-Path $PSScriptRoot 'verify_git_pack_semantics.py'

function Get-StackchanGitPackVerifierPython {
  $command = Get-Command -Name python -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($null -eq $command) {
    throw 'Git pack semantic verification requires an explicit Python application executable.'
  }
  return [IO.Path]::GetFullPath([string]$command.Source)
}

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
    [string]$PythonExecutable = (Get-StackchanGitPackVerifierPython)
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
    [string]$PythonExecutable = (Get-StackchanGitPackVerifierPython)
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

function Assert-StackchanReleaseBuildPythonEnvironment {
  param([Parameter(Mandatory = $true)][string]$ProjectRoot)

  $requiredEnvironment = [ordered]@{
    PYTHONNOUSERSITE = '1'
    PYTHONDONTWRITEBYTECODE = '1'
    PYTHONHASHSEED = '0'
    PYTHONUTF8 = '1'
    PYTHONIOENCODING = 'utf-8'
  }
  foreach ($entry in $requiredEnvironment.GetEnumerator()) {
    if ([Environment]::GetEnvironmentVariable(
        [string]$entry.Key, [EnvironmentVariableTarget]::Process) -cne [string]$entry.Value) {
      throw "Release build Python environment requires $($entry.Key)=$($entry.Value)."
    }
  }
  if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable(
      'PYTHONSAFEPATH', [EnvironmentVariableTarget]::Process))) {
    throw 'Release build Python environment requires PYTHONSAFEPATH to be unset so byte-identified PlatformIO tool packages can import their adjacent modules.'
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
      throw "Release build Python environment refuses ambient import/runtime override: $name"
    }
  }
  $project = Get-Item -LiteralPath $ProjectRoot -Force -ErrorAction Stop
  if (-not $project.PSIsContainer -or ($project.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw 'Release build project root is not one real directory.'
  }
  foreach ($name in @('.pth', '.egg-link', 'sitecustomize.py', 'usercustomize.py')) {
    if (Test-Path -LiteralPath (Join-Path $project.FullName $name)) {
      throw "Release build project root contains a Python import escape file: $name"
    }
  }
}

function New-StackchanToolchainLeaseState {
  $pathComparer = if ($env:OS -eq 'Windows_NT') {
    [StringComparer]::OrdinalIgnoreCase
  } else {
    [StringComparer]::Ordinal
  }
  return [pscustomobject][ordered]@{
    schema = 'stackchan.toolchain-lifetime-lease.v1'
    id = [guid]::NewGuid().ToString('N')
    streams = [Collections.Generic.Dictionary[string, object]]::new($pathComparer)
    watchers = [Collections.Generic.Dictionary[string, object]]::new($pathComparer)
    violation = $null
    violationEvidence = [Collections.Generic.List[object]]::new()
    preBuildVerified = $false
    preBuildComponents = @()
    preBuildAuthorityKey = $null
    preBuildScope = $null
    closed = $false
  }
}

function Copy-StackchanToolchainIdentityComponents {
  param([Parameter(Mandatory = $true)][object[]]$Components)

  return @($Components | ForEach-Object {
    [pscustomobject][ordered]@{
      name = [string]$_.name
      phase = [string]$_.phase
      identitySchema = [string]$_.identitySchema
      treeSha256 = [string]$_.treeSha256
      fileCount = [int]$_.fileCount
      bytes = [long]$_.bytes
    }
  })
}

function Get-StackchanToolchainPreBuildAuthorityKey {
  param(
    [Parameter(Mandatory = $true)][string]$AllowlistPath,
    [Parameter(Mandatory = $true)][hashtable]$RootMap,
    [Parameter(Mandatory = $true)][string]$PlatformKey,
    [Parameter(Mandatory = $true)][string]$PlatformioExecutable,
    [Parameter(Mandatory = $true)][string]$PythonExecutable,
    [Parameter(Mandatory = $true)][string]$GitExecutable
  )

  $parts = [Collections.Generic.List[string]]::new()
  $parts.Add($PlatformKey) | Out-Null
  $parts.Add([IO.Path]::GetFullPath((Get-Item -LiteralPath $AllowlistPath -Force).FullName)) | Out-Null
  $parts.Add((Get-StackchanFileSha256 -LiteralPath $AllowlistPath)) | Out-Null
  foreach ($rootKey in @('pythonHome', 'gitHome', 'legacyCore', 'releaseCore')) {
    if (-not $RootMap.ContainsKey($rootKey) -or
        [string]::IsNullOrWhiteSpace([string]$RootMap[$rootKey])) {
      throw "Release toolchain cache authority is missing root: $rootKey"
    }
    $parts.Add([IO.Path]::GetFullPath((Get-Item -LiteralPath (
          [string]$RootMap[$rootKey]) -Force -ErrorAction Stop).FullName).TrimEnd('\', '/')) | Out-Null
  }
  foreach ($executable in @($PlatformioExecutable, $PythonExecutable, $GitExecutable)) {
    $parts.Add([IO.Path]::GetFullPath((Get-Item -LiteralPath $executable -Force -ErrorAction Stop).FullName)) | Out-Null
  }
  $comparisonText = if ($env:OS -eq 'Windows_NT') {
    (@($parts) | ForEach-Object { $_.ToUpperInvariant() }) -join "`0"
  } else {
    @($parts) -join "`0"
  }
  $hasher = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($hasher.ComputeHash(
      [Text.Encoding]::UTF8.GetBytes("stackchan.prebuild-authority.v1`n$comparisonText`n"))) -replace '-', '').ToUpperInvariant()
  } finally {
    $hasher.Dispose()
  }
}

function Assert-StackchanToolchainLeaseState {
  param([Parameter(Mandatory = $true)]$LeaseState)

  if ([string]$LeaseState.schema -cne 'stackchan.toolchain-lifetime-lease.v1' -or
      [bool]$LeaseState.closed) {
    throw 'Release toolchain lifetime lease state is invalid or already closed.'
  }
}

function Add-StackchanToolchainFileLease {
  param(
    [Parameter(Mandatory = $true)]$LeaseState,
    [Parameter(Mandatory = $true)][string]$LiteralPath,
    [Parameter(Mandatory = $true)][string]$Scope
  )

  Assert-StackchanToolchainLeaseState -LeaseState $LeaseState
  if ([string]::IsNullOrWhiteSpace($Scope)) {
    throw 'Release toolchain file leases require a non-empty scope.'
  }
  $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
  if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "Release toolchain lifetime lease refuses a non-file or redirected path: $LiteralPath"
  }
  $fullPath = [IO.Path]::GetFullPath($item.FullName)
  if ($LeaseState.streams.ContainsKey($fullPath)) { return }
  $stream = [IO.FileStream]::new(
    $fullPath,
    [IO.FileMode]::Open,
    [IO.FileAccess]::Read,
    [IO.FileShare]::Read,
    4096,
    [IO.FileOptions]::SequentialScan)
  try {
    $LeaseState.streams.Add($fullPath, [pscustomobject][ordered]@{
      path = $fullPath
      scope = $Scope
      stream = $stream
    })
  } catch {
    $stream.Dispose()
    throw
  }
}

function Add-StackchanToolchainTreeWatcher {
  param(
    [Parameter(Mandatory = $true)]$LeaseState,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Scope
  )

  Assert-StackchanToolchainLeaseState -LeaseState $LeaseState
  $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
  if (-not $rootItem.PSIsContainer -or
      ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "Release toolchain lifetime watcher requires one real directory: $Root"
  }
  $resolvedRoot = [IO.Path]::GetFullPath($rootItem.FullName).TrimEnd('\', '/')
  if ($LeaseState.watchers.ContainsKey($resolvedRoot)) { return }

  $watcher = [IO.FileSystemWatcher]::new($resolvedRoot, '*')
  $sourceIdentifiers = [Collections.Generic.List[string]]::new()
  try {
    $watcher.IncludeSubdirectories = $true
    $watcher.InternalBufferSize = 65536
    $watcher.NotifyFilter = (
      [IO.NotifyFilters]::FileName -bor [IO.NotifyFilters]::DirectoryName -bor
      [IO.NotifyFilters]::LastWrite -bor [IO.NotifyFilters]::Size -bor
      [IO.NotifyFilters]::CreationTime -bor [IO.NotifyFilters]::Attributes -bor
      [IO.NotifyFilters]::Security)
    foreach ($eventName in @('Changed', 'Created', 'Deleted', 'Renamed', 'Error')) {
      $sourceIdentifier = "stackchan-toolchain-$($LeaseState.id)-$([guid]::NewGuid().ToString('N'))-$eventName"
      [void](Microsoft.PowerShell.Utility\Register-ObjectEvent `
        -InputObject $watcher -EventName $eventName -SourceIdentifier $sourceIdentifier)
      $sourceIdentifiers.Add($sourceIdentifier) | Out-Null
    }
    $LeaseState.watchers.Add($resolvedRoot, [pscustomobject][ordered]@{
      root = $resolvedRoot
      scope = $Scope
      watcher = $watcher
      sourceIdentifiers = @($sourceIdentifiers)
      baselineNamespaceSha256 = $null
    })
    $watcher.EnableRaisingEvents = $true
  } catch {
    foreach ($sourceIdentifier in $sourceIdentifiers) {
      Microsoft.PowerShell.Utility\Unregister-Event `
        -SourceIdentifier $sourceIdentifier -ErrorAction SilentlyContinue
      Microsoft.PowerShell.Utility\Remove-Event `
        -SourceIdentifier $sourceIdentifier -ErrorAction SilentlyContinue
    }
    $watcher.Dispose()
    throw
  }
}

function Get-StackchanToolchainNamespaceSha256 {
  param([Parameter(Mandatory = $true)][string]$Root)

  $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
  if (-not $rootItem.PSIsContainer -or
      ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "Release toolchain namespace root is not one real directory: $Root"
  }
  $rootPath = $rootItem.FullName.TrimEnd('\', '/')
  $queue = [Collections.Generic.Queue[object]]::new()
  $queue.Enqueue([pscustomobject]@{ item = $rootItem; relative = '' })
  $records = [Collections.Generic.List[string]]::new()
  while ($queue.Count -gt 0) {
    $current = $queue.Dequeue()
    foreach ($item in @(Get-ChildItem -LiteralPath $current.item.FullName -Force -ErrorAction Stop)) {
      if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Release toolchain namespace refuses reparse points: $($item.FullName)"
      }
      $relative = if ([string]::IsNullOrEmpty([string]$current.relative)) {
        [string]$item.Name
      } else {
        [string]$current.relative + '/' + [string]$item.Name
      }
      $relative = ConvertTo-StackchanSafeIdentityRelativePath $relative
      if ($item.PSIsContainer) {
        $records.Add("D`0$relative") | Out-Null
        $queue.Enqueue([pscustomobject]@{ item = $item; relative = $relative })
      } elseif ($item -is [IO.FileInfo]) {
        $records.Add("F`0$relative") | Out-Null
      } else {
        throw "Unsupported release toolchain namespace entry: $($item.FullName)"
      }
    }
  }
  $ordered = [string[]]@($records)
  [Array]::Sort($ordered, [StringComparer]::Ordinal)
  $namespaceText = "stackchan.toolchain-namespace.v1`n" + (($ordered | ForEach-Object { "$_`n" }) -join '')
  $hasher = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($hasher.ComputeHash(
      [Text.Encoding]::UTF8.GetBytes($namespaceText))) -replace '-', '').ToUpperInvariant()
  } finally {
    $hasher.Dispose()
  }
}

function Set-StackchanToolchainTreeWatcherBaseline {
  param(
    [Parameter(Mandatory = $true)]$LeaseState,
    [Parameter(Mandatory = $true)][string]$Root
  )

  Assert-StackchanToolchainLeaseState -LeaseState $LeaseState
  $resolvedRoot = [IO.Path]::GetFullPath((Get-Item -LiteralPath $Root -Force -ErrorAction Stop).FullName).
    TrimEnd('\', '/')
  if (-not $LeaseState.watchers.ContainsKey($resolvedRoot)) {
    throw "Release toolchain namespace has no active watcher: $resolvedRoot"
  }
  $record = $LeaseState.watchers[$resolvedRoot]
  if ([string]::IsNullOrWhiteSpace([string]$record.baselineNamespaceSha256)) {
    $record.baselineNamespaceSha256 = Get-StackchanToolchainNamespaceSha256 -Root $resolvedRoot
  }
}

function Get-StackchanToolchainEventPathMetadata {
  param([string]$LiteralPath)

  $metadata = [ordered]@{
    observedUtc = (Get-Date).ToUniversalTime().ToString('o')
    path = $LiteralPath
    exists = $false
    isContainer = $null
    length = $null
    attributes = $null
    creationTimeUtc = $null
    lastWriteTimeUtc = $null
    lastAccessTimeUtc = $null
    accessSddl = $null
    error = $null
  }
  if ([string]::IsNullOrWhiteSpace($LiteralPath)) {
    return [pscustomobject]$metadata
  }
  try {
    if (-not (Test-Path -LiteralPath $LiteralPath)) {
      return [pscustomobject]$metadata
    }
    $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
    $metadata.exists = $true
    $metadata.isContainer = [bool]$item.PSIsContainer
    if (-not $item.PSIsContainer -and $item -is [IO.FileInfo]) {
      $metadata.length = [long]$item.Length
    }
    $metadata.attributes = [string]$item.Attributes
    $metadata.creationTimeUtc = $item.CreationTimeUtc.ToString('o')
    $metadata.lastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
    $metadata.lastAccessTimeUtc = $item.LastAccessTimeUtc.ToString('o')
    try {
      $acl = Get-Acl -LiteralPath $item.FullName -ErrorAction Stop
      $sections = [Security.AccessControl.AccessControlSections]::Access -bor
        [Security.AccessControl.AccessControlSections]::Owner -bor
        [Security.AccessControl.AccessControlSections]::Group
      $metadata.accessSddl = $acl.GetSecurityDescriptorSddlForm($sections)
    } catch {
      $metadata.error = "ACL: $($_.Exception.Message)"
    }
  } catch {
    $metadata.error = $_.Exception.Message
  }
  return [pscustomobject]$metadata
}

function Add-StackchanToolchainQueuedEventEvidence {
  param([Parameter(Mandatory = $true)]$LeaseState)

  # Snapshot every watcher subscription before recording anything so evidence
  # is ordered across the entire guarded state, rather than once per root.
  # Events delivered after this snapshot remain queued for the next drain.
  $queued = [Collections.Generic.List[object]]::new()
  foreach ($watchRecord in @($LeaseState.watchers.Values)) {
    foreach ($sourceIdentifier in @($watchRecord.sourceIdentifiers)) {
      foreach ($eventRecord in @(Microsoft.PowerShell.Utility\Get-Event `
            -SourceIdentifier $sourceIdentifier -ErrorAction SilentlyContinue)) {
        $queued.Add([pscustomobject][ordered]@{
          sourceIdentifier = [string]$sourceIdentifier
          watchRecord = $watchRecord
          eventRecord = $eventRecord
        }) | Out-Null
      }
    }
  }
  if ($queued.Count -eq 0) { return 0 }

  $orderedEvents = @($queued | Sort-Object `
      @{ Expression = { [datetime]$_.eventRecord.TimeGenerated } },
      @{ Expression = { [long]$_.eventRecord.EventIdentifier } },
      @{ Expression = { [string]$_.sourceIdentifier } })
  foreach ($queuedRecord in $orderedEvents) {
    $eventRecord = $queuedRecord.eventRecord
    $watchRecord = $queuedRecord.watchRecord
    $eventArgs = $eventRecord.SourceEventArgs
    $sourceIdentifier = [string]$queuedRecord.sourceIdentifier
    $registeredEventName = if ($sourceIdentifier -match '-(Changed|Created|Deleted|Renamed|Error)$') {
      [string]$Matches[1]
    } else {
      'Unknown'
    }
    $changeType = if ($null -ne $eventArgs -and
        $null -ne $eventArgs.PSObject.Properties['ChangeType']) {
      [string]$eventArgs.ChangeType
    } else {
      $registeredEventName
    }
    $fullPath = if ($null -ne $eventArgs -and
        $null -ne $eventArgs.PSObject.Properties['FullPath']) {
      [string]$eventArgs.FullPath
    } else {
      [string]$watchRecord.root
    }
    $name = if ($null -ne $eventArgs -and
        $null -ne $eventArgs.PSObject.Properties['Name']) {
      [string]$eventArgs.Name
    } else { $null }
    $oldFullPath = if ($null -ne $eventArgs -and
        $null -ne $eventArgs.PSObject.Properties['OldFullPath']) {
      [string]$eventArgs.OldFullPath
    } else { $null }
    $oldName = if ($null -ne $eventArgs -and
        $null -ne $eventArgs.PSObject.Properties['OldName']) {
      [string]$eventArgs.OldName
    } else { $null }
    $eventException = $null
    if ($registeredEventName -ceq 'Error' -and $null -ne $eventArgs) {
      try { $eventException = $eventArgs.GetException() } catch {}
    }
    $timeGeneratedUtc = ([datetime]$eventRecord.TimeGenerated).ToUniversalTime().ToString('o')
    $observedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $evidence = [pscustomobject][ordered]@{
      schema = 'stackchan.toolchain-watcher-event.v1'
      ordinal = $LeaseState.violationEvidence.Count
      eventIdentifier = [long]$eventRecord.EventIdentifier
      sourceIdentifier = $sourceIdentifier
      registeredEventName = $registeredEventName
      changeType = $changeType
      timeGeneratedUtc = $timeGeneratedUtc
      observedUtc = $observedUtc
      watcherRoot = [string]$watchRecord.root
      watcherScope = [string]$watchRecord.scope
      watcherNotifyFilter = [string]$watchRecord.watcher.NotifyFilter
      fullPath = $fullPath
      name = $name
      oldFullPath = $oldFullPath
      oldName = $oldName
      errorType = if ($null -eq $eventException) { $null } else { $eventException.GetType().FullName }
      errorMessage = if ($null -eq $eventException) { $null } else { $eventException.Message }
      pathMetadata = Get-StackchanToolchainEventPathMetadata -LiteralPath $fullPath
      oldPathMetadata = Get-StackchanToolchainEventPathMetadata -LiteralPath $oldFullPath
      watcherRootMetadata = Get-StackchanToolchainEventPathMetadata -LiteralPath ([string]$watchRecord.root)
      queueRemovalSucceeded = $false
      queueRemovalError = $null
    }
    $LeaseState.violationEvidence.Add($evidence) | Out-Null
    try {
      Microsoft.PowerShell.Utility\Remove-Event `
        -EventIdentifier ([int]$eventRecord.EventIdentifier) -ErrorAction Stop
      $evidence.queueRemovalSucceeded = $true
    } catch {
      $evidence.queueRemovalError = $_.Exception.Message
    }
  }
  $cumulativeEvidence = @($LeaseState.violationEvidence | Sort-Object `
      @{ Expression = { [datetime]$_.timeGeneratedUtc } },
      @{ Expression = { [long]$_.eventIdentifier } },
      @{ Expression = { [string]$_.sourceIdentifier } })
  $LeaseState.violationEvidence.Clear()
  for ($ordinal = 0; $ordinal -lt $cumulativeEvidence.Count; $ordinal++) {
    $cumulativeEvidence[$ordinal].ordinal = $ordinal
    $LeaseState.violationEvidence.Add($cumulativeEvidence[$ordinal]) | Out-Null
  }
  $firstEvidence = $LeaseState.violationEvidence[0]
  $firstSummary = "$([string]$firstEvidence.registeredEventName)/$([string]$firstEvidence.changeType) " +
    "at $([string]$firstEvidence.fullPath) generatedUtc=$([string]$firstEvidence.timeGeneratedUtc)"
  if ([string]::IsNullOrWhiteSpace([string]$LeaseState.violation) -or
      [string]$LeaseState.violation -like 'filesystem watcher events=*') {
    $LeaseState.violation = "filesystem watcher events=$($LeaseState.violationEvidence.Count) first=$firstSummary"
  }
  return $orderedEvents.Count
}

function Complete-StackchanToolchainQueuedEventDrain {
  param(
    [Parameter(Mandatory = $true)]$LeaseState,
    [ValidateRange(1, 20)][int]$RequiredQuietPasses = 3,
    [ValidateRange(1, 100)][int]$MaximumPasses = 40,
    [ValidateRange(1, 1000)][int]$DelayMilliseconds = 25
  )

  $quietPasses = 0
  $drainedEvents = 0
  for ($pass = 1; $pass -le $MaximumPasses; $pass++) {
    [Threading.Thread]::Sleep($DelayMilliseconds)
    $drained = Add-StackchanToolchainQueuedEventEvidence -LeaseState $LeaseState
    $drainedEvents += $drained
    if ($drained -eq 0) {
      $quietPasses++
      if ($quietPasses -ge $RequiredQuietPasses) { return $drainedEvents }
    } else {
      $quietPasses = 0
    }
  }

  $quiescenceFailure = "watcher event queue did not quiesce after $MaximumPasses passes"
  if ([string]::IsNullOrWhiteSpace([string]$LeaseState.violation)) {
    $LeaseState.violation = $quiescenceFailure
  } elseif ([string]$LeaseState.violation -notlike "*$quiescenceFailure*") {
    $LeaseState.violation = "$($LeaseState.violation); $quiescenceFailure"
  }
  return $drainedEvents
}

function Assert-StackchanToolchainLeaseStateUnchanged {
  param(
    [Parameter(Mandatory = $true)]$LeaseState,
    [Parameter(Mandatory = $true)][string]$Context,
    [switch]$VerifyNamespace
  )

  Assert-StackchanToolchainLeaseState -LeaseState $LeaseState
  # FileSystemWatcher delivery is asynchronous. Existing inputs cannot be
  # changed because their read leases deny write/delete sharing; this short
  # drain interval makes transient new-path events observable before success.
  [Threading.Thread]::Sleep(50)
  foreach ($watchRecord in @($LeaseState.watchers.Values)) {
    if (-not [bool]$watchRecord.watcher.EnableRaisingEvents) {
      if ([string]::IsNullOrWhiteSpace([string]$LeaseState.violation)) {
        $LeaseState.violation = "watcher disabled for $([string]$watchRecord.root)"
      }
    }
    foreach ($sourceIdentifier in @($watchRecord.sourceIdentifiers)) {
      $subscribers = @(Microsoft.PowerShell.Utility\Get-EventSubscriber `
        -SourceIdentifier $sourceIdentifier -ErrorAction SilentlyContinue)
      if ($subscribers.Count -ne 1) {
        if ([string]::IsNullOrWhiteSpace([string]$LeaseState.violation)) {
          $LeaseState.violation = "watcher subscription missing for $([string]$watchRecord.root)"
        }
      }
    }
  }
  [void](Add-StackchanToolchainQueuedEventEvidence -LeaseState $LeaseState)
  foreach ($watchRecord in @($LeaseState.watchers.Values)) {
    if ($VerifyNamespace -and
        [string]::IsNullOrWhiteSpace([string]$LeaseState.violation)) {
      if ([string]::IsNullOrWhiteSpace([string]$watchRecord.baselineNamespaceSha256)) {
        $LeaseState.violation = "watcher namespace baseline missing for $([string]$watchRecord.root)"
        throw "Release toolchain changed after authentication during $Context`: $($LeaseState.violation)"
      }
      $actualNamespace = Get-StackchanToolchainNamespaceSha256 -Root ([string]$watchRecord.root)
      if ($actualNamespace -cne [string]$watchRecord.baselineNamespaceSha256) {
        $LeaseState.violation = "namespace drift at $([string]$watchRecord.root)"
        throw "Release toolchain changed after authentication during $Context`: $($LeaseState.violation)"
      }
    }
  }
  if (-not [string]::IsNullOrWhiteSpace([string]$LeaseState.violation)) {
    throw "Release toolchain changed after authentication during $Context`: $($LeaseState.violation)"
  }
  if ($VerifyNamespace) {
    Assert-StackchanToolchainLeaseStateUnchanged `
      -LeaseState $LeaseState -Context "$Context post-namespace event drain"
  }
}

function Close-StackchanToolchainLeaseScope {
  param(
    [Parameter(Mandatory = $true)]$LeaseState,
    [Parameter(Mandatory = $true)][string]$Scope,
    [switch]$RequireUnchanged,
    [string]$Context = 'toolchain lease scope closure'
  )

  Assert-StackchanToolchainLeaseState -LeaseState $LeaseState
  if ($RequireUnchanged) {
    Assert-StackchanToolchainLeaseStateUnchanged `
      -LeaseState $LeaseState -Context $Context -VerifyNamespace
  }
  $closingWatchers = @($LeaseState.watchers.Values | Where-Object {
    [string]$_.scope -ceq $Scope
  })
  foreach ($record in $closingWatchers) {
    $record.watcher.EnableRaisingEvents = $false
  }
  if ($closingWatchers.Count -gt 0) {
    [void](Complete-StackchanToolchainQueuedEventDrain -LeaseState $LeaseState)
  }
  foreach ($record in $closingWatchers) {
    foreach ($sourceIdentifier in @($record.sourceIdentifiers)) {
      Microsoft.PowerShell.Utility\Unregister-Event `
        -SourceIdentifier $sourceIdentifier -ErrorAction SilentlyContinue
    }
  }
  if ($closingWatchers.Count -gt 0) {
    [void](Complete-StackchanToolchainQueuedEventDrain -LeaseState $LeaseState)
  }
  foreach ($root in @($LeaseState.watchers.Keys)) {
    $record = $LeaseState.watchers[$root]
    if ([string]$record.scope -cne $Scope) { continue }
    foreach ($sourceIdentifier in @($record.sourceIdentifiers)) {
      Microsoft.PowerShell.Utility\Remove-Event `
        -SourceIdentifier $sourceIdentifier -ErrorAction SilentlyContinue
    }
    $record.watcher.Dispose()
    [void]$LeaseState.watchers.Remove($root)
  }
  foreach ($path in @($LeaseState.streams.Keys)) {
    $record = $LeaseState.streams[$path]
    if ([string]$record.scope -cne $Scope) { continue }
    $record.stream.Dispose()
    [void]$LeaseState.streams.Remove($path)
  }
  if ([string]$LeaseState.preBuildScope -ceq $Scope) {
    $LeaseState.preBuildVerified = $false
    $LeaseState.preBuildComponents = @()
    $LeaseState.preBuildAuthorityKey = $null
    $LeaseState.preBuildScope = $null
  }
  if ($RequireUnchanged -and
      -not [string]::IsNullOrWhiteSpace([string]$LeaseState.violation)) {
    throw "Release toolchain changed during guarded scope closure: $($LeaseState.violation)"
  }
}

function Close-StackchanToolchainLeaseState {
  param(
    [Parameter(Mandatory = $true)]$LeaseState,
    [switch]$RequireUnchanged,
    [string]$Context = 'toolchain lease state closure'
  )

  if ([bool]$LeaseState.closed) { return }
  if ($RequireUnchanged) {
    Assert-StackchanToolchainLeaseStateUnchanged `
      -LeaseState $LeaseState -Context $Context -VerifyNamespace
  }
  foreach ($record in @($LeaseState.watchers.Values)) {
    $record.watcher.EnableRaisingEvents = $false
  }
  if ($LeaseState.watchers.Count -gt 0) {
    [void](Complete-StackchanToolchainQueuedEventDrain -LeaseState $LeaseState)
  }
  foreach ($record in @($LeaseState.watchers.Values)) {
    foreach ($sourceIdentifier in @($record.sourceIdentifiers)) {
      Microsoft.PowerShell.Utility\Unregister-Event `
        -SourceIdentifier $sourceIdentifier -ErrorAction SilentlyContinue
    }
  }
  if ($LeaseState.watchers.Count -gt 0) {
    [void](Complete-StackchanToolchainQueuedEventDrain -LeaseState $LeaseState)
  }
  foreach ($record in @($LeaseState.watchers.Values)) {
    foreach ($sourceIdentifier in @($record.sourceIdentifiers)) {
      Microsoft.PowerShell.Utility\Remove-Event `
        -SourceIdentifier $sourceIdentifier -ErrorAction SilentlyContinue
    }
    $record.watcher.Dispose()
  }
  foreach ($record in @($LeaseState.streams.Values)) {
    $record.stream.Dispose()
  }
  $LeaseState.watchers.Clear()
  $LeaseState.streams.Clear()
  $LeaseState.preBuildVerified = $false
  $LeaseState.preBuildComponents = @()
  $LeaseState.preBuildAuthorityKey = $null
  $LeaseState.preBuildScope = $null
  $LeaseState.closed = $true
  if ($RequireUnchanged -and
      -not [string]::IsNullOrWhiteSpace([string]$LeaseState.violation)) {
    throw "Release toolchain changed during guarded state closure: $($LeaseState.violation)"
  }
}

function Protect-StackchanToolchainTree {
  param(
    [Parameter(Mandatory = $true)]$LeaseState,
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Scope
  )

  Add-StackchanToolchainTreeWatcher -LeaseState $LeaseState -Root $Root -Scope $Scope
  $queue = [Collections.Generic.Queue[object]]::new()
  $rootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
  $queue.Enqueue($rootItem)
  while ($queue.Count -gt 0) {
    $current = $queue.Dequeue()
    foreach ($item in @(Get-ChildItem -LiteralPath $current.FullName -Force -ErrorAction Stop)) {
      if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Release toolchain lifetime lease refuses reparse points: $($item.FullName)"
      }
      if ($item.PSIsContainer) {
        $queue.Enqueue($item)
      } elseif ($item -is [IO.FileInfo]) {
        Add-StackchanToolchainFileLease `
          -LeaseState $LeaseState -LiteralPath $item.FullName -Scope $Scope
      } else {
        throw "Unsupported release toolchain lease entry: $($item.FullName)"
      }
    }
  }
  Set-StackchanToolchainTreeWatcherBaseline `
    -LeaseState $LeaseState -Root $rootItem.FullName
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
    [switch]$IncludeRecords,
    $LeaseState,
    [string]$LeaseScope
  )

  if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    throw "Toolchain identity root is missing: $Root"
  }
  $resolvedRootItem = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
  if ($resolvedRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw "Toolchain identity refuses a reparse-point root: $Root"
  }
  $resolvedRoot = $resolvedRootItem.FullName.TrimEnd('\', '/')
  if ($null -ne $LeaseState) {
    Add-StackchanToolchainTreeWatcher `
      -LeaseState $LeaseState -Root $resolvedRoot -Scope $LeaseScope
  }
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
        if ($null -ne $LeaseState) {
          Add-StackchanToolchainFileLease `
            -LeaseState $LeaseState -LiteralPath $item.FullName -Scope $LeaseScope
        }
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

  if ($null -ne $LeaseState) {
    Set-StackchanToolchainTreeWatcherBaseline `
      -LeaseState $LeaseState -Root $resolvedRoot
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
  param(
    [Parameter(Mandatory = $true)][string]$PackRoot,
    [Parameter(Mandatory = $true)][string]$PythonExecutable,
    [Parameter(Mandatory = $true)][string]$ExpectedObjectId
  )

  $items = @(Get-ChildItem -LiteralPath $PackRoot -File -Force -ErrorAction Stop)
  if ($items.Count -eq 0) { throw "Git object pack directory is empty: $PackRoot" }
  $groups = @($items | Group-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) })
  $objectIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  $pythonItem = Get-Item -LiteralPath $PythonExecutable -Force -ErrorAction Stop
  $verifierItem = Get-Item -LiteralPath $script:StackchanGitPackSemanticVerifierPath -Force -ErrorAction Stop
  if (($pythonItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
      ($verifierItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
      $pythonItem.PSIsContainer -or $verifierItem.PSIsContainer) {
    throw 'Git pack semantic verification refuses reparse-point or non-file executables/sources.'
  }
  foreach ($group in $groups) {
    if ($group.Name -notmatch '^pack-[0-9a-f]{40}$') { throw "Unsafe Git pack name: $($group.Name)" }
    $extensions = @($group.Group | ForEach-Object { $_.Extension.ToLowerInvariant() } | Sort-Object)
    if (($extensions -join ',') -cne '.idx,.pack,.rev') {
      throw "Git pack must contain exactly idx/pack/rev: $($group.Name)"
    }
    $idxPath = ($group.Group | Where-Object Extension -eq '.idx').FullName
    $packPath = ($group.Group | Where-Object Extension -eq '.pack').FullName
    $revPath = ($group.Group | Where-Object Extension -eq '.rev').FullName
    $previousPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $output = @(& $pythonItem.FullName $verifierItem.FullName `
        '--pack' $packPath '--index' $idxPath '--reverse-index' $revPath 2>&1)
      $exitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) {
      throw "Git pack object-to-offset mapping verification failed: $($output -join "`n")"
    }
    try {
      $result = ($output -join "`n") | ConvertFrom-Json
    } catch {
      throw "Git pack semantic verifier returned invalid JSON: $($output -join "`n")"
    }
    if ([string]$result.schema -cne 'stackchan.git-pack-semantics.v1' -or
        -not [bool]$result.objectOffsetMappingVerified -or
        -not [bool]$result.objectCrcMappingVerified -or
        -not [bool]$result.reverseIndexMappingVerified -or
        [int]$result.objectCount -ne @($result.objectIds).Count) {
      throw "Git pack semantic verifier omitted required mapping proof: $packPath"
    }
    foreach ($id in @($result.objectIds)) {
      if ([string]$id -notmatch '^[0-9a-f]{40}$' -or -not $objectIds.Add([string]$id)) {
        throw "Duplicate or malformed Git object identity across packs: $id"
      }
    }
  }
  if (-not $objectIds.Contains($ExpectedObjectId)) {
    throw "Git pack object set does not contain the expected checked-out commit: $ExpectedObjectId"
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
    [Parameter(Mandatory = $true)][string]$ExpectedCommit,
    [string]$PythonExecutable = (Get-StackchanGitPackVerifierPython)
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
          -CanonicalText (Get-StackchanCanonicalGitPackText `
            -PackRoot (Join-Path $gitRoot 'objects/pack') `
            -PythonExecutable $PythonExecutable `
            -ExpectedObjectId $ExpectedCommit))) | Out-Null
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
    [string]$PythonExecutable = (Get-StackchanGitPackVerifierPython),
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
    -ExpectedCommit $ExpectedCommit `
    -PythonExecutable $PythonExecutable
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
        'ArduinoJson', 'Dynamixel2Arduino', 'ESP32Servo', 'M5GFX', 'M5GFX@0.2.24', 'M5Unified',
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
    [string]$PythonExecutable = (Get-StackchanGitPackVerifierPython),
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
        -ExpectedCommit ([string]$sourcePolicy.commit) `
        -PythonExecutable $PythonExecutable -IncludeRecords
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
  Add-PolicyComponent 'git-installation' 'preBuild' 'gitHome' '@root'
  Add-PolicyComponent 'release-toolchain-identity-policy-source' 'preBuild' 'projectRoot' `
    'tools/release_toolchain_identity.ps1'
  Add-PolicyComponent 'git-pack-semantic-verifier-source' 'preBuild' 'projectRoot' `
    'tools/verify_git_pack_semantics.py'

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
    Add-PolicyComponent "project-libdeps-$environment" 'postBuild' 'libdepsRoot' $environment
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
    [ValidateSet('stackchan', 'stackchan_servo_calibration', 'stackchan_release_full')]
    [string]$Environment,
    [string]$PythonExecutable = (Get-StackchanGitPackVerifierPython),
    [string]$PlatformKey = (Get-StackchanReleaseToolchainPlatformKey),
    $LeaseState,
    [string]$LeaseScope,
    [switch]$PostBuildComponentsOnly
  )

  $policy = @(Get-StackchanReleaseToolchainComponentPolicy -PlatformKey $PlatformKey)
  if ($PostBuildComponentsOnly -and
      ($Phase -cne 'PostBuild' -or $null -eq $LeaseState)) {
    throw 'PostBuild-only observation is valid only for a guarded PostBuild identity.'
  }
  if ($Phase -ceq 'PreBuild' -and -not [string]::IsNullOrWhiteSpace($Environment)) {
    throw 'A dependency environment filter is valid only for PostBuild identity.'
  }
  $selected = @($policy | Where-Object {
    (-not $PostBuildComponentsOnly -and [string]$_.phase -ceq 'preBuild') -or
      ($Phase -ceq 'PostBuild' -and [string]$_.phase -ceq 'postBuild' -and (
        [string]::IsNullOrWhiteSpace($Environment) -or
        [string]$_.name -ceq "project-libdeps-$Environment"))
  })
  $observed = [System.Collections.Generic.List[object]]::new()
  foreach ($component in $selected) {
    $path = Resolve-StackchanIdentityComponentPath -RootMap $RootMap -Component $component
    if ([string]$component.phase -ceq 'postBuild') {
      if ($null -ne $LeaseState) {
        Protect-StackchanToolchainTree `
          -LeaseState $LeaseState -Root $path -Scope $LeaseScope
      }
      $environment = ([string]$component.name).Substring('project-libdeps-'.Length)
      $identity = Get-StackchanCanonicalLibdepsIdentity `
        -Root $path -Environment $environment -PythonExecutable $PythonExecutable
    } elseif (Test-Path -LiteralPath $path -PathType Leaf) {
      if ($null -ne $LeaseState) {
        Add-StackchanToolchainFileLease `
          -LeaseState $LeaseState -LiteralPath $path -Scope $LeaseScope
      }
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
      $identity = Get-StackchanToolchainTreeIdentity `
        -Root $path -LeaseState $LeaseState -LeaseScope $LeaseScope
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
    [string]$GitExecutable,
    [string]$PlatformKey = (Get-StackchanReleaseToolchainPlatformKey)
  )

  $pythonHome = (Get-Item -LiteralPath ([string]$RootMap.pythonHome) -Force -ErrorAction Stop).FullName.TrimEnd('\', '/')
  $expectedPio = @('Scripts/pio.exe', 'Scripts/platformio.exe') | ForEach-Object {
    [IO.Path]::GetFullPath((Join-Path $pythonHome $_))
  }
  $resolvedPio = (Get-Item -LiteralPath $PlatformioExecutable -Force -ErrorAction Stop).FullName
  $resolvedPython = (Get-Item -LiteralPath $PythonExecutable -Force -ErrorAction Stop).FullName
  $gitHome = (Get-Item -LiteralPath ([string]$RootMap.gitHome) -Force -ErrorAction Stop).FullName.TrimEnd('\', '/')
  $expectedGit = [IO.Path]::GetFullPath((Join-Path $gitHome 'cmd/git.exe'))
  if ([string]::IsNullOrWhiteSpace($GitExecutable)) { $GitExecutable = $expectedGit }
  $resolvedGit = (Get-Item -LiteralPath $GitExecutable -Force -ErrorAction Stop).FullName
  $comparison = if ($env:OS -eq 'Windows_NT') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
  if (@($expectedPio | Where-Object { $_.Equals($resolvedPio, $comparison) }).Count -ne 1) {
    throw 'PlatformIO executable is outside the reviewed Python installation.'
  }
  $expectedPython = [IO.Path]::GetFullPath((Join-Path $pythonHome 'python.exe'))
  if (-not $expectedPython.Equals($resolvedPython, $comparison)) {
    throw 'Python executable is outside the reviewed Python installation.'
  }
  if (-not $expectedGit.Equals($resolvedGit, $comparison)) {
    throw 'Git executable is outside the reviewed Git installation.'
  }
  Assert-StackchanPythonImportIsolation `
    -PythonHome $pythonHome -PythonExecutable $resolvedPython
  $components = @(Get-StackchanReleaseToolchainObservedComponents `
    -RootMap $RootMap -Phase PostBuild -PlatformKey $PlatformKey `
    -PythonExecutable $resolvedPython)
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
    gitExecutableRelativePath = 'cmd/git.exe'
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
    [string]$GitExecutable,
    [Parameter(Mandatory = $true)][ValidateSet('PreBuild', 'PostBuild')][string]$Phase,
    [ValidateSet('stackchan', 'stackchan_servo_calibration', 'stackchan_release_full')]
    [string]$Environment,
    [string]$PlatformKey = (Get-StackchanReleaseToolchainPlatformKey),
    $LeaseState,
    [string]$LeaseScope
  )

  if ($null -ne $LeaseState) {
    Assert-StackchanToolchainLeaseState -LeaseState $LeaseState
    if ([string]::IsNullOrWhiteSpace($LeaseScope)) {
      throw 'Guarded release toolchain identity requires one explicit lease scope.'
    }
    if ($Phase -ceq 'PreBuild' -and [bool]$LeaseState.preBuildVerified) {
      throw 'A guarded toolchain session may verify PreBuild only once.'
    }
    if ($Phase -ceq 'PostBuild' -and -not [bool]$LeaseState.preBuildVerified) {
      throw 'Guarded PostBuild identity requires the same session to verify PreBuild first.'
    }
    if ($Phase -ceq 'PostBuild' -and
        [string]$LeaseState.preBuildScope -ceq $LeaseScope) {
      throw 'Guarded PostBuild identity requires a scope distinct from its PreBuild authority.'
    }
  }

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
      [string]$allowlist.pythonExecutableRelativePath -cne 'python.exe' -or
      [string]$allowlist.gitExecutableRelativePath -cne 'cmd/git.exe') {
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
  $gitHome = (Get-Item -LiteralPath ([string]$RootMap.gitHome) -Force -ErrorAction Stop).FullName.TrimEnd('\', '/')
  $gitRelative = ConvertTo-StackchanSafeIdentityRelativePath ([string]$allowlist.gitExecutableRelativePath)
  $expectedGit = [IO.Path]::GetFullPath((Join-Path $gitHome ($gitRelative -replace '/', [IO.Path]::DirectorySeparatorChar)))
  if ([string]::IsNullOrWhiteSpace($GitExecutable)) { $GitExecutable = $expectedGit }
  $resolvedGit = (Get-Item -LiteralPath $GitExecutable -Force -ErrorAction Stop).FullName
  if (-not $expectedGit.Equals($resolvedGit, $comparison)) {
    throw 'Selected Git executable is not the byte-allowlisted application.'
  }

  $authorityKey = Get-StackchanToolchainPreBuildAuthorityKey `
    -AllowlistPath $AllowlistPath -RootMap $RootMap -PlatformKey $PlatformKey `
    -PlatformioExecutable $resolvedPio -PythonExecutable $resolvedPython `
    -GitExecutable $resolvedGit

  $expected = @($allowlist.components | Where-Object {
    [string]$_.phase -ceq 'preBuild' -or
      ($Phase -ceq 'PostBuild' -and (
        [string]::IsNullOrWhiteSpace($Environment) -or
        [string]$_.name -ceq "project-libdeps-$Environment"))
  })

  $observedArguments = @{
    RootMap = $RootMap
    Phase = $Phase
    PlatformKey = $PlatformKey
    PythonExecutable = $resolvedPython
    LeaseState = $LeaseState
    LeaseScope = $LeaseScope
  }
  if (-not [string]::IsNullOrWhiteSpace($Environment)) {
    $observedArguments.Environment = $Environment
  }
  if ($null -ne $LeaseState -and $Phase -ceq 'PostBuild') {
    if ([string]::IsNullOrWhiteSpace([string]$LeaseState.preBuildAuthorityKey) -or
        [string]$LeaseState.preBuildAuthorityKey -cne $authorityKey) {
      throw 'Guarded PostBuild authority differs from the verified PreBuild toolchain roots, executables, or allowlist.'
    }
    Assert-StackchanToolchainLeaseStateUnchanged `
      -LeaseState $LeaseState -Context 'PostBuild cached PreBuild reuse' -VerifyNamespace
    if (@($LeaseState.preBuildComponents).Count -eq 0) {
      throw 'Guarded PostBuild identity has no verified PreBuild component cache.'
    }
    $cachedPreBuild = @(Copy-StackchanToolchainIdentityComponents `
      -Components @($LeaseState.preBuildComponents))
    $expectedCachedPreBuild = @($expected | Where-Object {
      [string]$_.phase -ceq 'preBuild'
    })
    if ($expectedCachedPreBuild.Count -ne $cachedPreBuild.Count) {
      throw 'Release toolchain allowlist component count mismatch for phase PreBuild cache.'
    }
    $expectedCachedNames = [System.Collections.Generic.HashSet[string]]::new(
      [StringComparer]::Ordinal)
    foreach ($entry in $expectedCachedPreBuild) {
      $name = [string]$entry.name
      if ([string]::IsNullOrWhiteSpace($name) -or -not $expectedCachedNames.Add($name)) {
        throw "Release toolchain allowlist has an invalid or duplicate component: $name"
      }
      $matches = @($cachedPreBuild | Where-Object { [string]$_.name -ceq $name })
      if ($matches.Count -ne 1 -or
          [string]$entry.phase -cne [string]$matches[0].phase -or
          [string]$entry.identitySchema -cne [string]$matches[0].identitySchema -or
          [string]$entry.treeSha256 -cne [string]$matches[0].treeSha256 -or
          [int]$entry.fileCount -ne [int]$matches[0].fileCount -or
          [long]$entry.bytes -ne [long]$matches[0].bytes) {
        throw "Release toolchain byte identity mismatch: $name"
      }
    }
    $observedArguments.PostBuildComponentsOnly = $true
    $freshPostBuild = @(Get-StackchanReleaseToolchainObservedComponents @observedArguments)
    $observed = @($cachedPreBuild) + @($freshPostBuild)
  } else {
    $observed = @(Get-StackchanReleaseToolchainObservedComponents @observedArguments)
  }
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
  if ($null -ne $LeaseState) {
    Assert-StackchanToolchainLeaseStateUnchanged `
      -LeaseState $LeaseState -Context "$Phase allowlist comparison"
  }
  Assert-StackchanPythonImportIsolation `
    -PythonHome $pythonHome -PythonExecutable $resolvedPython
  if ($null -ne $LeaseState) {
    Assert-StackchanToolchainLeaseStateUnchanged `
      -LeaseState $LeaseState -Context "$Phase Python isolation probe"
    if ($Phase -ceq 'PreBuild') {
      $LeaseState.preBuildComponents = @(Copy-StackchanToolchainIdentityComponents `
        -Components $observed)
      $LeaseState.preBuildAuthorityKey = $authorityKey
      $LeaseState.preBuildScope = $LeaseScope
      $LeaseState.preBuildVerified = $true
    }
  }
  $observationText = (@($observed | Sort-Object name | ForEach-Object {
    "$([string]$_.name)`0$([string]$_.phase)`0$([string]$_.identitySchema)`0$([string]$_.treeSha256)`0$([int]$_.fileCount)`0$([long]$_.bytes)"
  }) -join "`n") + "`n"
  $observationHasher = [Security.Cryptography.SHA256]::Create()
  try {
    $observationSha256 = ([BitConverter]::ToString($observationHasher.ComputeHash(
      [Text.Encoding]::UTF8.GetBytes($observationText))) -replace '-', '').ToUpperInvariant()
  } finally {
    $observationHasher.Dispose()
  }
  return [pscustomobject][ordered]@{
    schema = $script:StackchanToolchainIdentitySchema
    status = 'verified'
    platformKey = $PlatformKey
    phase = $Phase
    environment = if ([string]::IsNullOrWhiteSpace($Environment)) { $null } else { $Environment }
    componentCount = $observed.Count
    allowlistSha256 = Get-StackchanFileSha256 -LiteralPath $AllowlistPath
    observationSha256 = $observationSha256
  }
}
