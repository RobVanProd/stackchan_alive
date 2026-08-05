param(
  [string]$Version,
  [switch]$SkipBuild,
  [switch]$AllowDirty,
  [switch]$ObserveCandidateActions,
  [switch]$ReleaseShortPathChild,
  [string]$ToolchainAllowlistPath,
  [string]$GitExecutable,
  [string]$PythonExecutable,
  [string]$PlatformioExecutable,
  [string]$LegacyCoreDir,
  [string]$ReleaseCoreDir
)

$ErrorActionPreference = "Stop"
$script:releaseSourceCleanupReady = $false

# These variables can alter safety flags or the canonical build epoch. Public
# packages must be derived from the reviewed configuration and clean Git
# identity. Check presence rather than truthiness and refuse before path/cache/
# build/package work. Diagnostic direct builds may use STACKCHAN_BUILD_EPOCH;
# release packaging never may.
$releaseOverrideNames = @(
  "PLATFORMIO_BUILD_FLAGS",
  "STACKCHAN_BUILD_EPOCH",
  "SOURCE_DATE_EPOCH",
  "STACKCHAN_BUILD_STAMP",
  "STACKCHAN_DISABLE_REPRODUCIBLE_BUILD",
  "STACKCHAN_EXPECTED_BUILD_COMMIT",
  "STACKCHAN_EXPECTED_BUILD_EPOCH",
  "STACKCHAN_PERSONA",
  "STACKCHAN_WIFI_SSID",
  "STACKCHAN_WIFI_PASSWORD",
  "STACKCHAN_BRIDGE_HOST",
  "STACKCHAN_BRIDGE_PORT",
  "STACKCHAN_BRIDGE_PATH",
  "STACKCHAN_PAIRING_SHORT_CODE",
  "STACKCHAN_OTA_TOKEN",
  "STACKCHAN_OTA_PORT",
  "PLATFORMIO_EXE",
  "PLATFORMIO_CORE_DIR",
  "PLATFORMIO_PROJECT_DIR",
  "PLATFORMIO_SRC_DIR",
  "PLATFORMIO_BUILD_DIR",
  "PLATFORMIO_LIBDEPS_DIR",
  "PLATFORMIO_PACKAGES_DIR",
  "PLATFORMIO_CACHE_DIR",
  "PLATFORMIO_BUILD_CACHE_DIR",
  "GIT_DIR",
  "GIT_WORK_TREE",
  "GIT_INDEX_FILE",
  "GIT_OBJECT_DIRECTORY",
  "GIT_ALTERNATE_OBJECT_DIRECTORIES",
  "GIT_COMMON_DIR",
  "GIT_CEILING_DIRECTORIES"
)
foreach ($releaseOverrideName in $releaseOverrideNames) {
  if (Test-Path ("Env:\" + $releaseOverrideName)) {
    throw "Release packaging refuses ambient override: $releaseOverrideName"
  }
}
$unexpectedPlatformioOverrides = @(
  Get-ChildItem Env: | Where-Object { $_.Name -like "PLATFORMIO_*" }
)
if ($unexpectedPlatformioOverrides.Count -gt 0) {
  $unexpectedPlatformioNames = @($unexpectedPlatformioOverrides.Name | Sort-Object -Unique)
  throw "Release packaging refuses ambient PlatformIO overrides: $($unexpectedPlatformioNames -join ', ')"
}
$unexpectedGitOverrides = @(
  Get-ChildItem Env: | Where-Object { $_.Name -like "GIT_*" }
)
if ($unexpectedGitOverrides.Count -gt 0) {
  $unexpectedGitNames = @($unexpectedGitOverrides.Name | Sort-Object -Unique)
  throw "Release packaging refuses ambient Git overrides: $($unexpectedGitNames -join ', ')"
}

$releaseBootstrapNullAttributes = if ($env:OS -eq 'Windows_NT') { 'NUL' } else { '/dev/null' }
$releaseToolchainAllowlistSha256 = '8425BFD814AD4395E70DD86AFF7CFD3D9003F3D5E91FBBC1F2F19BAAF0FF1790' # reviewed allowlist SHA-256
$releaseToolchainIdentityHelperSha256 = 'D63A93F4E9C3CFE057B59F963FCFF2C7CAF293300FF572E04F4B22608BD368A9' # reviewed identity helper SHA-256
$releaseToolchainSemanticVerifierSha256 = '649DE0BBF4A966ADF389A4C2F98190B87958E2ECCC1DF15A6E6FE04D86A4BEBA' # reviewed semantic verifier SHA-256
$releaseToolchainPreBuild = $null
$script:releaseToolchainIdentityRecords = [System.Collections.Generic.List[object]]::new()
$releaseToolchainEligible = $false
$releaseToolchainIdentityEvidence = $null
$script:releaseToolchainReadLeases = [System.Collections.Generic.List[IO.FileStream]]::new()
$script:releaseToolchainLeaseState = $null

function Add-ReleaseToolchainReadLease {
  param([Parameter(Mandatory = $true)][string]$LiteralPath)
  $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
  if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "Release bootstrap refuses a non-file or redirected lease target: $LiteralPath"
  }
  $lease = [IO.File]::Open(
    $item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  $script:releaseToolchainReadLeases.Add($lease) | Out-Null
}

function Get-ReleaseBootstrapSha256 {
  param([Parameter(Mandatory = $true)][string]$LiteralPath)
  $item = Get-Item -LiteralPath $LiteralPath -Force -ErrorAction Stop
  if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "Release bootstrap refuses a non-file or redirected input: $LiteralPath"
  }
  $stream = [IO.File]::Open($item.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  $hasher = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($hasher.ComputeHash($stream)) -replace '-', '').ToUpperInvariant()
  } finally {
    $hasher.Dispose()
    $stream.Dispose()
  }
}

function Close-ReleaseToolchainResources {
  if ($null -ne $script:releaseToolchainLeaseState -and
      -not [bool]$script:releaseToolchainLeaseState.closed) {
    $closeCommand = Get-Command -Name Close-StackchanToolchainLeaseState `
      -CommandType Function -ErrorAction SilentlyContinue
    if ($null -eq $closeCommand) {
      throw 'Release toolchain guard exists but its cleanup function is unavailable.'
    }
    Close-StackchanToolchainLeaseState -LeaseState $script:releaseToolchainLeaseState
  }
  foreach ($lease in @($script:releaseToolchainReadLeases)) {
    $lease.Dispose()
  }
  $script:releaseToolchainReadLeases.Clear()
}

trap {
  $packageFailure = $_
  if ($script:releaseSourceCleanupReady -and
      $null -ne (Get-Command -Name Remove-ReleaseSourceWorktree `
        -CommandType Function -ErrorAction SilentlyContinue)) {
    try {
      Remove-ReleaseSourceWorktree
    } catch {
      Write-Warning 'Could not clean the exact release source worktree; it remains preserved for inspection.'
    }
  }
  try {
    Close-ReleaseToolchainResources
  } catch {
    Write-Warning "Could not fully release package toolchain resources: $($_.Exception.Message)"
  }
  throw $packageFailure
}

if (-not $SkipBuild) {
  $requiredToolchainArguments = [ordered]@{
    GitExecutable = $GitExecutable
    PythonExecutable = $PythonExecutable
    PlatformioExecutable = $PlatformioExecutable
    LegacyCoreDir = $LegacyCoreDir
    ReleaseCoreDir = $ReleaseCoreDir
  }
  foreach ($entry in $requiredToolchainArguments.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$entry.Value)) {
      throw "Release packaging requires explicit -$($entry.Key) authority."
    }
  }
  if ([string]::IsNullOrWhiteSpace($ToolchainAllowlistPath)) {
    $ToolchainAllowlistPath = Join-Path $PSScriptRoot 'release_toolchain_identity_allowlist.json'
  }
  $ToolchainAllowlistPath = (Get-Item -LiteralPath $ToolchainAllowlistPath -Force -ErrorAction Stop).FullName
  $identityHelperPath = Join-Path $PSScriptRoot 'release_toolchain_identity.ps1'
  $semanticVerifierPath = Join-Path $PSScriptRoot 'verify_git_pack_semantics.py'
  $bootstrapInputs = @(
    [ordered]@{ path = $ToolchainAllowlistPath; expected = $releaseToolchainAllowlistSha256; label = 'allowlist' },
    [ordered]@{ path = $identityHelperPath; expected = $releaseToolchainIdentityHelperSha256; label = 'identity helper' },
    [ordered]@{ path = $semanticVerifierPath; expected = $releaseToolchainSemanticVerifierSha256; label = 'semantic verifier' }
  )
  foreach ($input in $bootstrapInputs) {
    if ([string]$input.expected -notmatch '^[0-9A-F]{64}$') {
      throw "Release packaging has no reviewed pre-Git byte authority for the $([string]$input.label)."
    }
    Add-ReleaseToolchainReadLease -LiteralPath ([string]$input.path)
    $actual = Get-ReleaseBootstrapSha256 -LiteralPath ([string]$input.path)
    if ($actual -cne [string]$input.expected) {
      throw "Release packaging pre-Git byte authority mismatch: $([string]$input.label)"
    }
  }
  $requiredPythonEnvironment = [ordered]@{
    PYTHONNOUSERSITE = '1'
    PYTHONSAFEPATH = '1'
    PYTHONDONTWRITEBYTECODE = '1'
    PYTHONHASHSEED = '0'
    PYTHONUTF8 = '1'
    PYTHONIOENCODING = 'utf-8'
  }
  $unexpectedPythonEnvironment = @(Get-ChildItem Env: | Where-Object {
    $_.Name -like 'PYTHON*' -and -not $requiredPythonEnvironment.Contains($_.Name)
  })
  if ($unexpectedPythonEnvironment.Count -ne 0) {
    throw "Release packaging refuses ambient Python overrides: $(@($unexpectedPythonEnvironment.Name | Sort-Object) -join ', ')"
  }
  foreach ($entry in $requiredPythonEnvironment.GetEnumerator()) {
    $existing = [Environment]::GetEnvironmentVariable(
      [string]$entry.Key, [EnvironmentVariableTarget]::Process)
    if (-not [string]::IsNullOrWhiteSpace($existing) -and $existing -cne [string]$entry.Value) {
      throw "Release packaging refuses ambient Python override: $($entry.Key)"
    }
    [Environment]::SetEnvironmentVariable(
      [string]$entry.Key, [string]$entry.Value, [EnvironmentVariableTarget]::Process)
  }
  . $identityHelperPath
  $script:releaseToolchainLeaseState = New-StackchanToolchainLeaseState
  $resolvedGitExecutable = (Get-Item -LiteralPath $GitExecutable -Force -ErrorAction Stop).FullName
  $resolvedPythonExecutable = (Get-Item -LiteralPath $PythonExecutable -Force -ErrorAction Stop).FullName
  $resolvedPlatformioExecutable = (Get-Item -LiteralPath $PlatformioExecutable -Force -ErrorAction Stop).FullName
  $resolvedLegacyCore = (Get-Item -LiteralPath $LegacyCoreDir -Force -ErrorAction Stop).FullName
  $resolvedReleaseCore = (Get-Item -LiteralPath $ReleaseCoreDir -Force -ErrorAction Stop).FullName
  foreach ($executable in @($resolvedGitExecutable, $resolvedPythonExecutable, $resolvedPlatformioExecutable)) {
    Add-ReleaseToolchainReadLease -LiteralPath $executable
  }
  $releaseToolchainRootMap = @{
    pythonHome = Split-Path -Parent $resolvedPythonExecutable
    gitHome = Split-Path -Parent (Split-Path -Parent $resolvedGitExecutable)
    legacyCore = $resolvedLegacyCore
    releaseCore = $resolvedReleaseCore
    projectRoot = (Get-Item -LiteralPath (Split-Path -Parent $PSScriptRoot) -Force).FullName
    libdepsRoot = Join-Path (Split-Path -Parent $PSScriptRoot) '.pio/libdeps'
  }
  $releaseToolchainPreBuild = Assert-StackchanReleaseToolchainIdentity `
    -AllowlistPath $ToolchainAllowlistPath -RootMap $releaseToolchainRootMap `
    -PlatformioExecutable $resolvedPlatformioExecutable `
    -PythonExecutable $resolvedPythonExecutable -GitExecutable $resolvedGitExecutable `
    -Phase PreBuild -LeaseState $script:releaseToolchainLeaseState -LeaseScope 'pre-build'
  $script:releaseToolchainIdentityRecords.Add([ordered]@{
    stage = 'preBuild'; cycle = $null; environment = $null; result = $releaseToolchainPreBuild
  }) | Out-Null
  $releaseBootstrapGitExecutable = $resolvedGitExecutable
} else {
  $releaseBootstrapGitCommand = Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
  if ($null -eq $releaseBootstrapGitCommand) {
    throw 'Release packaging requires a Git application executable; functions, aliases, and scripts are refused.'
  }
  $releaseBootstrapGitExecutable = (
    Resolve-Path -LiteralPath ([string]$releaseBootstrapGitCommand.Source)).Path
}
function Invoke-ReleaseBootstrapGit {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string[]]$Arguments
  )

  $disabledHooks = Join-Path $Root 'output/private/disabled-release-bootstrap-hooks'
  if (Test-Path -LiteralPath $disabledHooks) {
    throw "Release bootstrap disabled-hooks sentinel unexpectedly exists: $disabledHooks"
  }
  $gitArguments = @(
    '-c', "core.hooksPath=$disabledHooks", '-c', 'core.fsmonitor=false',
    '-c', 'core.untrackedCache=false', '-c', 'core.useBuiltinFSMonitor=false',
    '-c', 'maintenance.auto=false', '-c', 'core.autocrlf=true',
    '-c', "core.attributesFile=$script:releaseBootstrapNullAttributes",
    '-c', 'filter.lfs.process=', '-c', 'filter.lfs.clean=',
    '-c', 'filter.lfs.smudge=', '-c', 'filter.lfs.required=false',
    '-C', $Root
  ) + $Arguments
  $previousNoReplaceObjects = $env:GIT_NO_REPLACE_OBJECTS
  $previousNoSystemAttributes = $env:GIT_ATTR_NOSYSTEM
  try {
    $env:GIT_NO_REPLACE_OBJECTS = '1'
    $env:GIT_ATTR_NOSYSTEM = '1'
    if ($null -ne $script:releaseToolchainLeaseState) {
      Assert-StackchanToolchainLeaseStateUnchanged `
        -LeaseState $script:releaseToolchainLeaseState -Context 'before trusted Git execution'
    }
    & $script:releaseBootstrapGitExecutable @gitArguments
    if ($null -ne $script:releaseToolchainLeaseState) {
      Assert-StackchanToolchainLeaseStateUnchanged `
        -LeaseState $script:releaseToolchainLeaseState -Context 'after trusted Git execution'
    }
  } finally {
    if ($null -eq $previousNoReplaceObjects) {
      Remove-Item Env:\GIT_NO_REPLACE_OBJECTS -ErrorAction SilentlyContinue
    } else {
      $env:GIT_NO_REPLACE_OBJECTS = $previousNoReplaceObjects
    }
    if ($null -eq $previousNoSystemAttributes) {
      Remove-Item Env:\GIT_ATTR_NOSYSTEM -ErrorAction SilentlyContinue
    } else {
      $env:GIT_ATTR_NOSYSTEM = $previousNoSystemAttributes
    }
  }
}

function Get-ReleaseBootstrapCanonicalBlobHash {
  param(
    [Parameter(Mandatory = $true)][string]$LiteralPath,
    [Parameter(Mandatory = $true)][ValidateSet(40, 64)][int]$HashLength
  )

  $bytes = [System.IO.File]::ReadAllBytes($LiteralPath)
  if (-not ($bytes -contains [byte]0)) {
    $normalized = New-Object System.Collections.Generic.List[byte]
    for ($index = 0; $index -lt $bytes.Length; $index++) {
      if ($bytes[$index] -eq 13 -and $index + 1 -lt $bytes.Length -and
          $bytes[$index + 1] -eq 10) {
        $normalized.Add(10)
        $index++
      } else {
        $normalized.Add($bytes[$index])
      }
    }
    $bytes = $normalized.ToArray()
  }
  $header = [System.Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)`0")
  $objectBytes = New-Object byte[] ($header.Length + $bytes.Length)
  [System.Array]::Copy($header, 0, $objectBytes, 0, $header.Length)
  [System.Array]::Copy($bytes, 0, $objectBytes, $header.Length, $bytes.Length)
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

function Resolve-ReleaseBootstrapGitPath {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$Candidate
  )
  if ([System.IO.Path]::IsPathRooted($Candidate)) {
    return [System.IO.Path]::GetFullPath($Candidate)
  }
  return [System.IO.Path]::GetFullPath((Join-Path $Root $Candidate))
}

function Assert-ReleaseBootstrapTrust {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [string]$ExpectedGitTopLevel = ''
  )

  $resolvedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
  $resolvedExpectedGitTopLevel = if ([string]::IsNullOrWhiteSpace($ExpectedGitTopLevel)) {
    $resolvedRoot
  } else {
    [System.IO.Path]::GetFullPath($ExpectedGitTopLevel).TrimEnd('\', '/')
  }
  $prefix = (Invoke-ReleaseBootstrapGit -Root $resolvedRoot -Arguments @(
    'rev-parse', '--show-prefix') | Out-String).Trim()
  $prefixExitCode = $LASTEXITCODE
  $topLevel = (Invoke-ReleaseBootstrapGit -Root $resolvedRoot -Arguments @(
    'rev-parse', '--show-toplevel')).Trim()
  if ($prefixExitCode -ne 0 -or -not [string]::IsNullOrEmpty($prefix) -or
      $LASTEXITCODE -ne 0 -or
      -not [System.IO.Path]::GetFullPath($topLevel).TrimEnd('\', '/').Equals(
        $resolvedExpectedGitTopLevel, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Release packaging must start at its exact Git top-level.'
  }
  $attributePaths = New-Object System.Collections.Generic.List[string]
  $worktreeAttributes = (Invoke-ReleaseBootstrapGit -Root $resolvedRoot -Arguments @(
    'rev-parse', '--git-path', 'info/attributes')).Trim()
  $commonDir = (Invoke-ReleaseBootstrapGit -Root $resolvedRoot -Arguments @(
    'rev-parse', '--git-common-dir')).Trim()
  if ([string]::IsNullOrWhiteSpace($worktreeAttributes) -or
      [string]::IsNullOrWhiteSpace($commonDir)) {
    throw 'Release packaging could not resolve repository-local attributes state.'
  }
  $attributePaths.Add((Resolve-ReleaseBootstrapGitPath -Root $resolvedRoot -Candidate $worktreeAttributes))
  $attributePaths.Add((Resolve-ReleaseBootstrapGitPath -Root $resolvedRoot -Candidate (
    Join-Path $commonDir 'info/attributes')))
  foreach ($attributePath in @($attributePaths | Sort-Object -Unique)) {
    if (Test-Path -LiteralPath $attributePath -PathType Leaf) {
      throw "Release packaging refuses repository-local Git attributes: $attributePath"
    }
  }
  $commit = (Invoke-ReleaseBootstrapGit -Root $resolvedRoot -Arguments @(
    'rev-parse', '--verify', 'HEAD')).Trim().ToLowerInvariant()
  if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40,64}$') {
    throw 'Release packaging could not resolve its exact Git commit.'
  }
  $bootstrapFiles = @(
    '.gitattributes', 'tools/package_release.ps1',
    'tools/verify_release_package.ps1',
    'tools/test_firmware_reproducible_build_contract.ps1',
    'tools/test_release_toolchain_integration_contract.ps1',
    'tools/test_release_toolchain_documentation_contract.ps1',
    'tools/test_release_toolchain_cache_contract.ps1',
    'tools/seal_pioarduino_release_core.ps1',
    'tools/release_toolchain_identity.ps1',
    'tools/release_toolchain_identity_allowlist.json',
    'tools/verify_git_pack_semantics.py',
    'tools/test_git_pack_semantic_verifier.py',
    'tools/test_release_toolchain_identity_contract.ps1',
    'tools/platformio_resolver.ps1', 'tools/preview_python_resolver.ps1',
    'tools/release_asset_contract.ps1', 'tools/firmware_reproducibility_failure.ps1',
    'tools/release_source_binding.ps1', 'tools/release_dependency_evidence.ps1',
    'tools/release_git_trust.ps1', 'tools/release_ota_selector_policy.ps1',
    'tools/check_release_credential_hygiene.ps1'
  )
  foreach ($relative in $bootstrapFiles) {
    $indexRecord = @(Invoke-ReleaseBootstrapGit -Root $resolvedRoot -Arguments @(
      'ls-files', '-v', '--', $relative))
    $trustedBlob = (Invoke-ReleaseBootstrapGit -Root $resolvedRoot -Arguments @(
      'rev-parse', '--verify', "${commit}:$relative")).Trim().ToLowerInvariant()
    $workingPath = Join-Path $resolvedRoot $relative
    if ($indexRecord.Count -ne 1 -or [string]$indexRecord[0] -cne "H $relative" -or
        $trustedBlob -notmatch '^[0-9a-f]{40,64}$' -or
        -not (Test-Path -LiteralPath $workingPath -PathType Leaf) -or
        (Get-ReleaseBootstrapCanonicalBlobHash -LiteralPath $workingPath `
          -HashLength $trustedBlob.Length) -cne $trustedBlob) {
      throw "Release packaging bootstrap input is not exact trusted commit content: $relative"
    }
  }
  $dirty = @(Invoke-ReleaseBootstrapGit -Root $resolvedRoot -Arguments @(
    'status', '--porcelain=v1', '--untracked-files=all'))
  if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) {
    throw 'Release packaging requires a clean trusted checkout before executing helpers or mutating release state.'
  }
}

function Invoke-ReleaseGit {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)
  Invoke-StackchanTrustedGit `
    -GitExecutable $script:releaseBootstrapGitExecutable `
    -DisabledHooksPath $script:releaseGitDisabledHooksPath `
    -Arguments $Arguments
}

function Assert-SafeReleaseVersionLeaf {
  param([Parameter(Mandatory = $true)][string]$Value)

  if ($Value.Length -gt 128 -or
      $Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or
      $Value -in @('.', '..') -or
      $Value.EndsWith('.', [System.StringComparison]::Ordinal)) {
    throw "Version must be one safe filename component containing only letters, digits, '.', '_', or '-'."
  }
}

function New-StackchanDeterministicReleaseZip {
  param(
    [Parameter(Mandatory = $true)][string]$RootPath,
    [Parameter(Mandatory = $true)][string]$ZipPath,
    [Parameter(Mandatory = $true)][long]$SourceEpoch
  )

  Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
  $rootItem = Get-Item -LiteralPath (Resolve-Path -LiteralPath $RootPath).Path -Force
  if (-not $rootItem.PSIsContainer -or
      ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    throw 'Release ZIP root must be one exact non-redirected directory.'
  }
  $resolvedRoot = $rootItem.FullName.TrimEnd('\', '/')
  $resolvedZip = [System.IO.Path]::GetFullPath($ZipPath)
  $rootPrefix = $resolvedRoot + [System.IO.Path]::DirectorySeparatorChar
  if ($resolvedZip.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Release ZIP must be outside the package tree being archived.'
  }
  $entryTimestamp = [DateTimeOffset]::FromUnixTimeSeconds($SourceEpoch)
  $minimumZipTimestamp = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
  $maximumZipTimestamp = [DateTimeOffset]::new(2107, 12, 31, 23, 59, 58, [TimeSpan]::Zero)
  if ($entryTimestamp -lt $minimumZipTimestamp -or $entryTimestamp -gt $maximumZipTimestamp) {
    throw "Release source epoch is outside the ZIP timestamp range: $SourceEpoch"
  }
  # ZIP timestamps have two-second resolution. Normalize explicitly so identical inputs produce
  # identical metadata rather than relying on runtime rounding behavior.
  $subsecondTicks = $entryTimestamp.Ticks % [TimeSpan]::TicksPerSecond
  $entryTimestamp = $entryTimestamp.AddSeconds(-($entryTimestamp.Second % 2)).AddTicks(-$subsecondTicks)

  $files = @(Get-ChildItem -LiteralPath $resolvedRoot -File -Recurse -Force)
  $relativeToFile = [System.Collections.Generic.Dictionary[string, string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
  foreach ($file in $files) {
    $fullName = [System.IO.Path]::GetFullPath($file.FullName)
    if (-not $fullName.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Release ZIP input escapes its package root: $fullName"
    }
    if ($file.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
      throw "Release ZIP refuses a reparse-point input: $fullName"
    }
    $ancestor = $file.Directory
    while ($null -ne $ancestor -and
        -not $ancestor.FullName.Equals(
          $resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
      if ($ancestor.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Release ZIP refuses a file beneath a reparse-point directory: $fullName"
      }
      $ancestor = $ancestor.Parent
    }
    if ($null -eq $ancestor) {
      throw "Release ZIP could not prove the input's directory ancestry: $fullName"
    }
    $relative = $fullName.Substring($rootPrefix.Length).Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($relative) -or $relativeToFile.ContainsKey($relative)) {
      throw "Release ZIP input has an invalid or duplicate entry: $relative"
    }
    $relativeToFile.Add($relative, $fullName)
  }
  $relativePaths = [string[]]@($relativeToFile.Keys)
  [Array]::Sort($relativePaths, [System.StringComparer]::Ordinal)

  $stream = [System.IO.FileStream]::new(
    $resolvedZip, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite,
    [System.IO.FileShare]::None)
  try {
    $archive = [System.IO.Compression.ZipArchive]::new(
      $stream, [System.IO.Compression.ZipArchiveMode]::Create, $true,
      [System.Text.Encoding]::UTF8)
    try {
      foreach ($relative in $relativePaths) {
        $entry = $archive.CreateEntry(
          $relative, [System.IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = $entryTimestamp
        $sourceStream = [System.IO.FileStream]::new(
          $relativeToFile[$relative], [System.IO.FileMode]::Open,
          [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $entryStream = $entry.Open()
        try {
          $sourceStream.CopyTo($entryStream)
        } finally {
          $entryStream.Dispose()
          $sourceStream.Dispose()
        }
      }
    } finally {
      $archive.Dispose()
    }
  } finally {
    $stream.Dispose()
  }

  $readStream = [System.IO.FileStream]::new(
    $resolvedZip, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read,
    [System.IO.FileShare]::Read)
  try {
    $readArchive = [System.IO.Compression.ZipArchive]::new(
      $readStream, [System.IO.Compression.ZipArchiveMode]::Read, $false,
      [System.Text.Encoding]::UTF8)
    try {
      $actualEntries = [string[]]@($readArchive.Entries | ForEach-Object { $_.FullName })
    } finally {
      $readArchive.Dispose()
    }
  } finally {
    $readStream.Dispose()
  }
  if ($actualEntries.Count -ne $relativePaths.Count) {
    throw 'Release ZIP entry count changed during deterministic archive creation.'
  }
  for ($index = 0; $index -lt $relativePaths.Count; $index++) {
    if ([string]$actualEntries[$index] -cne [string]$relativePaths[$index]) {
      throw "Release ZIP central-directory order mismatch at index $index."
    }
  }
  return $actualEntries
}

if (-not [string]::IsNullOrWhiteSpace($Version)) {
  Assert-SafeReleaseVersionLeaf -Value $Version
}

if ($SkipBuild -and -not $AllowDirty) {
  throw "-SkipBuild is diagnostic-only and requires -AllowDirty; release-grade packages must perform the governed two-cycle firmware proof."
}
if ($AllowDirty -and -not $SkipBuild) {
  throw "-AllowDirty supports diagnostic -SkipBuild packages only; dirty firmware compilation requires a separately governed direct build."
}
if ($SkipBuild -and $ObserveCandidateActions) {
  throw "Diagnostic -SkipBuild packages cannot observe or claim candidate GitHub Actions evidence."
}

$releaseSystemDirectory = [System.IO.Path]::GetFullPath([Environment]::SystemDirectory).TrimEnd('\', '/')
if ($env:OS -ne 'Windows_NT' -or -not [System.IO.Path]::IsPathRooted($releaseSystemDirectory)) {
  throw 'Release packaging requires a validated Windows system executable root.'
}
$releasePowerShellExecutable = Join-Path $releaseSystemDirectory 'WindowsPowerShell/v1.0/powershell.exe'
$releaseSubstExecutable = Join-Path $releaseSystemDirectory 'subst.exe'
foreach ($systemExecutable in @($releasePowerShellExecutable, $releaseSubstExecutable)) {
  if (-not (Test-Path -LiteralPath $systemExecutable -PathType Leaf)) {
    throw "Required Windows system executable is missing: $systemExecutable"
  }
  $systemExecutableItem = Get-Item -LiteralPath $systemExecutable -Force
  if ($systemExecutableItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint -or
      [string]$systemExecutableItem.Extension -cne '.exe') {
    throw "Release packaging refuses a redirected or non-EXE system command: $systemExecutable"
  }
}

function Get-ReleaseShortPathPhysicalRoot {
  param([Parameter(Mandatory = $true)][string]$LogicalRoot)

  $fullLogicalRoot = [System.IO.Path]::GetFullPath($LogicalRoot)
  $driveRoot = [System.IO.Path]::GetPathRoot($fullLogicalRoot)
  $resolvedLogicalRoot = $fullLogicalRoot.TrimEnd('\', '/')
  $allowedShortRoots = @('R:\', 'Q:\', 'P:\', 'O:\')
  if ($allowedShortRoots -notcontains $driveRoot -or
      -not $resolvedLogicalRoot.Equals(
        $driveRoot.TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase) -or
      $resolvedLogicalRoot.Length -gt 60) {
    throw '-ReleaseShortPathChild is internal and requires the verified short subst checkout.'
  }

  $mappingLines = @(& $script:releaseSubstExecutable)
  if ($LASTEXITCODE -ne 0) {
    throw 'Release packaging could not query the temporary subst mapping.'
  }
  $driveLetter = $driveRoot.Substring(0, 1)
  $physicalTargets = @($mappingLines | ForEach-Object {
    $match = [regex]::Match(
      [string]$_, '^(?<drive>[A-Za-z]):\\: => (?<target>.+)$',
      [System.Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if ($match.Success -and
        $match.Groups['drive'].Value.Equals(
          $driveLetter, [System.StringComparison]::OrdinalIgnoreCase)) {
      $match.Groups['target'].Value
    }
  })
  if ($physicalTargets.Count -ne 1) {
    throw 'Release packaging requires exactly one verified subst mapping for its short checkout.'
  }
  $physicalRoot = [System.IO.Path]::GetFullPath([string]$physicalTargets[0]).TrimEnd('\', '/')
  $physicalItem = Get-Item -LiteralPath $physicalRoot -Force -ErrorAction Stop
  if (-not $physicalItem.PSIsContainer -or
      ($physicalItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
    throw 'Release packaging refuses a missing, non-directory, or redirected subst target.'
  }
  return $physicalRoot
}

$physicalRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$bootstrapGitTopLevel = $physicalRepoRoot
if ($ReleaseShortPathChild) {
  $bootstrapGitTopLevel = Get-ReleaseShortPathPhysicalRoot -LogicalRoot $physicalRepoRoot
}
$trustedVerifierScriptPath = [System.IO.Path]::GetFullPath(
  (Join-Path $bootstrapGitTopLevel 'tools/verify_release_package.ps1'))
if (-not $SkipBuild) {
  Assert-ReleaseBootstrapTrust -Root $physicalRepoRoot `
    -ExpectedGitTopLevel $bootstrapGitTopLevel
  if ($ReleaseShortPathChild) {
    $confirmedPhysicalRoot = Get-ReleaseShortPathPhysicalRoot -LogicalRoot $physicalRepoRoot
    if (-not $confirmedPhysicalRoot.Equals(
        $bootstrapGitTopLevel, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw 'Release packaging detected a changed subst mapping during bootstrap trust verification.'
    }
  }
}
if (
  $env:OS -eq "Windows_NT" -and
  -not $ReleaseShortPathChild -and
  $physicalRepoRoot.Length -gt 60
) {
  $shortDrive = @("R:", "Q:", "P:", "O:") |
    Where-Object { -not (Test-Path $_) } |
    Select-Object -First 1
  if (-not $shortDrive) {
    throw "Release packaging needs a free temporary drive letter (R:, Q:, P:, or O:) for this deeply nested checkout."
  }

  $driveName = $shortDrive.TrimEnd("\")
  & $script:releaseSubstExecutable $driveName $physicalRepoRoot
  if ($LASTEXITCODE -ne 0) { throw "Could not create temporary release path $driveName" }

  $childExit = 1
  try {
    $childArgs = @(
      "-NoProfile",
      "-ExecutionPolicy", "Bypass",
      "-File", "$driveName\tools\package_release.ps1",
      "-ReleaseShortPathChild"
    )
    if ($Version) { $childArgs += @("-Version", $Version) }
    if ($SkipBuild) { $childArgs += "-SkipBuild" }
    if ($AllowDirty) { $childArgs += "-AllowDirty" }
    if ($ObserveCandidateActions) { $childArgs += "-ObserveCandidateActions" }
    if ($ToolchainAllowlistPath) { $childArgs += @('-ToolchainAllowlistPath', $ToolchainAllowlistPath) }
    if ($GitExecutable) { $childArgs += @('-GitExecutable', $GitExecutable) }
    if ($PythonExecutable) { $childArgs += @('-PythonExecutable', $PythonExecutable) }
    if ($PlatformioExecutable) { $childArgs += @('-PlatformioExecutable', $PlatformioExecutable) }
    if ($LegacyCoreDir) { $childArgs += @('-LegacyCoreDir', $LegacyCoreDir) }
    if ($ReleaseCoreDir) { $childArgs += @('-ReleaseCoreDir', $ReleaseCoreDir) }
    & $script:releasePowerShellExecutable @childArgs
    $childExit = $LASTEXITCODE
  } finally {
    Set-Location $env:TEMP
    & $script:releaseSubstExecutable $driveName /D | Out-Null
    if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath "$driveName\")) {
      throw "Could not remove temporary release path $driveName"
    }
  }
  exit $childExit
}

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
$releaseGitDisabledHooksPath = Join-Path $repoRoot (
  "output/private/disabled-release-git-hooks-$PID-" + [guid]::NewGuid().ToString("N"))
if (Test-Path -LiteralPath $releaseGitDisabledHooksPath) {
  throw "Release Git disabled-hooks sentinel unexpectedly exists: $releaseGitDisabledHooksPath"
}
& $releasePowerShellExecutable -NoProfile -ExecutionPolicy Bypass -File `
  (Join-Path $PSScriptRoot "test_firmware_reproducible_build_contract.ps1")
if ($LASTEXITCODE -ne 0) {
  throw "Firmware reproducible-build contract failed; refusing release packaging."
}
. (Join-Path $PSScriptRoot "platformio_resolver.ps1")
. (Join-Path $PSScriptRoot "preview_python_resolver.ps1")
. (Join-Path $PSScriptRoot "release_asset_contract.ps1")
. (Join-Path $PSScriptRoot "firmware_reproducibility_failure.ps1")
. (Join-Path $PSScriptRoot "release_source_binding.ps1")
. (Join-Path $PSScriptRoot "release_dependency_evidence.ps1")
. (Join-Path $PSScriptRoot "release_git_trust.ps1")
. (Join-Path $PSScriptRoot "release_ota_selector_policy.ps1")
if (-not $SkipBuild) {
  $script:StackchanPlatformioCommand = $resolvedPlatformioExecutable
}

$credentialHygieneJson = (& (Join-Path $PSScriptRoot "check_release_credential_hygiene.ps1") -Root $repoRoot -Json | Out-String)
$credentialHygieneReport = $credentialHygieneJson | ConvertFrom-Json
if ($credentialHygieneReport.status -ne "release-credential-hygiene-ready" -or [int]$credentialHygieneReport.failed -ne 0) {
  throw "Release credential hygiene failed; refusing to build or package from this checkout."
}
Write-Host $credentialHygieneJson.Trim()

$releaseLegacyPlatformioCore = if ($SkipBuild) {
  Get-StackchanPlatformioCoreDir
} else {
  $resolvedLegacyCore
}
if ([string]::IsNullOrWhiteSpace($releaseLegacyPlatformioCore) -and
    -not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
  $legacyCoreFallback = Join-Path $env:USERPROFILE '.platformio'
  if (Test-Path -LiteralPath $legacyCoreFallback -PathType Container) {
    $releaseLegacyPlatformioCore = (Resolve-Path -LiteralPath $legacyCoreFallback).Path
  }
}
if ([string]::IsNullOrWhiteSpace($releaseLegacyPlatformioCore) -or
    -not (Test-Path -LiteralPath $releaseLegacyPlatformioCore -PathType Container)) {
  throw 'Release packaging could not resolve the legacy PlatformIO core directory.'
}
$releasePlatformioCoreRoot = if ($env:OS -eq "Windows_NT") {
  # The repository may be running through a temporary subst drive. Keep the
  # pioarduino core on the physical system drive so it survives that mapping
  # and retains the intentionally short path used by release builds.
  Join-Path ([System.IO.Path]::GetPathRoot($env:SystemRoot)) "spio"
} else {
  Join-Path ([System.IO.Path]::GetTempPath()) "stackchan-pio-release-cores"
}

function Get-ReleasePlatformioCoreDir {
  param([string]$Environment)

  if ($Environment -eq "stackchan_release_full") {
    if (-not $SkipBuild) { return $resolvedReleaseCore }
    return Join-Path $releasePlatformioCoreRoot "pioarduino"
  }
  return $releaseLegacyPlatformioCore
}

function Get-ReleaseOtaSelectorPath {
  param([Parameter(Mandatory = $true)][string]$Environment)

  $coreDir = Get-ReleasePlatformioCoreDir -Environment $Environment
  $selector = Assert-StackchanReleaseFrameworkOtaSelector `
    -Environment $Environment -CoreDir $coreDir
  return [string]$selector.path
}

function Invoke-StackchanReleasePlatformio {
  param(
    [string]$Environment,
    [string]$BuildCacheDir,
    [string]$ExpectedCommit,
    [string]$ExpectedEpoch,
    [string]$BuildProjectRoot,
    [string[]]$Arguments
  )

  $previousCoreDir = $env:PLATFORMIO_CORE_DIR
  $previousBuildCacheDir = $env:PLATFORMIO_BUILD_CACHE_DIR
  $previousExpectedCommit = $env:STACKCHAN_EXPECTED_BUILD_COMMIT
  $previousExpectedEpoch = $env:STACKCHAN_EXPECTED_BUILD_EPOCH
  $previousPythonSafePath = $env:PYTHONSAFEPATH
  $previousProcessPath = $env:PATH
  try {
    $env:PLATFORMIO_CORE_DIR = Get-ReleasePlatformioCoreDir -Environment $Environment
    if (-not [string]::IsNullOrWhiteSpace($BuildCacheDir)) {
      $env:PLATFORMIO_BUILD_CACHE_DIR = $BuildCacheDir
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedCommit) -or
        -not [string]::IsNullOrWhiteSpace($ExpectedEpoch)) {
      if ([string]::IsNullOrWhiteSpace($ExpectedCommit) -or
          [string]::IsNullOrWhiteSpace($ExpectedEpoch)) {
        throw "Release build identity lock requires both commit and epoch."
      }
      $env:STACKCHAN_EXPECTED_BUILD_COMMIT = $ExpectedCommit
      $env:STACKCHAN_EXPECTED_BUILD_EPOCH = $ExpectedEpoch
    }
    if (-not $SkipBuild) {
      if ([string]::IsNullOrWhiteSpace($BuildProjectRoot)) {
        throw 'Release PlatformIO execution requires one explicit BuildProjectRoot.'
      }
      Remove-Item Env:\PYTHONSAFEPATH -ErrorAction SilentlyContinue
      $env:PATH = @(
        (Split-Path -Parent $resolvedPlatformioExecutable),
        (Split-Path -Parent $resolvedPythonExecutable),
        (Split-Path -Parent $resolvedGitExecutable),
        (Join-Path ([Environment]::GetFolderPath('Windows')) 'System32'),
        (Join-Path ([Environment]::GetFolderPath('Windows')) 'System32/WindowsPowerShell/v1.0')
      ) -join [IO.Path]::PathSeparator
      Assert-StackchanReleaseBuildPythonEnvironment -ProjectRoot $BuildProjectRoot
    }
    if ($null -ne $script:releaseToolchainLeaseState) {
      Assert-StackchanToolchainLeaseStateUnchanged `
        -LeaseState $script:releaseToolchainLeaseState -Context 'before PlatformIO execution'
    }
    Invoke-StackchanPlatformio @Arguments
    if ($null -ne $script:releaseToolchainLeaseState) {
      Assert-StackchanToolchainLeaseStateUnchanged `
        -LeaseState $script:releaseToolchainLeaseState -Context 'after PlatformIO execution'
    }
  } finally {
    if ($null -eq $previousCoreDir) {
      Remove-Item Env:\PLATFORMIO_CORE_DIR -ErrorAction SilentlyContinue
    } else {
      $env:PLATFORMIO_CORE_DIR = $previousCoreDir
    }
    if ($null -eq $previousBuildCacheDir) {
      Remove-Item Env:\PLATFORMIO_BUILD_CACHE_DIR -ErrorAction SilentlyContinue
    } else {
      $env:PLATFORMIO_BUILD_CACHE_DIR = $previousBuildCacheDir
    }
    if ($null -eq $previousExpectedCommit) {
      Remove-Item Env:\STACKCHAN_EXPECTED_BUILD_COMMIT -ErrorAction SilentlyContinue
    } else {
      $env:STACKCHAN_EXPECTED_BUILD_COMMIT = $previousExpectedCommit
    }
    if ($null -eq $previousExpectedEpoch) {
      Remove-Item Env:\STACKCHAN_EXPECTED_BUILD_EPOCH -ErrorAction SilentlyContinue
    } else {
      $env:STACKCHAN_EXPECTED_BUILD_EPOCH = $previousExpectedEpoch
    }
    if ($null -eq $previousPythonSafePath) {
      Remove-Item Env:\PYTHONSAFEPATH -ErrorAction SilentlyContinue
    } else {
      $env:PYTHONSAFEPATH = $previousPythonSafePath
    }
    $env:PATH = $previousProcessPath
  }
}

if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = (Invoke-ReleaseGit -Arguments @("describe", "--tags", "--always", "--dirty")).Trim()
}
Assert-SafeReleaseVersionLeaf -Value $Version
if ($SkipBuild -and -not $Version.StartsWith("diagnostic-", [System.StringComparison]::Ordinal)) {
  throw "Diagnostic -SkipBuild package versions must start with 'diagnostic-'."
}

$firmwareBuildArtifactNames = @(
  "firmware.bin",
  "firmware.elf",
  "bootloader.bin",
  "partitions.bin"
)
$firmwareArtifactNames = @($firmwareBuildArtifactNames + "boot_app0.bin")

function Copy-BuildArtifacts {
  param(
    [Parameter(Mandatory = $true)][string]$Environment,
    [string]$BuildDir,
    [string]$Destination
  )

  New-Item -ItemType Directory -Force -Path $Destination | Out-Null
  foreach ($file in $firmwareBuildArtifactNames) {
    $source = Join-Path $BuildDir $file
    if (-not (Test-Path -LiteralPath $source)) {
      throw "Missing build artifact: $source"
    }
    Copy-Item -LiteralPath $source -Destination $Destination -Force
  }
  $otaSelector = Get-ReleaseOtaSelectorPath -Environment $Environment
  $packagedSelector = Join-Path $Destination "boot_app0.bin"
  Copy-Item -LiteralPath $otaSelector -Destination $packagedSelector -Force
  Assert-StackchanReleaseOtaSelectorBytes `
    -Environment $Environment -LiteralPath $packagedSelector | Out-Null
}

$releaseOutputRoot = if ($SkipBuild) {
  Join-Path $repoRoot "output/diagnostics"
} else {
  Join-Path $repoRoot "output/release"
}

$builtFirmwareCache = $null
$firmwareBuildCacheRoot = $null
$firmwareDependencySnapshotRoot = $null
$releaseSourceRoot = $null
$releaseSourceWorktreeAdded = $false
$releaseSourceLocationPushed = $false
$releaseSourceFailureRecorded = $false
$firmwareReproducibilityProof = [ordered]@{
  status = "not-proven-skip-build"
  minimumClockBoundarySeconds = 65
  clockBoundarySeconds = 0
  cycleAStartedUtc = $null
  cycleBStartedUtc = $null
  cycleASourceCommit = $null
  cycleASourceEpoch = $null
  cycleBSourceCommit = $null
  cycleBSourceEpoch = $null
  buildCachePolicy = "not-applicable-skip-build"
  sourceIsolationPolicy = "not-applicable-skip-build"
  sourcePathTopologyPolicy = "not-applicable-skip-build"
  sourceRootLength = 0
  identityAttestations = @()
  cycleAArtifacts = @()
  cycleBArtifacts = @()
}

function Get-CanonicalReleaseGitIdentity {
  param([Parameter(Mandatory = $true)][string]$ProjectRoot)

  $identityCommit = (Invoke-ReleaseGit -Arguments @("-C", $ProjectRoot, "rev-parse", "HEAD")).Trim()
  if ($LASTEXITCODE -ne 0 -or $identityCommit -notmatch '^[0-9a-fA-F]{40}$') {
    throw "Could not resolve a canonical 40-character Git commit for release provenance."
  }
  $identityEpoch = (Invoke-ReleaseGit -Arguments @("-C", $ProjectRoot, "show", "-s", "--format=%ct", $identityCommit)).Trim()
  if ($LASTEXITCODE -ne 0 -or $identityEpoch -notmatch '^[0-9]{1,12}$') {
    throw "Could not resolve the canonical Git commit epoch for release provenance."
  }
  return [ordered]@{
    commit = $identityCommit.ToLowerInvariant()
    epoch = $identityEpoch
  }
}

function Assert-ReleaseSourceIdentity {
  param(
    [Parameter(Mandatory = $true)][string]$ExpectedCommit,
    [Parameter(Mandatory = $true)][string]$ExpectedEpoch,
    [Parameter(Mandatory = $true)][string]$Phase,
    [Parameter(Mandatory = $true)][string]$ProjectRoot,
    [switch]$RejectIgnored
  )

  $observedIdentity = Get-CanonicalReleaseGitIdentity -ProjectRoot $ProjectRoot
  if ($observedIdentity.commit -cne $ExpectedCommit -or
      $observedIdentity.epoch -cne $ExpectedEpoch) {
    throw "Release source identity changed during $Phase."
  }
  $identityStatusArguments = @(
    "-C", $ProjectRoot, "status", "--porcelain", "--untracked-files=all")
  if ($RejectIgnored) {
    $identityStatusArguments += @("--ignored=matching", "--ignore-submodules=none")
  }
  $identityDirty = @(Invoke-ReleaseGit -Arguments $identityStatusArguments)
  if ($LASTEXITCODE -ne 0 -or $identityDirty.Count -gt 0) {
    throw "Release source worktree is not clean during $Phase."
  }
}

function New-ShortReleaseScratchPath {
  param([Parameter(Mandatory = $true)][string]$Label)

  if ($Label -notmatch '^[a-z0-9-]{1,16}$') {
    throw "Invalid release scratch label: $Label"
  }
  if ($env:OS -eq "Windows_NT") {
    $reservedDrives = @("R", "Q", "P", "O", "S", "T", "U")
    $drive = Get-PSDrive -PSProvider FileSystem |
      Where-Object {
        $_.Root -match '^[A-Za-z]:\\$' -and
        $reservedDrives -notcontains $_.Name -and
        $null -ne $_.Free
      } |
      Sort-Object Free -Descending |
      Select-Object -First 1
    if ($null -eq $drive) {
      throw "Could not locate a fixed drive for a short release build worktree."
    }
    $fixedWidthProcessId = $PID.ToString('D10', [Globalization.CultureInfo]::InvariantCulture)
    $scratch = Join-Path $drive.Root ("sc-$Label-$fixedWidthProcessId-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
  } else {
    $fixedWidthProcessId = $PID.ToString('D10', [Globalization.CultureInfo]::InvariantCulture)
    $scratch = Join-Path ([System.IO.Path]::GetTempPath()) ("sc-$Label-$fixedWidthProcessId-" + [guid]::NewGuid().ToString("N").Substring(0, 8))
  }
  $scratch = [System.IO.Path]::GetFullPath($scratch)
  if ($env:OS -eq "Windows_NT" -and $scratch.Length -gt 60) {
    throw "Release scratch path is not short enough for the embedded toolchain: $scratch"
  }
  if (Test-Path -LiteralPath $scratch) {
    throw "Fresh release scratch path already exists: $scratch"
  }
  return $scratch
}

function Assert-StackchanReleaseCycleSourceTopology {
  param(
    [Parameter(Mandatory = $true)][string]$CycleASourceRoot,
    [Parameter(Mandatory = $true)][string]$CycleBSourceRoot
  )

  if ($CycleASourceRoot -ceq $CycleBSourceRoot -or
      $CycleASourceRoot.Length -ne $CycleBSourceRoot.Length -or
      (Split-Path -Leaf $CycleASourceRoot) -cnotmatch '^sc-fw-a-[0-9]{10}-[0-9a-f]{8}$' -or
      (Split-Path -Leaf $CycleBSourceRoot) -cnotmatch '^sc-fw-b-[0-9]{10}-[0-9a-f]{8}$') {
    throw "Firmware reproducibility proof requires distinct equal-length fixed-width source roots."
  }
}

function Invoke-LoggedReleasePlatformio {
  param(
    [Parameter(Mandatory = $true)][string]$Environment,
    [Parameter(Mandatory = $true)][string]$BuildCacheDir,
    [Parameter(Mandatory = $true)][string]$ExpectedCommit,
    [Parameter(Mandatory = $true)][string]$ExpectedEpoch,
    [Parameter(Mandatory = $true)][string]$BuildProjectRoot,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [Parameter(Mandatory = $true)][string]$LogPath,
    [Parameter(Mandatory = $true)][string]$Description
  )

  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $LogPath) | Out-Null
  $lines = New-Object 'System.Collections.Generic.List[string]'
  try {
    Invoke-StackchanReleasePlatformio `
      -Environment $Environment `
      -BuildCacheDir $BuildCacheDir `
      -ExpectedCommit $ExpectedCommit `
      -ExpectedEpoch $ExpectedEpoch `
      -BuildProjectRoot $BuildProjectRoot `
      -Arguments $Arguments 2>&1 | ForEach-Object {
        $line = [string]$_
        $lines.Add($line)
        Write-Host $line
      }
    $commandExit = $LASTEXITCODE
  } catch {
    $lines.Add([string]$_)
    $lines | Set-Content -LiteralPath $LogPath -Encoding UTF8
    throw
  }
  $lines | Set-Content -LiteralPath $LogPath -Encoding UTF8
  if ($commandExit -ne 0) {
    throw "$Description failed with exit code $commandExit. Log: $LogPath"
  }
  return @($lines)
}

function Copy-DependencySnapshotFiles {
  param(
    [Parameter(Mandatory = $true)][string]$SourceRoot,
    [Parameter(Mandatory = $true)][string]$DestinationRoot
  )

  if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) { return }
  $sourcePath = (Resolve-Path -LiteralPath $SourceRoot).Path.TrimEnd('\', '/')
  foreach ($file in Get-ChildItem -LiteralPath $sourcePath -Recurse -File -Force -ErrorAction SilentlyContinue) {
    if ($file.Name -notmatch '(?i)^(LICENSE|LICENCE|COPYING|NOTICE)(\..*)?$' -and
        $file.Name -notin @('library.json', 'library.properties', 'package.json', 'platform.json')) {
      continue
    }
    $relative = $file.FullName.Substring($sourcePath.Length + 1)
    $destination = Join-Path $DestinationRoot $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
  }
}

function Save-BuildDependencySnapshot {
  param(
    [Parameter(Mandatory = $true)][string]$Environment,
    [Parameter(Mandatory = $true)][string]$BuildCacheDir,
    [Parameter(Mandatory = $true)][string]$ExpectedCommit,
    [Parameter(Mandatory = $true)][string]$ExpectedEpoch,
    [Parameter(Mandatory = $true)][string]$BuildProjectRoot,
    [Parameter(Mandatory = $true)][string]$SnapshotRoot
  )

  $environmentRoot = Join-Path $SnapshotRoot $Environment
  New-Item -ItemType Directory -Force -Path $environmentRoot | Out-Null
  $packageListLines = @(Invoke-LoggedReleasePlatformio `
    -Environment $Environment `
    -BuildCacheDir $BuildCacheDir `
    -ExpectedCommit $ExpectedCommit `
    -ExpectedEpoch $ExpectedEpoch `
    -BuildProjectRoot $BuildProjectRoot `
    -Arguments @('pkg', 'list', '-d', $BuildProjectRoot, '-e', $Environment) `
    -LogPath (Join-Path $environmentRoot 'pkg-list.txt') `
    -Description "$Environment dependency inventory")
  $verbosePackageListLines = @(Invoke-LoggedReleasePlatformio `
    -Environment $Environment `
    -BuildCacheDir $BuildCacheDir `
    -ExpectedCommit $ExpectedCommit `
    -ExpectedEpoch $ExpectedEpoch `
    -BuildProjectRoot $BuildProjectRoot `
    -Arguments @('pkg', 'list', '-d', $BuildProjectRoot, '-e', $Environment, '-v') `
    -LogPath (Join-Path $environmentRoot 'pkg-list-verbose.txt') `
    -Description "$Environment verbose dependency inventory")
  Invoke-LoggedReleasePlatformio `
    -Environment $Environment `
    -BuildCacheDir $BuildCacheDir `
    -ExpectedCommit $ExpectedCommit `
    -ExpectedEpoch $ExpectedEpoch `
    -BuildProjectRoot $BuildProjectRoot `
    -Arguments @('--version') `
    -LogPath (Join-Path $environmentRoot 'platformio-version.txt') `
    -Description "$Environment PlatformIO version capture" | Out-Null

  Copy-DependencySnapshotFiles `
    -SourceRoot (Join-Path $BuildProjectRoot ".pio/libdeps/$Environment") `
    -DestinationRoot (Join-Path $environmentRoot 'libdeps')
  $coreDir = Get-ReleasePlatformioCoreDir -Environment $Environment
  $platformSource = Get-StackchanVerbosePlatformSource `
    -VerbosePackageList ($verbosePackageListLines -join "`n") `
    -PlatformioCoreDir $coreDir
  Copy-DependencySnapshotFiles `
    -SourceRoot $platformSource.sourcePath `
    -DestinationRoot (Join-Path $environmentRoot ('platform/' + $platformSource.sourceLeaf))
  $platformSource | ConvertTo-Json | Set-Content `
    -LiteralPath (Join-Path $environmentRoot 'platform-source.json') -Encoding UTF8
  $resolvedPackages = @(Convert-StackchanPioPackageList ($packageListLines -join "`n"))
  $corePackagesRoot = Join-Path $coreDir 'packages'
  $corePackageNames = @(Get-StackchanResolvedCorePackageNames `
    -ResolvedPackages $resolvedPackages -CorePackagesRoot $corePackagesRoot)
  if ($corePackageNames.Count -eq 0) {
    throw "No resolved PlatformIO core packages were captured for $Environment"
  }
  Copy-StackchanResolvedCorePackageEvidence `
    -CorePackagesRoot $corePackagesRoot `
    -DestinationRoot (Join-Path $environmentRoot 'packages') `
    -CorePackageNames $corePackageNames
  $corePackageNames | ConvertTo-Json | Set-Content `
    -LiteralPath (Join-Path $environmentRoot 'core-package-names.json') -Encoding UTF8
}

function Invoke-FirmwareBuildCycle {
  param(
    [Parameter(Mandatory = $true)][string]$CycleRoot,
    [Parameter(Mandatory = $true)][string]$ExpectedCommit,
    [Parameter(Mandatory = $true)][string]$ExpectedEpoch,
    [Parameter(Mandatory = $true)][string]$CycleName,
    [Parameter(Mandatory = $true)][string]$BuildProjectRoot,
    [string]$DependencySnapshotRoot
  )
  New-Item -ItemType Directory -Force -Path $CycleRoot | Out-Null
  foreach ($environment in @("stackchan", "stackchan_servo_calibration", "stackchan_release_full")) {
    Assert-ReleaseSourceIdentity `
      -ExpectedCommit $ExpectedCommit `
      -ExpectedEpoch $ExpectedEpoch `
      -Phase "$CycleName/$environment pre-clean" `
      -ProjectRoot $BuildProjectRoot
    $environmentBuildCache = Join-Path $CycleRoot "build-cache-$environment"
    if (Test-Path -LiteralPath $environmentBuildCache) {
      throw "Fresh release build cache already exists: $environmentBuildCache"
    }
    New-Item -ItemType Directory -Path $environmentBuildCache | Out-Null
    if (@(Get-ChildItem -LiteralPath $environmentBuildCache -Force).Count -ne 0) {
      throw "Fresh release build cache is not empty: $environmentBuildCache"
    }
    $environmentLibdeps = Join-Path $BuildProjectRoot ".pio/libdeps/$environment"
    if (Test-Path -LiteralPath $environmentLibdeps) {
      Remove-Item -LiteralPath $environmentLibdeps -Recurse -Force
    }
    Invoke-LoggedReleasePlatformio `
      -Environment $environment `
      -BuildCacheDir $environmentBuildCache `
      -ExpectedCommit $ExpectedCommit `
      -ExpectedEpoch $ExpectedEpoch `
      -BuildProjectRoot $BuildProjectRoot `
      -Arguments @('pkg', 'install', '-d', $BuildProjectRoot, '-e', $environment) `
      -LogPath (Join-Path $CycleRoot "logs/$environment-dependency-stage.log") `
      -Description "$CycleName/$environment dependency staging" | Out-Null
    $dependencyRootMap = @{
      pythonHome = [string]$releaseToolchainRootMap.pythonHome
      gitHome = [string]$releaseToolchainRootMap.gitHome
      legacyCore = [string]$releaseToolchainRootMap.legacyCore
      releaseCore = [string]$releaseToolchainRootMap.releaseCore
      projectRoot = $BuildProjectRoot
      libdepsRoot = Join-Path $BuildProjectRoot '.pio/libdeps'
    }
    $preExecutionIdentity = Assert-StackchanReleaseToolchainIdentity `
      -AllowlistPath $ToolchainAllowlistPath -RootMap $dependencyRootMap `
      -PlatformioExecutable $resolvedPlatformioExecutable `
      -PythonExecutable $resolvedPythonExecutable -GitExecutable $resolvedGitExecutable `
      -Phase PostBuild -Environment $environment `
      -LeaseState $script:releaseToolchainLeaseState -LeaseScope $CycleName
    $script:releaseToolchainIdentityRecords.Add([ordered]@{
      stage = 'preExecution'; cycle = $CycleName; environment = $environment
      result = $preExecutionIdentity
    }) | Out-Null
    Invoke-LoggedReleasePlatformio `
      -Environment $environment `
      -BuildCacheDir $environmentBuildCache `
      -ExpectedCommit $ExpectedCommit `
      -ExpectedEpoch $ExpectedEpoch `
      -BuildProjectRoot $BuildProjectRoot `
      -Arguments @("run", "-d", $BuildProjectRoot, "-e", $environment, "-t", "clean") `
      -LogPath (Join-Path $CycleRoot "logs/$environment-clean.log") `
      -Description "$CycleName/$environment clean" | Out-Null
    Assert-ReleaseSourceIdentity `
      -ExpectedCommit $ExpectedCommit `
      -ExpectedEpoch $ExpectedEpoch `
      -Phase "$CycleName/$environment pre-build" `
      -ProjectRoot $BuildProjectRoot
    Invoke-LoggedReleasePlatformio `
      -Environment $environment `
      -BuildCacheDir $environmentBuildCache `
      -ExpectedCommit $ExpectedCommit `
      -ExpectedEpoch $ExpectedEpoch `
      -BuildProjectRoot $BuildProjectRoot `
      -Arguments @("run", "-d", $BuildProjectRoot, "-e", $environment) `
      -LogPath (Join-Path $CycleRoot "logs/$environment-build.log") `
      -Description "$CycleName/$environment build" | Out-Null
    $postBuildIdentity = Assert-StackchanReleaseToolchainIdentity `
      -AllowlistPath $ToolchainAllowlistPath -RootMap $dependencyRootMap `
      -PlatformioExecutable $resolvedPlatformioExecutable `
      -PythonExecutable $resolvedPythonExecutable -GitExecutable $resolvedGitExecutable `
      -Phase PostBuild -Environment $environment `
      -LeaseState $script:releaseToolchainLeaseState -LeaseScope $CycleName
    $script:releaseToolchainIdentityRecords.Add([ordered]@{
      stage = 'postBuild'; cycle = $CycleName; environment = $environment
      result = $postBuildIdentity
    }) | Out-Null
    Copy-BuildArtifacts `
      -Environment $environment `
      -BuildDir (Join-Path $BuildProjectRoot ".pio/build/$environment") `
      -Destination (Join-Path $CycleRoot $environment)
    Assert-ReleaseSourceIdentity `
      -ExpectedCommit $ExpectedCommit `
      -ExpectedEpoch $ExpectedEpoch `
      -Phase "$CycleName/$environment post-snapshot" `
      -ProjectRoot $BuildProjectRoot
    $script:firmwareIdentityAttestations += [ordered]@{
      cycle = $CycleName
      environment = $environment
      sourceCommit = $ExpectedCommit
      sourceEpoch = $ExpectedEpoch
      preBuildChecked = $true
      postSnapshotChecked = $true
    }
    if (-not [string]::IsNullOrWhiteSpace($DependencySnapshotRoot)) {
      Save-BuildDependencySnapshot `
        -Environment $environment `
        -BuildCacheDir $environmentBuildCache `
        -ExpectedCommit $ExpectedCommit `
        -ExpectedEpoch $ExpectedEpoch `
        -BuildProjectRoot $BuildProjectRoot `
        -SnapshotRoot $DependencySnapshotRoot
    }
  }
}

function Get-FirmwareBuildArtifactRecords {
  param(
    [Parameter(Mandatory = $true)][string]$CycleRoot
  )
  $records = @()
  foreach ($environment in @("stackchan", "stackchan_servo_calibration", "stackchan_release_full")) {
    foreach ($artifact in $firmwareArtifactNames) {
      $path = Join-Path (Join-Path $CycleRoot $environment) $artifact
      if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing reproducibility artifact: $path"
      }
      $item = Get-Item -LiteralPath $path
      $records += [ordered]@{
        environment = $environment
        artifact = $artifact
        bytes = [long]$item.Length
        sha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $path).Hash.ToUpperInvariant()
      }
    }
  }
  return @($records)
}

function Get-UtcWholeSecond {
  $now = (Get-Date).ToUniversalTime()
  return [DateTime]::new(
    $now.Ticks - ($now.Ticks % [TimeSpan]::TicksPerSecond),
    [DateTimeKind]::Utc)
}

function Remove-ReleaseSourceWorktree {
  if ($script:releaseSourceLocationPushed) {
    Pop-Location
    $script:releaseSourceLocationPushed = $false
  }
  if (-not $script:releaseSourceWorktreeAdded) {
    return
  }
  if ([string]::IsNullOrWhiteSpace($script:releaseSourceRoot)) {
    throw "Commit-bound release source root is missing while its worktree is registered; refusing successful cleanup."
  }
  if (-not (Test-Path -LiteralPath $script:releaseSourceRoot)) {
    throw (
      "Commit-bound release source worktree is missing at " + [string]$script:releaseSourceRoot +
      "; refusing successful packaging because its final state cannot be audited.")
  }
  $releaseSourceDirty = @(
    Invoke-ReleaseGit -Arguments @(
      '-C', [string]$script:releaseSourceRoot, 'status', '--porcelain=v1',
      '--untracked-files=all', '--ignored=matching', '--ignore-submodules=none'))
  if ($LASTEXITCODE -ne 0) {
    throw "Could not audit the commit-bound release source; leaving its exact worktree attached."
  }
  if ($releaseSourceDirty.Count -gt 0) {
    if (-not $script:releaseSourceFailureRecorded) {
      $sourceFailureParent = Join-Path $repoRoot 'output/private/package-source-failures'
      New-Item -ItemType Directory -Force -Path $sourceFailureParent | Out-Null
      $sourceFailureRoot = Join-Path $sourceFailureParent (
        (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + "-$PID-" + [guid]::NewGuid().ToString('N'))
      New-Item -ItemType Directory -Path $sourceFailureRoot | Out-Null
      $releaseSourceDirty | Set-Content -LiteralPath (Join-Path $sourceFailureRoot 'STATUS.txt') -Encoding UTF8
      Invoke-ReleaseGit -Arguments @(
        '-C', [string]$script:releaseSourceRoot, 'diff', '--binary', '--no-ext-diff') |
        Set-Content -LiteralPath (Join-Path $sourceFailureRoot 'TRACKED_CHANGES.patch') -Encoding UTF8
      [ordered]@{
        schema = 'stackchan.package-source-failure.v2'
        status = 'commit-bound-source-drift-full-worktree-preserved'
        preservationPolicy = 'full-failed-worktree-retained-attached'
        sourceRoot = [string]$script:releaseSourceRoot
        sourceCommit = if ($null -eq $canonicalBuildCommit) { $null } else { $canonicalBuildCommit }
        capturedUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
      } | ConvertTo-Json -Depth 3 | Set-Content `
        -LiteralPath (Join-Path $sourceFailureRoot 'FAILURE_EVIDENCE.json') -Encoding UTF8
      $script:releaseSourceFailureRecorded = $true
      Write-Warning (
        "Commit-bound release source drift was detected. Its complete worktree remains attached at " +
        [string]$script:releaseSourceRoot + "; evidence: " + $sourceFailureRoot)
    }
    throw "Commit-bound release source drift is a package failure; the full worktree remains attached."
  }
  Invoke-ReleaseGit -Arguments @(
    '-C', [string]$repoRoot, 'worktree', 'remove', [string]$script:releaseSourceRoot)
  if ($LASTEXITCODE -ne 0) {
    throw "Could not remove the commit-bound release source worktree: $($script:releaseSourceRoot)"
  }
  $script:releaseSourceWorktreeAdded = $false
  $script:releaseSourceRoot = $null
}

$script:releaseSourceCleanupReady = $true

if (-not $SkipBuild) {
  # The three profiles span two PlatformIO core roots. Each proof cycle uses a
  # distinct, short detached worktree, and the compiler hook maps both paths to
  # one canonical debug/source prefix before bytes are compared.
  $firmwareBuildCacheRoot = Join-Path $repoRoot (
    "output/release/.firmware-build-cache-$PID-" + [guid]::NewGuid().ToString("N"))
  $cycleARoot = Join-Path $firmwareBuildCacheRoot "cycle-a"
  $cycleBRoot = Join-Path $firmwareBuildCacheRoot "cycle-b"
  $firmwareDependencySnapshotRoot = Join-Path $firmwareBuildCacheRoot "cycle-b-dependencies"
  $cycleASourceRoot = New-ShortReleaseScratchPath -Label 'fw-a'
  $cycleBSourceRoot = New-ShortReleaseScratchPath -Label 'fw-b'
  Assert-StackchanReleaseCycleSourceTopology `
    -CycleASourceRoot $cycleASourceRoot `
    -CycleBSourceRoot $cycleBSourceRoot
  $activeBuildSourceRoot = $null
  $activeBuildWorktreeAdded = $false
  $script:firmwareIdentityAttestations = @()
  $canonicalBuildIdentity = Get-CanonicalReleaseGitIdentity -ProjectRoot $repoRoot
  $canonicalBuildCommit = $canonicalBuildIdentity.commit
  $canonicalBuildEpoch = $canonicalBuildIdentity.epoch
  Assert-ReleaseSourceIdentity `
    -ExpectedCommit $canonicalBuildCommit `
    -ExpectedEpoch $canonicalBuildEpoch `
    -Phase "reproducibility proof source capture" `
    -ProjectRoot $repoRoot
  try {
    $activeBuildSourceRoot = $cycleASourceRoot
    Invoke-ReleaseGit -Arguments @(
      '-C', $repoRoot, 'worktree', 'add', '--detach', $activeBuildSourceRoot, $canonicalBuildCommit)
    if ($LASTEXITCODE -ne 0) { throw "Could not create the cycle-a detached firmware worktree." }
    $activeBuildWorktreeAdded = $true
    Assert-ReleaseSourceIdentity `
      -ExpectedCommit $canonicalBuildCommit `
      -ExpectedEpoch $canonicalBuildEpoch `
      -Phase "cycle-a detached source creation" `
      -ProjectRoot $activeBuildSourceRoot
    $cycleAStarted = Get-UtcWholeSecond
    Invoke-FirmwareBuildCycle `
      -CycleRoot $cycleARoot `
      -ExpectedCommit $canonicalBuildCommit `
      -ExpectedEpoch $canonicalBuildEpoch `
      -CycleName 'cycle-a' `
      -BuildProjectRoot $activeBuildSourceRoot
    $cycleAArtifacts = @(Get-FirmwareBuildArtifactRecords -CycleRoot $cycleARoot)
    Assert-ReleaseSourceIdentity `
      -ExpectedCommit $canonicalBuildCommit `
      -ExpectedEpoch $canonicalBuildEpoch `
      -Phase "reproducibility proof post-cycle-a" `
      -ProjectRoot $activeBuildSourceRoot
    Close-StackchanToolchainLeaseScope `
      -LeaseState $script:releaseToolchainLeaseState -Scope 'cycle-a' `
      -RequireUnchanged -Context 'cycle-a final authenticated namespace'
    Invoke-ReleaseGit -Arguments @(
      '-C', $repoRoot, 'worktree', 'remove', '--force', $activeBuildSourceRoot)
    if ($LASTEXITCODE -ne 0) { throw "Could not remove the cycle-a detached firmware worktree." }
    $activeBuildWorktreeAdded = $false
    $activeBuildSourceRoot = $null

    $cycleBNotBefore = $cycleAStarted.AddSeconds(65)
    while ((Get-Date).ToUniversalTime() -lt $cycleBNotBefore) {
      $remaining = [int][Math]::Ceiling(($cycleBNotBefore - (Get-Date).ToUniversalTime()).TotalSeconds)
      Start-Sleep -Seconds ([Math]::Min(10, [Math]::Max(1, $remaining)))
    }
    $cycleBStarted = Get-UtcWholeSecond
    $activeBuildSourceRoot = $cycleBSourceRoot
    Invoke-ReleaseGit -Arguments @(
      '-C', $repoRoot, 'worktree', 'add', '--detach', $activeBuildSourceRoot, $canonicalBuildCommit)
    if ($LASTEXITCODE -ne 0) { throw "Could not create the cycle-b detached firmware worktree." }
    $activeBuildWorktreeAdded = $true
    Assert-ReleaseSourceIdentity `
      -ExpectedCommit $canonicalBuildCommit `
      -ExpectedEpoch $canonicalBuildEpoch `
      -Phase "cycle-b detached source creation" `
      -ProjectRoot $activeBuildSourceRoot
    Invoke-FirmwareBuildCycle `
      -CycleRoot $cycleBRoot `
      -ExpectedCommit $canonicalBuildCommit `
      -ExpectedEpoch $canonicalBuildEpoch `
      -CycleName 'cycle-b' `
      -BuildProjectRoot $activeBuildSourceRoot `
      -DependencySnapshotRoot $firmwareDependencySnapshotRoot
    $cycleBArtifacts = @(Get-FirmwareBuildArtifactRecords -CycleRoot $cycleBRoot)
    Assert-ReleaseSourceIdentity `
      -ExpectedCommit $canonicalBuildCommit `
      -ExpectedEpoch $canonicalBuildEpoch `
      -Phase "reproducibility proof post-cycle-b" `
      -ProjectRoot $activeBuildSourceRoot
    Close-StackchanToolchainLeaseScope `
      -LeaseState $script:releaseToolchainLeaseState -Scope 'cycle-b' `
      -RequireUnchanged -Context 'cycle-b final authenticated namespace'

    if ($cycleAArtifacts.Count -ne 15 -or $cycleBArtifacts.Count -ne 15) {
      throw "Firmware reproducibility proof did not produce all 15 artifacts per cycle."
    }
    for ($artifactIndex = 0; $artifactIndex -lt $cycleAArtifacts.Count; $artifactIndex++) {
      $left = $cycleAArtifacts[$artifactIndex]
      $right = $cycleBArtifacts[$artifactIndex]
      if ($left.environment -cne $right.environment -or
          $left.artifact -cne $right.artifact -or
          [long]$left.bytes -ne [long]$right.bytes -or
          $left.sha256 -cne $right.sha256) {
        throw "Firmware reproducibility mismatch: $($left.environment)/$($left.artifact)"
      }
    }
    $clockBoundarySeconds = [int][Math]::Floor(($cycleBStarted - $cycleAStarted).TotalSeconds)
    if ($clockBoundarySeconds -lt 65) {
      throw "Firmware reproducibility cycles did not cross the required 65-second clock boundary."
    }
    $firmwareReproducibilityProof = [ordered]@{
      status = "verified-two-clean-cycles"
      minimumClockBoundarySeconds = 65
      clockBoundarySeconds = $clockBoundarySeconds
      cycleAStartedUtc = $cycleAStarted.ToString("yyyy-MM-ddTHH:mm:ssZ")
      cycleBStartedUtc = $cycleBStarted.ToString("yyyy-MM-ddTHH:mm:ssZ")
      cycleASourceCommit = $canonicalBuildCommit
      cycleASourceEpoch = $canonicalBuildEpoch
      cycleBSourceCommit = $canonicalBuildCommit
      cycleBSourceEpoch = $canonicalBuildEpoch
      buildCachePolicy = "isolated-empty-per-cycle-environment"
      sourceIsolationPolicy = "distinct-equal-length-short-detached-clean-worktrees-pinned-to-source-commit-with-prefix-mapped-paths"
      sourcePathTopologyPolicy = "fixed-width-process-id-and-equal-length-distinct-labels"
      sourceRootLength = $cycleASourceRoot.Length
      identityAttestations = @($script:firmwareIdentityAttestations)
      cycleAArtifacts = @($cycleAArtifacts)
      cycleBArtifacts = @($cycleBArtifacts)
    }
    Invoke-ReleaseGit -Arguments @(
      '-C', $repoRoot, 'worktree', 'remove', '--force', $activeBuildSourceRoot)
    if ($LASTEXITCODE -ne 0) { throw "Could not remove the cycle-b detached firmware worktree." }
    $activeBuildWorktreeAdded = $false
    $activeBuildSourceRoot = $null
  } catch {
    $buildFailure = $_
    $failureParent = Join-Path $repoRoot "output/private/reproducibility-failures"
    New-Item -ItemType Directory -Force -Path $failureParent | Out-Null
    $failureName = (Get-Date).ToUniversalTime().ToString("yyyyMMdd-HHmmss") + "-$PID-" + [guid]::NewGuid().ToString("N")
    $failureRoot = Join-Path $failureParent $failureName
    try {
      $failureEvidence = Save-StackchanFirmwareReproducibilityFailureEvidence `
        -FailureRoot $failureRoot `
        -BuildCacheRoot ([string]$firmwareBuildCacheRoot) `
        -ActiveSourceRoot ([string]$activeBuildSourceRoot) `
        -WorktreeStillAttached ([bool]$activeBuildWorktreeAdded) `
        -Failure $buildFailure `
        -SourceCommit $canonicalBuildCommit `
        -SourceEpoch $canonicalBuildEpoch
      $firmwareBuildCacheRoot = $null
      Write-Warning (
        "Firmware reproducibility failed. The complete detached worktree remains attached at " +
        [string]$activeBuildSourceRoot + "; evidence: " + $failureRoot)
    } catch {
      Write-Warning "Could not fully copy failed build evidence; leaving the exact failed worktree attached."
    }
    throw $buildFailure.Exception
  }
  $identityRecords = @($script:releaseToolchainIdentityRecords)
  $preExecutionRecords = @($identityRecords | Where-Object { [string]$_.stage -ceq 'preExecution' })
  $postBuildRecords = @($identityRecords | Where-Object { [string]$_.stage -ceq 'postBuild' })
  $invalidIdentityRecords = @($identityRecords | Where-Object {
    [string]$_.result.status -cne 'verified' -or
      [string]$_.result.allowlistSha256 -cne $releaseToolchainAllowlistSha256 -or
      [string]$_.result.observationSha256 -notmatch '^[0-9A-F]{64}$'
  })
  if ($identityRecords.Count -ne 13 -or $preExecutionRecords.Count -ne 6 -or
      $postBuildRecords.Count -ne 6 -or $invalidIdentityRecords.Count -ne 0) {
    throw 'Release toolchain identity did not verify PreBuild plus pre-execution/post-build dependency state for both cycles.'
  }
  $reviewedAllowlist = Get-Content -LiteralPath $ToolchainAllowlistPath -Raw | ConvertFrom-Json
  Assert-StackchanToolchainLeaseStateUnchanged `
    -LeaseState $script:releaseToolchainLeaseState `
    -Context 'release toolchain eligibility decision' -VerifyNamespace
  $releaseToolchainEligible = $true
  $releaseToolchainIdentityEvidence = [ordered]@{
    schema = 'stackchan.release-toolchain-package-evidence.v1'
    status = 'verified-reviewed-toolchain-and-two-cycle-dependencies'
    platformKey = [string]$releaseToolchainPreBuild.platformKey
    allowlistSha256 = $releaseToolchainAllowlistSha256
    identityHelperSha256 = $releaseToolchainIdentityHelperSha256
    semanticVerifierSha256 = $releaseToolchainSemanticVerifierSha256
    review = $reviewedAllowlist.review
    gitExecutable = $resolvedGitExecutable
    pythonExecutable = $resolvedPythonExecutable
    platformioExecutable = $resolvedPlatformioExecutable
    preBuild = $releaseToolchainPreBuild
    preExecution = $preExecutionRecords
    postBuild = $postBuildRecords
  }
  $builtFirmwareCache = $cycleBRoot
  Assert-ReleaseSourceIdentity `
    -ExpectedCommit $canonicalBuildCommit `
    -ExpectedEpoch $canonicalBuildEpoch `
    -Phase "reproducibility proof before packaging" `
    -ProjectRoot $repoRoot

  $releaseSourceRoot = New-ShortReleaseScratchPath -Label 'release-src'
  Invoke-ReleaseGit -Arguments @(
    '-C', $repoRoot, 'worktree', 'add', '--detach', $releaseSourceRoot, $canonicalBuildCommit)
  if ($LASTEXITCODE -ne 0) { throw "Could not create the commit-bound release source worktree." }
  $releaseSourceWorktreeAdded = $true
  Assert-ReleaseSourceIdentity `
    -ExpectedCommit $canonicalBuildCommit `
    -ExpectedEpoch $canonicalBuildEpoch `
    -Phase "commit-bound package source creation" `
    -ProjectRoot $releaseSourceRoot `
    -RejectIgnored
  Push-Location $releaseSourceRoot
  $releaseSourceLocationPushed = $true
  $previewPython = Get-StackchanPreviewPython
  & $previewPython tools/render_preview.py
  if ($LASTEXITCODE -ne 0) {
    throw "Preview media generation failed with exit code $LASTEXITCODE"
  }
  Assert-ReleaseSourceIdentity `
    -ExpectedCommit $canonicalBuildCommit `
    -ExpectedEpoch $canonicalBuildEpoch `
    -Phase "commit-bound preview generation" `
    -ProjectRoot $releaseSourceRoot `
    -RejectIgnored
}

$dirtyFiles = @(Invoke-ReleaseGit -Arguments @(
  "-C", $repoRoot, "status", "--porcelain"))
$generatedMediaDirtyFiles = @(
  $dirtyFiles | Where-Object { $_ -match "^\s*(M|\?\?) docs/media/stackchan_alive_(preview\.(gif|mp4|png)|speech_preview\.gif|expression_sheet\.png)$" }
)
$sourceDirtyFiles = @(
  $dirtyFiles | Where-Object { $_ -notmatch "^\s*(M|\?\?) docs/media/stackchan_alive_(preview\.(gif|mp4|png)|speech_preview\.gif|expression_sheet\.png)$" }
)

if ($sourceDirtyFiles.Count -gt 0 -and -not $AllowDirty) {
  $dirtyList = ($sourceDirtyFiles -join [Environment]::NewLine)
  throw "Refusing to package a dirty source worktree. Commit or discard changes first, or pass -AllowDirty for local diagnostic packages. Dirty files:$([Environment]::NewLine)$dirtyList"
}

$observedPackageIdentity = Get-CanonicalReleaseGitIdentity -ProjectRoot $repoRoot
$commit = $observedPackageIdentity.commit
$shortCommit = (Invoke-ReleaseGit -Arguments @(
  "-C", $repoRoot, "rev-parse", "--short", "HEAD")).Trim()
$commitEpoch = $observedPackageIdentity.epoch
if (-not $SkipBuild -and
    ($commit -cne $canonicalBuildCommit -or $commitEpoch -cne $canonicalBuildEpoch)) {
  throw "Release source identity changed between reproducibility proof and packaging."
}
$releaseOutputRootPath = [System.IO.Path]::GetFullPath([string]$releaseOutputRoot).TrimEnd('\', '/')
$releaseOutputRootPrefix = $releaseOutputRootPath + [System.IO.Path]::DirectorySeparatorChar
function Join-ContainedReleaseOutputPath {
  param([Parameter(Mandatory = $true)][string]$Leaf)

  if ([System.IO.Path]::IsPathRooted($Leaf) -or
      $Leaf.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
      $Leaf.Contains('/') -or $Leaf.Contains('\')) {
    throw "Refusing unsafe release output leaf: $Leaf"
  }
  $candidate = [System.IO.Path]::GetFullPath((Join-Path $releaseOutputRootPath $Leaf))
  if (-not $candidate.StartsWith($releaseOutputRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing release output path outside the governed root: $Leaf"
  }
  return $candidate
}

$outDir = Join-ContainedReleaseOutputPath -Leaf $Version
$zipPath = Join-ContainedReleaseOutputPath -Leaf "stackchan_alive_$Version.zip"
$zipSidecarPath = "$zipPath.sha256"

if (Test-Path -LiteralPath $outDir) {
  Remove-Item -LiteralPath $outDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$firmwareDir = Join-Path $outDir "firmware"
$displayFirmwareDir = Join-Path $firmwareDir "display_only"
$servoFirmwareDir = Join-Path $firmwareDir "servo_calibration"
$fullOnlineFirmwareDir = Join-Path $firmwareDir "full_online"
$mediaDir = Join-Path $outDir "media"
$faceArtifactDir = Join-Path $outDir "artifacts/face"
$docsDir = Join-Path $outDir "docs"
$siteDir = Join-Path $outDir "site"
$privacySiteDir = Join-Path $siteDir "privacy"
$dataDir = Join-Path $outDir "data"
$bridgeDir = Join-Path $outDir "bridge"
$bridgeModelsDir = Join-Path $bridgeDir "models"
$companionEvidenceDir = Join-Path $outDir "companion/evidence"
$provenanceDir = Join-Path $outDir "provenance"
$thirdPartyLicensesDir = Join-Path $outDir "third_party_licenses"
$toolsDir = Join-Path $outDir "tools"
New-Item -ItemType Directory -Force -Path $displayFirmwareDir, $servoFirmwareDir, $fullOnlineFirmwareDir, $mediaDir, $faceArtifactDir, $docsDir, $siteDir, $privacySiteDir, $dataDir, $bridgeDir, $bridgeModelsDir, $companionEvidenceDir, $provenanceDir, $thirdPartyLicensesDir, $toolsDir | Out-Null

$releaseRootPrefix = [System.IO.Path]::GetFullPath($outDir).TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar

function Join-ReleasePackagePath {
  param([string]$RelativePath)

  $normalized = $RelativePath.Replace("\", "/").TrimStart("/")
  if ([System.IO.Path]::IsPathRooted($normalized) -or $normalized.StartsWith("../") -or $normalized.Contains("/../")) {
    throw "Refusing unsafe package-relative path: $RelativePath"
  }
  $absolutePath = [System.IO.Path]::GetFullPath((Join-Path $outDir $normalized))
  if (-not $absolutePath.StartsWith($releaseRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing package path outside release root: $RelativePath"
  }
  return $absolutePath
}

function Copy-SourceTree {
  param(
    [string]$SourceRoot,
    [string]$DestinationRoot,
    [string[]]$ExcludedDirectoryNames = @()
  )

  function ConvertTo-ExtendedPath {
    param([string]$Path)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if ($env:OS -eq "Windows_NT" -and -not $fullPath.StartsWith("\\?\")) {
      return "\\?\$fullPath"
    }
    return $fullPath
  }

  $sourcePath = (Resolve-Path $SourceRoot).Path
  [void][System.IO.Directory]::CreateDirectory((ConvertTo-ExtendedPath $DestinationRoot))
  $excluded = @{}
  foreach ($name in $ExcludedDirectoryNames) {
    $excluded[$name] = $true
  }

  function Copy-SourceTreeDirectory {
    param(
      [string]$CurrentSource,
      [string]$CurrentDestination
    )

    [void][System.IO.Directory]::CreateDirectory((ConvertTo-ExtendedPath $CurrentDestination))
    Get-ChildItem -LiteralPath $CurrentSource -File -Force | ForEach-Object {
      $destinationFile = Join-Path $CurrentDestination $_.Name
      [System.IO.File]::Copy(
        (ConvertTo-ExtendedPath $_.FullName),
        (ConvertTo-ExtendedPath $destinationFile),
        $true
      )
    }
    Get-ChildItem -LiteralPath $CurrentSource -Directory -Force | ForEach-Object {
      if ($excluded.ContainsKey($_.Name)) {
        return
      }
      Copy-SourceTreeDirectory -CurrentSource $_.FullName -CurrentDestination (Join-Path $CurrentDestination $_.Name)
    }
  }

  Copy-SourceTreeDirectory -CurrentSource $sourcePath -CurrentDestination $DestinationRoot
}

function Copy-FirmwareSet {
  param(
    [Parameter(Mandatory = $true)][string]$Environment,
    [string]$BuildDir,
    [string]$Destination
  )

  Copy-BuildArtifacts -Environment $Environment -BuildDir $BuildDir -Destination $Destination
}

$firmwareSourceRoot = if ($builtFirmwareCache) {
  $builtFirmwareCache
} else {
  Join-Path $repoRoot ".pio/build"
}
Copy-FirmwareSet -Environment "stackchan" -BuildDir (Join-Path $firmwareSourceRoot "stackchan") -Destination $displayFirmwareDir
Copy-FirmwareSet -Environment "stackchan_servo_calibration" -BuildDir (Join-Path $firmwareSourceRoot "stackchan_servo_calibration") -Destination $servoFirmwareDir
Copy-FirmwareSet -Environment "stackchan_release_full" -BuildDir (Join-Path $firmwareSourceRoot "stackchan_release_full") -Destination $fullOnlineFirmwareDir

$mediaFiles = @(
  "docs/media/stackchan_alive_preview.png",
  "docs/media/stackchan_alive_expression_sheet.png",
  "docs/media/face_gallery.png",
  "docs/media/stackchan_alive_preview.mp4",
  "docs/media/stackchan_alive_preview.gif",
  "docs/media/stackchan_alive_speech_preview.gif"
)

$diagramFiles = @(
  "docs/media/diagrams/01-system-overview.png",
  "docs/media/diagrams/02-firmware-task-architecture.png",
  "docs/media/diagrams/03-persona-engine.png",
  "docs/media/diagrams/04-face-runtime.png",
  "docs/media/diagrams/05-motion-servo-safety.png",
  "docs/media/diagrams/06-brain-bridge-protocol.png",
  "docs/media/diagrams/08-io-abstraction-builds.png"
)

$windowsPowerShell = $releasePowerShellExecutable
$releaseToolsRoot = if ($SkipBuild) { $PSScriptRoot } else { Join-Path $releaseSourceRoot 'tools' }
$packageTrackedSourceRoot = if ($SkipBuild) { [string]$repoRoot } else { [string]$releaseSourceRoot }
& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $releaseToolsRoot "render_voice_samples.ps1")
if ($LASTEXITCODE -ne 0) {
  throw "Voice sample rendering failed."
}

foreach ($file in $mediaFiles) {
  if (-not (Test-Path -LiteralPath $file)) {
    throw "Missing preview artifact: $file"
  }
  Copy-Item -LiteralPath $file -Destination $mediaDir
}

$diagramMediaDir = Join-Path $mediaDir "diagrams"
New-Item -ItemType Directory -Force -Path $diagramMediaDir | Out-Null
foreach ($file in $diagramFiles) {
  if (-not (Test-Path -LiteralPath $file)) {
    throw "Missing architecture diagram: $file"
  }
  Copy-Item -LiteralPath $file -Destination $diagramMediaDir
}

$faceArtifactFiles = @(
  "artifacts/face/phase_a_idle_10s.gif",
  "artifacts/face/phase_a_blink_filmstrip_50ms.png",
  "artifacts/face/phase_a_unlabeled_expression_sheet.png",
  "artifacts/face/phase_b_unlabeled_expression_sheet.png",
  "artifacts/face/phase_c_idle_10s.gif",
  "artifacts/face/phase_d_idle_to_listen_filmstrip_50ms.png",
  "artifacts/face/phase_d_think_to_speak_filmstrip_50ms.png",
  "artifacts/face/phase_d_idle_to_sleep_filmstrip_50ms.png",
  "artifacts/face/phase_e_speech_reactive_6s.gif"
)

foreach ($file in $faceArtifactFiles) {
  if (-not (Test-Path -LiteralPath $file)) {
    throw "Missing Phase A face artifact: $file"
  }
  Copy-Item -LiteralPath $file -Destination $faceArtifactDir
}

$voiceMediaDir = Join-Path $mediaDir "voice"
$voiceRvcMediaDir = Join-Path $voiceMediaDir "rvc"
$voiceSidecarDir = Join-Path $voiceMediaDir "sidecars"
New-Item -ItemType Directory -Force -Path $voiceMediaDir | Out-Null
New-Item -ItemType Directory -Force -Path $voiceRvcMediaDir | Out-Null
New-Item -ItemType Directory -Force -Path $voiceSidecarDir | Out-Null
$personaPromptAssetsPath = Join-Path $outDir "persona_prompt_assets.json"
$personaPromptPython = Get-StackchanPreviewPython
& $personaPromptPython tools/export_persona_prompt_assets.py --persona spark --out $personaPromptAssetsPath | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "Persona prompt asset export failed."
}
$personaPromptAssets = Get-Content -LiteralPath $personaPromptAssetsPath -Raw | ConvertFrom-Json

foreach ($asset in @($personaPromptAssets.assets)) {
  $packagedSourcePath = Join-ReleasePackagePath ([string]$asset.source_path)
  $promptWavPath = Join-ReleasePackagePath ([string]$asset.wav_path)
  $promptSidecarPath = Join-ReleasePackagePath ([string]$asset.sidecar_path)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $packagedSourcePath), (Split-Path -Parent $promptWavPath), (Split-Path -Parent $promptSidecarPath) | Out-Null
  Copy-StackchanCommitBoundPackageFile `
    -PackageSourceRoot $packageTrackedSourceRoot `
    -RelativePath ([string]$asset.source_path) `
    -DestinationPath $packagedSourcePath
  Copy-StackchanCommitBoundPackageFile `
    -PackageSourceRoot $packageTrackedSourceRoot `
    -RelativePath ([string]$asset.source_path) `
    -DestinationPath $promptWavPath
  & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $releaseToolsRoot "generate_speech_envelope_sidecar.ps1") `
    -InputWav $promptWavPath `
    -OutputJson $promptSidecarPath
  if ($LASTEXITCODE -ne 0) {
    throw "Packaged prompt sidecar generation failed for $($asset.wav_path)."
  }
  & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $releaseToolsRoot "verify_speech_envelope_sidecar.ps1") `
    -Path $promptSidecarPath
  if ($LASTEXITCODE -ne 0) {
    throw "Packaged prompt sidecar verification failed for $($asset.sidecar_path)."
  }
}

$voiceMediaFiles = @(
  "docs/media/voice/stackchan_spark_audition_warm_slow_greeting.wav",
  "docs/media/voice/stackchan_spark_audition_bright_robot_greeting.wav",
  "docs/media/voice/stackchan_spark_audition_bright_robot_greeting.mp3",
  "docs/media/voice/stackchan_spark_thinking.mp3",
  "docs/media/voice/VOICE_SAMPLES.md",
  "docs/media/voice/VOICE_AUDITION.html"
)

foreach ($file in $voiceMediaFiles) {
  if (-not (Test-Path -LiteralPath $file)) {
    throw "Missing voice artifact: $file"
  }
  Copy-Item -LiteralPath $file -Destination $voiceMediaDir
}

$voiceRvcReadme = "media/voice/rvc/README.md"
Copy-StackchanCommitBoundPackageFile `
  -PackageSourceRoot $packageTrackedSourceRoot `
  -RelativePath $voiceRvcReadme `
  -DestinationPath (Join-Path $voiceRvcMediaDir "README.md")

$voiceRvcPayloads = @(
  [ordered]@{
    relativePath = "media/voice/rvc/model.pth"
    bytes = 57577722
    sha256 = "1A8ADDFD670CD811D1AD1EEB9E9B4FF72C5D795B1123A23E86A0C41C1DD9BF1A"
  },
  [ordered]@{
    relativePath = "media/voice/rvc/model.index"
    bytes = 99428699
    sha256 = "DA0EDB00FB15E8CEEC135B261F32E5907BA570FF0D213BEF8267EB80AB167DC2"
  }
)
$voiceRvcSourceBindings = [System.Collections.Generic.List[object]]::new()
$releaseGitCommonDir = $null
if (-not $SkipBuild) {
  $releaseGitCommonDirCandidate = (Invoke-ReleaseGit -Arguments @(
    '-C', $packageTrackedSourceRoot, 'rev-parse', '--git-common-dir')).Trim()
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($releaseGitCommonDirCandidate)) {
    throw 'Could not resolve the trusted local Git object authority for RVC packaging.'
  }
  $releaseGitCommonDir = Resolve-ReleaseBootstrapGitPath `
    -Root $packageTrackedSourceRoot -Candidate $releaseGitCommonDirCandidate
}
foreach ($entry in $voiceRvcPayloads) {
  $file = [string]$entry.relativePath
  $destination = Join-Path $voiceRvcMediaDir ([System.IO.Path]::GetFileName($file))
  if ($SkipBuild) {
    Copy-StackchanCommitBoundPackageFile `
      -PackageSourceRoot $packageTrackedSourceRoot `
      -RelativePath $file `
      -DestinationPath $destination
    $voiceRvcSourceBindings.Add([ordered]@{
      sourcePath = $file
      sourceCommit = $null
      pointerBlob = $null
      bytes = [int64](Get-Item -LiteralPath $destination).Length
      sha256 = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToUpperInvariant()
      policy = 'diagnostic-working-tree-unbound'
    }) | Out-Null
  } else {
    $pointerIndexRecord = @(Invoke-ReleaseGit -Arguments @(
      '-C', $packageTrackedSourceRoot, 'ls-files', '-v', '--', $file))
    $pointerBlob = (Invoke-ReleaseGit -Arguments @(
      '-C', $packageTrackedSourceRoot, 'rev-parse', '--verify',
      "${canonicalBuildCommit}:$file")).Trim().ToLowerInvariant()
    $pointerWorkingBlob = if ($pointerBlob -match '^[0-9a-f]{40,64}$') {
      Get-ReleaseBootstrapCanonicalBlobHash `
        -LiteralPath (Join-Path $packageTrackedSourceRoot $file) `
        -HashLength $pointerBlob.Length
    } else { '' }
    if ($pointerIndexRecord.Count -ne 1 -or
        [string]$pointerIndexRecord[0] -cne "H $file" -or
        $pointerWorkingBlob -cne $pointerBlob) {
      throw "Release packaging refuses hidden or noncanonical LFS pointer state: $file"
    }
    $binding = Copy-StackchanCommitBoundLfsPackageFile `
      -CommitPointerRoot $packageTrackedSourceRoot `
      -GitCommonDir $releaseGitCommonDir `
      -RelativePath $file `
      -DestinationPath $destination `
      -ExpectedBytes ([int64]$entry.bytes) `
      -ExpectedSha256 ([string]$entry.sha256)
    $voiceRvcSourceBindings.Add([ordered]@{
      sourcePath = [string]$binding.relativePath
      sourceCommit = $canonicalBuildCommit
      pointerBlob = $pointerBlob
      bytes = [int64]$binding.bytes
      sha256 = [string]$binding.sha256
      policy = 'offline-local-lfs-object-bound-to-commit-pointer-v1'
    }) | Out-Null
  }
}

& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $releaseToolsRoot "verify_tracked_rvc_assets.ps1") `
  -VoiceRoot $voiceRvcMediaDir
if ($LASTEXITCODE -ne 0) {
  throw "Packaged RVC asset verification failed."
}

Copy-Item -LiteralPath "README.md" -Destination $outDir
Copy-Item -LiteralPath "AGENTS.md" -Destination $outDir
Copy-Item -LiteralPath "CONTRIBUTING.md" -Destination $outDir
Copy-Item -LiteralPath "SECURITY.md" -Destination $outDir
Copy-Item -LiteralPath "CODE_OF_CONDUCT.md" -Destination $outDir
Copy-Item -LiteralPath "LICENSE" -Destination $outDir
Copy-Item -LiteralPath "docs/README.md" -Destination $docsDir
$packageReadmePath = Join-Path $outDir "README.md"
$packageReadmeText = [System.IO.File]::ReadAllText($packageReadmePath)
$packageReadmeText = ConvertTo-StackchanPackageReadmeText -Text $packageReadmeText
[System.IO.File]::WriteAllText(
  $packageReadmePath,
  $packageReadmeText,
  (New-Object System.Text.UTF8Encoding($false))
)
Copy-Item -LiteralPath "docs/ANDROID_COMPANION_SPEC.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/ANDROID_COMPANION_TEST_PLAN.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/ANDROID_PLAY_RELEASE.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/ANDROID_PLAY_POLICY_DECLARATIONS.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/ANDROID_PLAY_PRIVACY_POLICY.md" -Destination $docsDir
Copy-Item -LiteralPath "site/.nojekyll" -Destination $siteDir
Copy-Item -LiteralPath "site/index.html" -Destination $siteDir
Copy-Item -LiteralPath "site/privacy/index.html" -Destination $privacySiteDir
Copy-Item -LiteralPath "docs/BRAIN_MODEL.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/COMPANION_CROSS_PLATFORM_PLAN.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/COMPANION_APP_GAP_ANALYSIS.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/CONVERSATION_V2_ROADMAP.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/CHARACTER_LOCK.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/CREATING_PERSONAS.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/CUSTOMIZING_THE_FACE.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/DESKTOP_PYTHON_RUNTIME.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/GAP_ANALYSIS.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/JOHNNY_ALIVE_PATHWAY.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/PERSONA_PACKS.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/HARDWARE_SIMULATION.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/HARDWARE_FEATURE_ROADMAP.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/LTR553_CALIBRATION.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/LOCAL_RESEARCH_TOOLING.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/LOCAL_VISION.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/LAN_OTA.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/POWER_BLACKOUT_FORENSICS.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/SPEAKER_AUDIO_RESEARCH.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/VOICE_V2_DIRECTML.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/DEVICE_BRINGUP.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/BRIDGE_PROTOCOL.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/BRIDGE_AI_HANDOFF.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/BRIDGE_AI_QUALIFICATION.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/BRIDGE_DASHBOARD.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/FIRST_DEPLOY_STATUS.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/ARRIVAL_DAY_RUNBOOK.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/stackchan_procedural_runtime_design.pdf" -Destination $docsDir
Copy-Item -LiteralPath "docs/PRIVACY.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/PRODUCTION_READINESS.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/ARRIVAL_DAY_RUNBOOK.md" -Destination (Join-Path $outDir "ARRIVAL_DAY_RUNBOOK.md")
Copy-Item -LiteralPath "docs/RELEASE_QUICKSTART.md" -Destination (Join-Path $outDir "QUICKSTART.md")
if ($SkipBuild) {
  $diagnosticBanner = @"
> [!CAUTION]
> DIAGNOSTIC-ONLY UNQUALIFIED PACKAGE. RELEASE AND HARDWARE USE ARE FORBIDDEN.
> This package used ``-SkipBuild -AllowDirty``; firmware provenance and reproducibility are not
> proven. Do not flash it, run its hardware procedures, publish it, or use it as evidence.
> Any release or hardware language later in this copied document describes the governed workflow,
> not this diagnostic archive.

"@
  foreach ($diagnosticBannerFile in @("README.md", "QUICKSTART.md", "ARRIVAL_DAY_RUNBOOK.md", "docs/README.md")) {
    $diagnosticBannerPath = Join-Path $outDir $diagnosticBannerFile
    $diagnosticBanner + [System.IO.File]::ReadAllText($diagnosticBannerPath) |
      Set-Content -LiteralPath $diagnosticBannerPath -Encoding UTF8
  }
  @"
DIAGNOSTIC-ONLY UNQUALIFIED PACKAGE
RELEASE AND HARDWARE USE ARE FORBIDDEN

This package used -SkipBuild -AllowDirty. Firmware provenance and reproducibility were not
proven. Do not flash it, run hardware procedures from it, publish it, or use it as release or
hardware evidence. Create a governed two-cycle package from a clean immutable commit instead.
"@ | Set-Content -LiteralPath (Join-Path $outDir "DIAGNOSTIC_PACKAGE_DO_NOT_FLASH.txt") -Encoding UTF8
}
Copy-Item -LiteralPath "docs/RELEASE_PROCESS.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/ROLLOUT_CHECKLIST.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/VOICE_PERSONALITY.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md" -Destination $docsDir
Copy-Item -LiteralPath "docs/CI_ACCOUNT_BLOCK_EXCEPTION_TEMPLATE.json" -Destination $docsDir
Copy-Item -LiteralPath "docs/store-assets" -Destination $docsDir -Recurse
Copy-Item -LiteralPath "data/calibration.yaml" -Destination $dataDir
Copy-Item -LiteralPath "data/expressions.yaml" -Destination $dataDir
Copy-Item -LiteralPath "data/commands.yaml" -Destination $dataDir
Copy-Item -LiteralPath "data/voice_persona.yaml" -Destination $dataDir
Copy-Item -LiteralPath "data/voice_source_provenance.yaml" -Destination $dataDir
Copy-Item -LiteralPath "data/voice_rvc_base.yaml" -Destination $dataDir
Copy-Item -LiteralPath "data/voice_rvc_base_metadata.json" -Destination $dataDir
Copy-Item -LiteralPath "data/persona_index.json" -Destination $dataDir
$bridgePackageFiles = @(
  "README.md",
  "bridge_memory.py",
  "test_bridge_memory.py",
  "test_bridge_memory_v4.py",
  "memory_maintenance.py",
  "test_memory_maintenance.py",
  "episode_distillation.py",
  "test_episode_distillation.py",
  "memory_probe.py",
  "test_memory_probe.py",
  "memory_prefill_probe.py",
  "conversation_harness.py",
  "test_conversation_harness.py",
  "character_harness.py",
  "test_character_harness.py",
  "character_red_team.py",
  "test_character_red_team.py",
  "persona_pack.py",
  "test_persona_pack.py",
  "reference_bridge.py",
  "test_reference_bridge.py",
  "research_broker.py",
  "test_research_broker.py",
  "research_acceptance.py",
  "robot_embodiment.py",
  "test_robot_embodiment.py",
  "local_facts.py",
  "test_local_facts.py",
  "trusted_facts_smoke.py",
  "test_trusted_facts_smoke.py",
  "local_runner.py",
  "test_local_runner.py",
  "cancellation.py",
  "cancellable_process.py",
  "test_cancellable_process.py",
  "ltr553_calibration.py",
  "test_ltr553_calibration.py",
  "ota_channels.py",
  "test_ota_channels.py",
  "litert_lm_stackchan_wrapper.py",
  "test_litert_lm_stackchan_wrapper.py",
  "litert_lm_contract_smoke.py",
  "test_litert_lm_contract_smoke.py",
  "engine_probe.py",
  "test_engine_probe.py",
  "model_benchmark.py",
  "test_model_benchmark.py",
  "utterance_text.py",
  "stt_normalization.py",
  "stt_adapter.py",
  "stt_supervisor.py",
  "windows_speech_stt.py",
  "whisper_cpp_stt.py",
  "whisper_server_stt.py",
  "test_stt_adapter.py",
  "test_stt_supervisor.py",
  "test_whisper_server_stt.py",
  "tts_adapter.py",
  "test_tts_adapter.py",
  "conversation_session.py",
  "test_conversation_session.py",
  "conversation_latency.py",
  "test_conversation_latency.py",
  "conversation_latency_report.py",
  "test_conversation_latency_report.py",
  "initiative_policy.py",
  "test_initiative_policy.py",
  "room_context.py",
  "test_room_context.py",
  "ollama_room_vision.py",
  "test_ollama_room_vision.py",
  "lan_service.py",
  "test_lan_service.py",
  "bridge_ai_qualification.py",
  "test_bridge_ai_qualification.py",
  "dashboard_service.py",
  "test_dashboard_service.py",
  "ollama_stackchan_runner.py",
  "test_ollama_stackchan_runner.py",
  "pc_brain_probe.py",
  "selected_voice_tts.py",
  "windows_speech_tts.py",
  "rvc_tts.py",
  "rvc_tts_client.py",
  "rvc_worker_service.py",
  "rvc_directml_tts_client.py",
  "test_rvc_directml_tts_client.py",
  "rvc_directml_worker_service.py",
  "test_rvc_directml_worker_service.py",
  "rvc_production_tts_client.py",
  "test_rvc_production_tts_client.py",
  "voice_v2_directml_runtime.py",
  "voice_v2_directml_benchmark.py",
  "voice_v2_wire_benchmark.py",
  "voice_device_truth.py",
  "test_voice_device_truth.py",
  "vision_service.py",
  "test_vision_service.py",
  "requirements-vision.txt",
  "lan_smoke.py",
  "test_lan_smoke.py",
  "android_companion_probe.py",
  "test_android_companion_probe.py",
  "android_companion_soak.py",
  "test_android_companion_soak.py",
  "android_udp_beacon_probe.py",
  "test_android_udp_beacon_probe.py",
  "test_android_dashboard_media_gate.py",
  "hardware_simulator.py",
  "test_hardware_simulator.py",
  "prearrival_sim_check.py",
  "test_prearrival_sim_check.py"
)
foreach ($bridgeFile in $bridgePackageFiles) {
  Copy-Item -LiteralPath (Join-Path "bridge" $bridgeFile) -Destination $bridgeDir
}
Copy-Item -LiteralPath "bridge/dashboard" -Destination $bridgeDir -Recurse
Copy-Item -LiteralPath "bridge/fixtures" -Destination $bridgeDir -Recurse
Copy-Item -LiteralPath "bridge/models/README.md" -Destination $bridgeModelsDir
Copy-Item -LiteralPath "bridge/models/LICENSE" -Destination $bridgeModelsDir
Copy-Item -LiteralPath "bridge/models/face_detection_yunet_2023mar.onnx" -Destination $bridgeModelsDir

Copy-Item -LiteralPath "personas" -Destination (Join-Path $outDir "personas") -Recurse

$personaVerifierPython = Get-StackchanPreviewPython
& $personaVerifierPython tools/build_persona_index.py --check
if ($LASTEXITCODE -ne 0) {
  throw "Persona index is stale or invalid."
}
$personaStatus = & $personaVerifierPython tools/verify_persona_pack.py spark --json
$personaStatusExit = $LASTEXITCODE
$personaStatusPath = Join-Path $outDir "persona_pack_status.json"
$personaStatus | Set-Content -Path $personaStatusPath -Encoding UTF8
if ($personaStatusExit -ne 0) {
  throw "Persona pack verification failed."
}
$glowPersonaStatus = & $personaVerifierPython tools/verify_persona_pack.py glow --json
if ($LASTEXITCODE -ne 0) {
  throw "Glow persona pack verification failed: $glowPersonaStatus"
}

$characterRedTeamOutDir = Join-Path $outDir "character-red-team"
$characterRedTeamPython = Get-StackchanPreviewPython
& $characterRedTeamPython bridge/character_red_team.py --out-dir $characterRedTeamOutDir --json | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw "Character red-team dry run failed."
}

& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $releaseToolsRoot "export_voice_source_status.ps1") `
  -VoiceSourceProvenancePath (Join-Path $dataDir "voice_source_provenance.yaml") `
  -VoiceSourceProvenanceDisplayPath "data/voice_source_provenance.yaml" `
  -TemplatePath (Join-Path $docsDir "VOICE_SOURCE_PROVENANCE_TEMPLATE.md") `
  -TemplateDisplayPath "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md" `
  -OutputDir $outDir `
  -VoiceRoot (Join-Path $outDir "media/voice/rvc")
if ($LASTEXITCODE -ne 0) {
  throw "Voice source status export failed."
}

& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $releaseToolsRoot "export_rvc_voice_base_status.ps1") `
  -ManifestPath (Join-Path $dataDir "voice_rvc_base.yaml") `
  -MetadataPath (Join-Path $dataDir "voice_rvc_base_metadata.json") `
  -OutputDir $outDir `
  -VoiceRoot (Join-Path $outDir "media/voice/rvc")
if ($LASTEXITCODE -ne 0) {
  throw "RVC voice base status export failed."
}

$companionEvidenceFiles = @(
  "output/companion/c6-evidence/EVIDENCE.json",
  "output/companion/c6-evidence/EVIDENCE.md",
  "output/companion/c6-brain-supervisor/BRAIN_SUPERVISOR_SMOKE.json",
  "output/companion/c6-brain-supervisor/BRAIN_SUPERVISOR_SMOKE.md",
  "output/companion/c6-brain-supervisor/DIAGNOSTICS_EXPORT.json",
  "output/companion/c6-gui-rehearsal/GUI_REHEARSAL.json",
  "output/companion/c6-gui-rehearsal/GUI_REHEARSAL.md",
  "output/companion/c6-gui-rehearsal/DIAGNOSTICS_EXPORT.json"
)

foreach ($file in $companionEvidenceFiles) {
  if (-not (Test-Path -LiteralPath $file)) {
    throw "Missing companion C6 evidence artifact: $file"
  }
  $destination = Join-ReleasePackagePath ("companion/evidence/" + $file.Substring("output/companion/".Length))
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
  Copy-Item -LiteralPath $file -Destination $destination
}

$releaseTools = @(
  "tools/package_release.ps1",
  "tools/release_toolchain_identity.ps1",
  "tools/release_toolchain_identity_allowlist.json",
  "tools/verify_git_pack_semantics.py",
  "tools/test_git_pack_semantic_verifier.py",
  "tools/test_release_toolchain_identity_contract.ps1",
  "tools/test_release_toolchain_integration_contract.ps1",
  "tools/test_release_toolchain_documentation_contract.ps1",
  "tools/test_release_toolchain_cache_contract.ps1",
  "tools/seal_pioarduino_release_core.ps1",
  "tools/firmware_reproducibility_proof.ps1",
  "tools/test_firmware_reproducibility_proof_contract.ps1",
  "tools/firmware_reproducibility_failure.ps1",
  "tools/test_firmware_reproducibility_failure_contract.ps1",
  "tools/release_source_binding.ps1",
  "tools/release_dependency_evidence.ps1",
  "tools/test_release_dependency_evidence_contract.ps1",
  "tools/release_git_trust.ps1",
  "tools/release_ota_selector_policy.ps1",
  "tools/test_release_ota_selector_policy_contract.ps1",
  "tools/test_release_flash_snapshot_contract.ps1",
  "tools/test_release_package_verifier_trust_contract.ps1",
  "tools/test_release_source_binding_contract.ps1",
  "tools/release_zip_safety.ps1",
  "tools/flash_device.cmd",
  "tools/flash_device.ps1",
  "tools/flash_release_firmware.cmd",
  "tools/flash_release_firmware.ps1",
  "tools/flash_wifi_bridge.cmd",
  "tools/flash_wifi_bridge.ps1",
  "tools/platformio_apply_wifi_bridge_env.py",
  "tools/platformio_apply_ota_env.py",
  "tools/test_platformio_ota_env_contract.py",
  "tools/test_platformio_wifi_env_contract.py",
  "tools/upload_lan_ota.cmd",
  "tools/upload_lan_ota.ps1",
  "tools/test_lan_ota_channel_contract.ps1",
  "tools/body_sensor_validation.ps1",
  "tools/test_body_sensor_validation_contract.ps1",
  "tools/run_full_system_soak_http_motion.ps1",
  "tools/start_warm_rocm_full_system_soak.ps1",
  "tools/start_production_full_system_soak.ps1",
  "tools/check_full_system_soak_evidence.ps1",
  "tools/test_full_system_soak_evidence_contract.ps1",
  "tools/check_current_lead_reproducibility.cmd",
  "tools/check_current_lead_reproducibility.ps1",
  "tools/test_current_lead_reproducibility_contract.cmd",
  "tools/test_current_lead_reproducibility_contract.ps1",
  "tools/archive_current_lead.cmd",
  "tools/archive_current_lead.ps1",
  "tools/test_archive_current_lead_contract.cmd",
  "tools/test_archive_current_lead_contract.ps1",
  "tools/test_start_warm_rocm_full_system_soak_contract.ps1",
  "tools/test_start_production_full_system_soak_contract.ps1",
  "tools/camera_follow_wake_validation.ps1",
  "tools/test_camera_follow_wake_validation_contract.ps1",
  "tools/complete_camera_follow_wake_validation.ps1",
  "tools/test_complete_camera_follow_wake_validation_contract.ps1",
  "tools/prepare_desktop_python_runtime.cmd",
  "tools/prepare_desktop_python_runtime.ps1",
  "tools/check_desktop_python_runtime_payload.cmd",
  "tools/check_desktop_python_runtime_payload.ps1",
  "tools/test_desktop_python_runtime_payload_contract.cmd",
  "tools/test_desktop_python_runtime_payload_contract.ps1",
  "tools/export_desktop_package_evidence.cmd",
  "tools/export_desktop_package_evidence.ps1",
  "tools/test_desktop_package_launch.cmd",
  "tools/test_desktop_package_launch.ps1",
  "tools/test_desktop_package_evidence_contract.cmd",
  "tools/test_desktop_package_evidence_contract.ps1",
  "tools/check_desktop_release_signing_readiness.cmd",
  "tools/check_desktop_release_signing_readiness.ps1",
  "tools/test_desktop_release_signing_readiness_contract.ps1",
  "tools/check_release_credential_hygiene.cmd",
  "tools/check_release_credential_hygiene.ps1",
  "tools/test_release_credential_hygiene_contract.cmd",
  "tools/test_release_credential_hygiene_contract.ps1",
  "tools/download_companion_ci_candidate.cmd",
  "tools/download_companion_ci_candidate.ps1",
  "tools/test_companion_ci_candidate_contract.cmd",
  "tools/test_companion_ci_candidate_contract.ps1",
  "tools/install_desktop_companion_package.cmd",
  "tools/install_desktop_companion_package.ps1",
  "tools/check_desktop_target_install_evidence.cmd",
  "tools/check_desktop_target_install_evidence.ps1",
  "tools/test_desktop_target_install_evidence_contract.cmd",
  "tools/test_desktop_target_install_evidence_contract.ps1",
  "tools/check_desktop_v1_evidence_bundle.cmd",
  "tools/check_desktop_v1_evidence_bundle.ps1",
  "tools/test_desktop_v1_evidence_bundle_contract.cmd",
  "tools/test_desktop_v1_evidence_bundle_contract.ps1",
  "tools/check_companion_v1_evidence_bundle.cmd",
  "tools/check_companion_v1_evidence_bundle.ps1",
  "tools/test_companion_v1_evidence_bundle_contract.cmd",
  "tools/test_companion_v1_evidence_bundle_contract.ps1",
  "tools/platformio_resolver.ps1",
  "tools/check_native_toolchain.cmd",
  "tools/check_native_toolchain.ps1",
  "tools/check_android_toolchain.cmd",
  "tools/check_android_toolchain.ps1",
  "tools/check_android_play_release_readiness.cmd",
  "tools/check_android_play_release_readiness.ps1",
  "tools/check_privacy_policy_deployment.cmd",
  "tools/check_privacy_policy_deployment.ps1",
  "tools/test_privacy_policy_deployment_contract.cmd",
  "tools/test_privacy_policy_deployment_contract.ps1",
  "tools/test_android_upload_signing_contract.cmd",
  "tools/test_android_upload_signing_contract.ps1",
  "tools/test_android_emulator_launch.cmd",
  "tools/test_android_emulator_launch.ps1",
  "tools/check_android_emulator_release_evidence.cmd",
  "tools/check_android_emulator_release_evidence.ps1",
  "tools/test_android_emulator_release_evidence_contract.cmd",
  "tools/test_android_emulator_release_evidence_contract.ps1",
  "tools/check_android_play_store_evidence.cmd",
  "tools/check_android_play_store_evidence.ps1",
  "tools/check_android_v1_evidence_bundle.cmd",
  "tools/check_android_v1_evidence_bundle.ps1",
  "tools/check_android_diagnostics_export_evidence.cmd",
  "tools/check_android_diagnostics_export_evidence.ps1",
  "tools/check_companion_v1_readiness.cmd",
  "tools/check_companion_v1_readiness.ps1",
  "tools/check_companion_release_version.cmd",
  "tools/check_companion_release_version.ps1",
  "tools/test_companion_release_version_contract.cmd",
  "tools/test_companion_release_version_contract.ps1",
  "tools/export_companion_release_evidence.cmd",
  "tools/export_companion_release_evidence.ps1",
  "tools/preview_python_resolver.ps1",
  "tools/render_preview.py",
  "tools/audit_published_release.cmd",
  "tools/audit_published_release.ps1",
  "tools/publish_release.cmd",
  "tools/publish_release.ps1",
  "tools/release_asset_contract.ps1",
  "tools/verify_release_asset_contract.cmd",
  "tools/verify_release_asset_contract.ps1",
  "tools/export_github_actions_status.cmd",
  "tools/export_github_actions_status.ps1",
  "tools/new_ci_account_block_exception.cmd",
  "tools/new_ci_account_block_exception.ps1",
  "tools/export_voice_source_status.cmd",
  "tools/export_voice_source_status.ps1",
  "tools/export_rvc_voice_base_status.cmd",
  "tools/export_rvc_voice_base_status.ps1",
  "tools/export_rollout_status.cmd",
  "tools/export_rollout_status.ps1",
  "tools/setup_voice_tools.cmd",
  "tools/setup_voice_tools.ps1",
  "tools/open_voice_audition.cmd",
  "tools/open_voice_audition.ps1",
  "tools/render_voice_samples.cmd",
  "tools/render_voice_samples.ps1",
  "tools/render_rvc_audition_mp3s.cmd",
  "tools/render_rvc_audition_mp3s.ps1",
  "tools/render_rvc_auditions.ps1",
  "tools/verify_voice_samples.cmd",
  "tools/verify_voice_samples.ps1",
  "tools/verify_rvc_auditions.cmd",
  "tools/verify_rvc_auditions.ps1",
  "tools/verify_tracked_rvc_assets.cmd",
  "tools/verify_tracked_rvc_assets.ps1",
  "tools/sanitize_public_archive.cmd",
  "tools/sanitize_public_archive.ps1",
  "tools/generate_speech_envelope_sidecar.cmd",
  "tools/generate_speech_envelope_sidecar.ps1",
  "tools/generate_speech_envelope_sidecar.py",
  "tools/platformio_reproducible_build.py",
  "tools/test_firmware_reproducible_build_contract.ps1",
  "tools/platformio_generate_persona_assets.py",
  "tools/platformio_generate_voice_assets.py",
  "tools/verify_speech_envelope_sidecar.cmd",
  "tools/verify_speech_envelope_sidecar.ps1",
  "tools/generate_synthetic_hardware_evidence.cmd",
  "tools/generate_synthetic_hardware_evidence.ps1",
  "tools/add_hardware_evidence_media.cmd",
  "tools/add_hardware_evidence_media.ps1",
  "tools/check_hardware_evidence_progress.cmd",
  "tools/check_hardware_evidence_progress.ps1",
  "tools/test_android_apk_install_evidence_contract.cmd",
  "tools/test_android_apk_install_evidence_contract.ps1",
  "tools/test_android_probe_evidence_progress_contract.cmd",
  "tools/test_android_probe_evidence_progress_contract.ps1",
  "tools/test_android_rollout_status_contract.cmd",
  "tools/test_android_rollout_status_contract.ps1",
  "tools/test_android_logcat_capture_contract.cmd",
  "tools/test_android_logcat_capture_contract.ps1",
  "tools/test_android_evidence_packet_contract.cmd",
  "tools/test_android_evidence_packet_contract.ps1",
  "tools/test_strict_android_apk_evidence_contract.cmd",
  "tools/test_strict_android_apk_evidence_contract.ps1",
  "tools/test_strict_android_dashboard_evidence_contract.cmd",
  "tools/test_strict_android_dashboard_evidence_contract.ps1",
  "tools/test_strict_android_probe_evidence_contract.cmd",
  "tools/test_strict_android_probe_evidence_contract.ps1",
  "tools/test_android_play_store_evidence_contract.cmd",
  "tools/test_android_play_store_evidence_contract.ps1",
  "tools/test_android_gemma_evidence_contract.cmd",
  "tools/test_android_gemma_evidence_contract.ps1",
  "tools/test_android_v1_evidence_bundle_contract.cmd",
  "tools/test_android_v1_evidence_bundle_contract.ps1",
  "tools/prepare_device_arrival.cmd",
  "tools/prepare_device_arrival.ps1",
  "tools/run_device_preflight.cmd",
  "tools/run_device_preflight.ps1",
  "tools/run_character_harness_tests.cmd",
  "tools/run_character_harness_tests.ps1",
  "tools/run_character_red_team.cmd",
  "tools/run_character_red_team.ps1",
  "tools/create_persona_pack.cmd",
  "tools/create_persona_pack.ps1",
  "tools/create_persona_pack.py",
  "tools/build_persona_index.cmd",
  "tools/build_persona_index.ps1",
  "tools/build_persona_index.py",
  "tools/export_persona_prompt_assets.py",
  "tools/verify_persona_pack.cmd",
  "tools/verify_persona_pack.ps1",
  "tools/verify_persona_pack.py",
  "tools/run_bridge_reference_tests.cmd",
  "tools/run_bridge_reference_tests.ps1",
  "tools/run_engine_probe.cmd",
  "tools/run_engine_probe.ps1",
  "tools/run_litert_lm_smoke.cmd",
  "tools/run_litert_lm_smoke.ps1",
  "tools/run_lan_smoke.cmd",
  "tools/run_lan_smoke.ps1",
  "tools/setup_whisper_cpp.cmd",
  "tools/setup_whisper_cpp.ps1",
  "tools/start_pc_brain.cmd",
  "tools/start_pc_brain.ps1",
  "tools/start_pc_brain_directml.ps1",
  "tools/test_start_pc_brain_directml_contract.ps1",
  "tools/check_local_research.ps1",
  "tools/start_local_research.ps1",
  "tools/test_local_research_runtime_contract.ps1",
  "tools/start_local_vision.cmd",
  "tools/start_local_vision.ps1",
  "tools/test_start_local_vision_contract.ps1",
  "tools/start_whisper_server.ps1",
  "tools/test_start_whisper_server_contract.ps1",
  "tools/start_bridge_ai_supervised_qualification.ps1",
  "tools/complete_bridge_ai_supervised_qualification.ps1",
  "tools/test_bridge_ai_supervised_qualification_contract.ps1",
  "tools/start_stackchan_dashboard.cmd",
  "tools/start_stackchan_dashboard.ps1",
  "tools/install_stackchan_dashboard_shortcut.ps1",
  "tools/test_stackchan_dashboard_launcher_contract.cmd",
  "tools/test_stackchan_dashboard_launcher_contract.ps1",
  "tools/start_rvc_worker.ps1",
  "tools/setup_voice_v2_directml.ps1",
  "tools/voice_v2_directml_constraints.txt",
  "tools/start_voice_v2_directml_worker.ps1",
  "tools/run_voice_v2_directml_benchmark.ps1",
  "tools/run_voice_v2_wire_benchmark.ps1",
  "tools/start_voice_v2_supervised_validation.ps1",
  "tools/check_voice_v2_supervised_evidence.ps1",
  "tools/complete_voice_v2_supervised_validation.ps1",
  "tools/restore_voice_v2_production.ps1",
  "tools/test_voice_v2_supervised_evidence_contract.ps1",
  "tools/run_pc_brain_probe.cmd",
  "tools/collect_pc_brain_deploy_evidence.cmd",
  "tools/collect_pc_brain_deploy_evidence.ps1",
  "tools/check_pc_brain_deploy_evidence.cmd",
  "tools/check_pc_brain_deploy_evidence.ps1",
  "tools/run_pc_brain_quiet_soak.cmd",
  "tools/run_pc_brain_quiet_soak.ps1",
  "tools/check_pc_brain_quiet_soak_evidence.cmd",
  "tools/check_pc_brain_quiet_soak_evidence.ps1",
  "tools/run_selected_voice_once.cmd",
  "tools/run_selected_voice_once.ps1",
  "tools/run_android_companion_probe.cmd",
  "tools/run_android_companion_probe.ps1",
  "tools/run_android_companion_soak.cmd",
  "tools/run_android_companion_soak.ps1",
  "tools/run_android_udp_beacon_probe.cmd",
  "tools/run_android_udp_beacon_probe.ps1",
  "tools/install_android_companion_apk.cmd",
  "tools/install_android_companion_apk.ps1",
  "tools/capture_android_companion_logcat.cmd",
  "tools/capture_android_companion_logcat.ps1",
  "tools/run_prearrival_sim_check.cmd",
  "tools/run_prearrival_sim_check.ps1",
  "tools/run_hardware_simulation.cmd",
  "tools/run_hardware_simulation.ps1",
  "tools/compare_hardware_sim_baseline.cmd",
  "tools/compare_hardware_sim_baseline.ps1",
  "tools/send_speech_mouth_demo.cmd",
  "tools/send_speech_mouth_demo.ps1",
  "tools/send_speak_all_intents_demo.cmd",
  "tools/send_speak_all_intents_demo.ps1",
  "tools/send_bridge_replay_demo.cmd",
  "tools/send_bridge_replay_demo.ps1",
  "tools/share_release.cmd",
  "tools/share_release.ps1",
  "tools/start_hardware_evidence.cmd",
  "tools/start_hardware_evidence.ps1",
  "tools/stop_share.cmd",
  "tools/stop_share.ps1",
  "tools/verify_hardware_evidence.cmd",
  "tools/verify_hardware_evidence.ps1",
  "tools/verify_consumer_promotion.cmd",
  "tools/verify_consumer_promotion.ps1",
  "tools/test_consumer_promotion_contract.ps1",
  "tools/verify_published_release.cmd",
  "tools/verify_published_release.ps1",
  "tools/verify_architecture.cmd",
  "tools/verify_architecture.ps1",
  "tools/verify_preview_media.cmd",
  "tools/verify_preview_media.ps1",
  "tools/verify_face_phase_a.cmd",
  "tools/verify_face_phase_a.ps1",
  "tools/verify_face_phase_b.cmd",
  "tools/verify_face_phase_b.ps1",
  "tools/verify_face_phase_c.cmd",
  "tools/verify_face_phase_c.ps1",
  "tools/verify_face_phase_d.cmd",
  "tools/verify_face_phase_d.ps1",
  "tools/verify_face_phase_e.cmd",
  "tools/verify_face_phase_e.ps1",
  "tools/verify_rvc_voice_base.cmd",
  "tools/verify_rvc_voice_base.ps1",
  "tools/verify_release_package.cmd",
  "tools/verify_release_package.ps1",
  "tools/verify_share_release.cmd",
  "tools/verify_share_release.ps1",
  "tools/provision_stackchan_wifi.cmd",
  "tools/provision_stackchan_wifi.ps1",
  "tools/check_android_controls_evidence.cmd",
  "tools/check_android_controls_evidence.ps1",
  "tools/check_android_gemma_evidence.cmd",
  "tools/check_android_gemma_evidence.ps1",
  "tools/check_android_pairing_evidence.cmd",
  "tools/check_android_pairing_evidence.ps1",
  "tools/check_android_screen_off_soak_evidence.cmd",
  "tools/check_android_screen_off_soak_evidence.ps1",
  "tools/check_android_speech_evidence.cmd",
  "tools/check_android_speech_evidence.ps1",
  "tools/check_android_wifi_evidence.cmd",
  "tools/check_android_wifi_evidence.ps1",
  "tools/test_android_controls_evidence_contract.cmd",
  "tools/test_android_controls_evidence_contract.ps1",
  "tools/test_android_diagnostics_export_evidence_contract.cmd",
  "tools/test_android_diagnostics_export_evidence_contract.ps1",
  "tools/test_android_pairing_evidence_contract.cmd",
  "tools/test_android_pairing_evidence_contract.ps1",
  "tools/test_android_screen_off_soak_evidence_contract.cmd",
  "tools/test_android_screen_off_soak_evidence_contract.ps1",
  "tools/test_android_speech_evidence_contract.cmd",
  "tools/test_android_speech_evidence_contract.ps1",
  "tools/test_android_wifi_evidence_contract.cmd",
  "tools/test_android_wifi_evidence_contract.ps1",
  "tools/check_voice_source_readiness.ps1",
  "tools/test_voice_source_readiness_contract.ps1",
  "tools/searxng/compose.yaml",
  "tools/searxng/settings.yml"
)

foreach ($file in $releaseTools) {
  if (-not (Test-Path -LiteralPath $file)) {
    throw "Missing release tool: $file"
  }
  $relativeToolPath = $file.Substring("tools/".Length).Replace('/', [System.IO.Path]::DirectorySeparatorChar)
  $toolDestination = Join-Path $toolsDir $relativeToolPath
  $toolDestinationParent = Split-Path -Parent $toolDestination
  if (-not (Test-Path -LiteralPath $toolDestinationParent -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $toolDestinationParent | Out-Null
  }
  Copy-Item -LiteralPath $file -Destination $toolDestination
}

Copy-Item -LiteralPath "platformio.ini" -Destination $provenanceDir
Copy-Item -LiteralPath "partitions_esp_sr_16.csv" -Destination $provenanceDir
Copy-Item -LiteralPath "requirements-preview.txt" -Destination $provenanceDir
Copy-Item -LiteralPath "requirements-firmware-release.txt" -Destination $provenanceDir
Copy-Item -LiteralPath ".github/workflows/firmware.yml" -Destination $provenanceDir
Copy-Item -LiteralPath ".github/workflows/release.yml" -Destination $provenanceDir
Copy-Item -LiteralPath ".github/workflows/pages.yml" -Destination $provenanceDir
Copy-Item -LiteralPath ".github/workflows/companion-signing-readiness.yml" -Destination $provenanceDir
Copy-Item -LiteralPath "src" -Destination (Join-Path $provenanceDir "src") -Recurse
Copy-SourceTree -SourceRoot "bridge" -DestinationRoot (Join-Path $provenanceDir "bridge") -ExcludedDirectoryNames @("__pycache__")
Copy-Item -LiteralPath "protocol-fixtures" -Destination (Join-Path $provenanceDir "protocol-fixtures") -Recurse
Copy-Item -LiteralPath "personas" -Destination (Join-Path $provenanceDir "personas") -Recurse
Copy-Item -LiteralPath "test" -Destination (Join-Path $provenanceDir "test") -Recurse
Copy-SourceTree -SourceRoot "companion" -DestinationRoot (Join-Path $provenanceDir "companion") -ExcludedDirectoryNames @("build", ".gradle", ".kotlin")
$dataProvenanceDir = Join-Path $provenanceDir "data"
New-Item -ItemType Directory -Force -Path $dataProvenanceDir | Out-Null
Copy-Item -LiteralPath "data/commands.yaml" -Destination $dataProvenanceDir
$audioFixtureProvenanceDir = Join-Path $provenanceDir "test/fixtures/audio"
New-Item -ItemType Directory -Force -Path $audioFixtureProvenanceDir | Out-Null
foreach ($fixture in @(
  "test/fixtures/audio/speech_right.wav",
  "test/fixtures/audio/speech_left.wav",
  "test/fixtures/audio/music_center.wav",
  "test/fixtures/audio/fan_noise.wav"
)) {
  if (-not (Test-Path -LiteralPath $fixture)) {
    throw "Missing P3 audio saliency fixture: $fixture"
  }
  Copy-Item -LiteralPath $fixture -Destination $audioFixtureProvenanceDir
}

function Invoke-CapturedText {
  param(
    [scriptblock]$Command
  )

  $oldEncoding = $env:PYTHONIOENCODING
  $env:PYTHONIOENCODING = "utf-8"
  try {
    $output = & $Command 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "Command failed while generating dependency provenance: $($output | Out-String)"
    }
    return ($output | Out-String).TrimEnd()
  } finally {
    $env:PYTHONIOENCODING = $oldEncoding
  }
}

function Get-DeclaredLibDeps {
  $platformioLines = Get-Content -LiteralPath "platformio.ini"
  $libDeps = @()
  $insideLibDeps = $false

  foreach ($line in $platformioLines) {
    if ($line -match "^\s*lib_deps\s*=") {
      $insideLibDeps = $true
      continue
    }

    if ($insideLibDeps) {
      if ($line -match "^\s*\S+\s*=" -or $line -match "^\[.+\]") {
        $insideLibDeps = $false
      } elseif ($line -match "^\s+(.+?)\s*$") {
        $dep = $Matches[1].Trim()
        if (-not [string]::IsNullOrWhiteSpace($dep) -and -not $dep.StartsWith('$')) {
          $libDeps += $dep
        }
      }
    }
  }

  return @($libDeps)
}

function Copy-LicenseEvidenceTree {
  param(
    [string]$SourceRoot,
    [string]$DestinationRoot
  )

  if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
    return 0
  }

  $sourcePath = (Resolve-Path -LiteralPath $SourceRoot).Path.TrimEnd("\", "/")
  $count = 0
  foreach ($file in Get-ChildItem -LiteralPath $sourcePath -Recurse -File -Force -ErrorAction SilentlyContinue) {
    if ($file.Name -notmatch '(?i)^(LICENSE|LICENCE|COPYING|NOTICE)(\..*)?$') {
      continue
    }
    $relative = $file.FullName.Substring($sourcePath.Length + 1)
    $destination = Join-Path $DestinationRoot $relative
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
    Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
    $count++
  }
  return $count
}

function Copy-EnvironmentLicenseEvidence {
  param(
    [string]$Environment,
    [object[]]$ResolvedPackages,
    [string]$PlatformSourceLeaf,
    [string]$DependencySnapshotRoot
  )

  $destination = Join-Path $thirdPartyLicensesDir $Environment
  New-Item -ItemType Directory -Force -Path $destination | Out-Null
  if (-not [string]::IsNullOrWhiteSpace($DependencySnapshotRoot)) {
    $exactEnvironmentRoot = Join-Path $DependencySnapshotRoot $Environment
    if (-not (Test-Path -LiteralPath $exactEnvironmentRoot -PathType Container)) {
      throw "Missing exact cycle-b dependency snapshot for $Environment"
    }
    Get-ChildItem -LiteralPath $exactEnvironmentRoot -Force | Where-Object {
      $_.Name -notin @(
        'pkg-list.txt', 'pkg-list-verbose.txt', 'platformio-version.txt',
        'core-package-names.json', 'platform-source.json')
    } | ForEach-Object {
      Copy-Item -LiteralPath $_.FullName -Destination $destination -Recurse -Force
    }
    return @(
      Get-ChildItem -LiteralPath $destination -Recurse -File -Force |
        Where-Object { $_.Name -match '(?i)^(LICENSE|LICENCE|COPYING|NOTICE)(\..*)?$' }
    ).Count
  }

  $count = Copy-LicenseEvidenceTree `
    -SourceRoot (Join-Path $repoRoot ".pio/libdeps/$Environment") `
    -DestinationRoot (Join-Path $destination "libdeps")

  $coreDir = Get-ReleasePlatformioCoreDir -Environment $Environment
  if ($PlatformSourceLeaf -notmatch '^[A-Za-z0-9][A-Za-z0-9._@-]*$') {
    throw "Unsafe PlatformIO platform source leaf for $Environment`: $PlatformSourceLeaf"
  }
  $platformRoot = Join-Path $coreDir "platforms/$PlatformSourceLeaf"
  $count += Copy-LicenseEvidenceTree `
    -SourceRoot $platformRoot `
    -DestinationRoot (Join-Path $destination "platform/$PlatformSourceLeaf")
  foreach ($metadataName in @("platform.json", "package.json")) {
    $metadataPath = Join-Path $platformRoot $metadataName
    if (Test-Path -LiteralPath $metadataPath -PathType Leaf) {
      $metadataDestination = Join-Path $destination "platform/$PlatformSourceLeaf/$metadataName"
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $metadataDestination) | Out-Null
      Copy-Item -LiteralPath $metadataPath -Destination $metadataDestination -Force
    }
  }

  $packageNames = @(
    $ResolvedPackages |
      Where-Object { $_.kind -eq "package" } |
      ForEach-Object { [string]$_.name } |
      Sort-Object -Unique
  )
  foreach ($packageName in $packageNames) {
    $packageRoot = Join-Path $coreDir "packages/$packageName"
    if (-not (Test-Path -LiteralPath $packageRoot -PathType Container)) {
      continue
    }
    $packageDestination = Join-Path $destination "packages/$packageName"
    $count += Copy-LicenseEvidenceTree -SourceRoot $packageRoot -DestinationRoot $packageDestination
    $packageMetadata = Join-Path $packageRoot "package.json"
    if (Test-Path -LiteralPath $packageMetadata -PathType Leaf) {
      New-Item -ItemType Directory -Force -Path $packageDestination | Out-Null
      Copy-Item -LiteralPath $packageMetadata -Destination (Join-Path $packageDestination "package.json") -Force
    }
  }

  return $count
}

function Test-GitRequirement {
  param([string]$Value)
  return $Value -match "(?i)(git\+|\.git($|[#@\s])|github\.com/.+\.git)"
}

function Test-PinnedGitRequirement {
  param([string]$Value)
  if (-not (Test-GitRequirement $Value)) {
    return $true
  }
  return $Value -match "#[A-Za-z0-9_.-]+$"
}

function Get-DependencyAudit {
  param(
    [string[]]$DeclaredLibDeps,
    [object[]]$DisplayResolvedPackages,
    [object[]]$ServoResolvedPackages,
    [object[]]$FullResolvedPackages
  )

  $directGitDepsMissingRef = @(
    $DeclaredLibDeps |
      Where-Object { (Test-GitRequirement $_) -and -not (Test-PinnedGitRequirement $_) }
  )

  $allResolved = @()
  foreach ($entry in $DisplayResolvedPackages) {
    $allResolved += [pscustomobject][ordered]@{
      environment = "stackchan"
      kind = $entry.kind
      name = $entry.name
      version = $entry.version
      required = $entry.required
    }
  }
  foreach ($entry in $ServoResolvedPackages) {
    $allResolved += [pscustomobject][ordered]@{
      environment = "stackchan_servo_calibration"
      kind = $entry.kind
      name = $entry.name
      version = $entry.version
      required = $entry.required
    }
  }
  foreach ($entry in $FullResolvedPackages) {
    $allResolved += [pscustomobject][ordered]@{
      environment = "stackchan_release_full"
      kind = $entry.kind
      name = $entry.name
      version = $entry.version
      required = $entry.required
    }
  }

  $duplicateResolvedPackages = @()
  foreach ($envGroup in ($allResolved | Group-Object environment)) {
    foreach ($nameGroup in ($envGroup.Group | Group-Object name)) {
      if ($nameGroup.Count -gt 1) {
        $duplicateResolvedPackages += [pscustomobject][ordered]@{
          environment = $envGroup.Name
          name = $nameGroup.Name
          count = $nameGroup.Count
          entries = @($nameGroup.Group)
        }
      }
    }
  }

  $unpinnedGitRequirements = @(
    $allResolved |
      Where-Object { (Test-GitRequirement $_.required) -and -not (Test-PinnedGitRequirement $_.required) }
  )

  $gitResolvedWithoutSha = @(
    $allResolved |
      Where-Object { (Test-GitRequirement $_.required) -and $_.version -notmatch "sha\.[0-9a-fA-F]+" }
  )

  return [ordered]@{
    policy = "Direct Git dependencies must include a ref; resolved Git dependencies must record a SHA. Known upstream transitive Git declarations are recorded for review."
    directGitDepsMissingRef = @($directGitDepsMissingRef)
    duplicateResolvedPackages = @($duplicateResolvedPackages)
    unpinnedGitRequirements = @($unpinnedGitRequirements)
    gitResolvedWithoutSha = @($gitResolvedWithoutSha)
  }
}

$platformioVersion = if ($SkipBuild) {
  Invoke-CapturedText {
    Invoke-StackchanReleasePlatformio -Environment "stackchan" -Arguments @("--version")
  }
} else {
  (Get-Content -LiteralPath (Join-Path $firmwareDependencySnapshotRoot 'stackchan/platformio-version.txt') -Raw).Trim()
}
$displayDeps = if ($SkipBuild) {
  Invoke-CapturedText {
    Invoke-StackchanReleasePlatformio -Environment "stackchan" -Arguments @("pkg", "list", "-e", "stackchan")
  }
} else {
  Get-Content -LiteralPath (Join-Path $firmwareDependencySnapshotRoot 'stackchan/pkg-list.txt') -Raw
}
$displayResolvedPackages = Convert-StackchanPioPackageList $displayDeps
$displayPlatformSourceLeaf = if ($SkipBuild) {
  $verbose = Invoke-CapturedText {
    Invoke-StackchanReleasePlatformio -Environment 'stackchan' `
      -Arguments @('pkg', 'list', '-e', 'stackchan', '-v')
  }
  (Get-StackchanVerbosePlatformSource -VerbosePackageList $verbose `
    -PlatformioCoreDir (Get-ReleasePlatformioCoreDir -Environment 'stackchan')).sourceLeaf
} else {
  [string](Get-Content -LiteralPath (Join-Path $firmwareDependencySnapshotRoot 'stackchan/platform-source.json') -Raw | ConvertFrom-Json).sourceLeaf
}
$displayCorePackageNames = if ($SkipBuild) {
  @(Get-StackchanResolvedCorePackageNames -ResolvedPackages $displayResolvedPackages `
    -CorePackagesRoot (Join-Path (Get-ReleasePlatformioCoreDir -Environment 'stackchan') 'packages'))
} else {
  @(Get-Content -LiteralPath (Join-Path $firmwareDependencySnapshotRoot 'stackchan/core-package-names.json') -Raw | ConvertFrom-Json)
}
$displayLicenseCount = Copy-EnvironmentLicenseEvidence `
  -Environment "stackchan" `
  -ResolvedPackages $displayResolvedPackages `
  -PlatformSourceLeaf $displayPlatformSourceLeaf `
  -DependencySnapshotRoot $firmwareDependencySnapshotRoot
$servoDeps = if ($SkipBuild) {
  Invoke-CapturedText {
    Invoke-StackchanReleasePlatformio -Environment "stackchan_servo_calibration" -Arguments @("pkg", "list", "-e", "stackchan_servo_calibration")
  }
} else {
  Get-Content -LiteralPath (Join-Path $firmwareDependencySnapshotRoot 'stackchan_servo_calibration/pkg-list.txt') -Raw
}
$servoResolvedPackages = Convert-StackchanPioPackageList $servoDeps
$servoPlatformSourceLeaf = if ($SkipBuild) {
  $verbose = Invoke-CapturedText {
    Invoke-StackchanReleasePlatformio -Environment 'stackchan_servo_calibration' `
      -Arguments @('pkg', 'list', '-e', 'stackchan_servo_calibration', '-v')
  }
  (Get-StackchanVerbosePlatformSource -VerbosePackageList $verbose `
    -PlatformioCoreDir (Get-ReleasePlatformioCoreDir -Environment 'stackchan_servo_calibration')).sourceLeaf
} else {
  [string](Get-Content -LiteralPath (Join-Path $firmwareDependencySnapshotRoot 'stackchan_servo_calibration/platform-source.json') -Raw | ConvertFrom-Json).sourceLeaf
}
$servoCorePackageNames = if ($SkipBuild) {
  @(Get-StackchanResolvedCorePackageNames -ResolvedPackages $servoResolvedPackages `
    -CorePackagesRoot (Join-Path (Get-ReleasePlatformioCoreDir -Environment 'stackchan_servo_calibration') 'packages'))
} else {
  @(Get-Content -LiteralPath (Join-Path $firmwareDependencySnapshotRoot 'stackchan_servo_calibration/core-package-names.json') -Raw | ConvertFrom-Json)
}
$servoLicenseCount = Copy-EnvironmentLicenseEvidence `
  -Environment "stackchan_servo_calibration" `
  -ResolvedPackages $servoResolvedPackages `
  -PlatformSourceLeaf $servoPlatformSourceLeaf `
  -DependencySnapshotRoot $firmwareDependencySnapshotRoot
$fullDeps = if ($SkipBuild) {
  Invoke-CapturedText {
    Invoke-StackchanReleasePlatformio -Environment "stackchan_release_full" -Arguments @("pkg", "list", "-e", "stackchan_release_full")
  }
} else {
  Get-Content -LiteralPath (Join-Path $firmwareDependencySnapshotRoot 'stackchan_release_full/pkg-list.txt') -Raw
}
$fullResolvedPackages = Convert-StackchanPioPackageList $fullDeps
$fullPlatformSourceLeaf = if ($SkipBuild) {
  $verbose = Invoke-CapturedText {
    Invoke-StackchanReleasePlatformio -Environment 'stackchan_release_full' `
      -Arguments @('pkg', 'list', '-e', 'stackchan_release_full', '-v')
  }
  (Get-StackchanVerbosePlatformSource -VerbosePackageList $verbose `
    -PlatformioCoreDir (Get-ReleasePlatformioCoreDir -Environment 'stackchan_release_full')).sourceLeaf
} else {
  [string](Get-Content -LiteralPath (Join-Path $firmwareDependencySnapshotRoot 'stackchan_release_full/platform-source.json') -Raw | ConvertFrom-Json).sourceLeaf
}
$fullCorePackageNames = if ($SkipBuild) {
  @(Get-StackchanResolvedCorePackageNames -ResolvedPackages $fullResolvedPackages `
    -CorePackagesRoot (Join-Path (Get-ReleasePlatformioCoreDir -Environment 'stackchan_release_full') 'packages'))
} else {
  @(Get-Content -LiteralPath (Join-Path $firmwareDependencySnapshotRoot 'stackchan_release_full/core-package-names.json') -Raw | ConvertFrom-Json)
}
$fullLicenseCount = Copy-EnvironmentLicenseEvidence `
  -Environment "stackchan_release_full" `
  -ResolvedPackages $fullResolvedPackages `
  -PlatformSourceLeaf $fullPlatformSourceLeaf `
  -DependencySnapshotRoot $firmwareDependencySnapshotRoot
$visionLicenseDir = Join-Path $thirdPartyLicensesDir "models/opencv-zoo-yunet"
New-Item -ItemType Directory -Force -Path $visionLicenseDir | Out-Null
Copy-Item -LiteralPath "bridge/models/LICENSE" -Destination (Join-Path $visionLicenseDir "LICENSE") -Force
Copy-Item -LiteralPath "bridge/models/README.md" -Destination (Join-Path $visionLicenseDir "README.md") -Force

$thirdPartyLicenseFiles = @(
  Get-ChildItem -LiteralPath $thirdPartyLicensesDir -Recurse -File -Force |
    Sort-Object FullName
)
$thirdPartyLicenseIndex = @($thirdPartyLicenseFiles | ForEach-Object {
  [ordered]@{
    path = $_.FullName.Substring($thirdPartyLicensesDir.Length + 1).Replace("\", "/")
    bytes = $_.Length
    sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  }
})
$thirdPartyLicenseIndex | ConvertTo-Json -Depth 5 | Set-Content `
  -LiteralPath (Join-Path $thirdPartyLicensesDir "files.json") `
  -Encoding UTF8

@"
# Third-Party Notices

This release package includes third-party source and binary components. Their installed license,
licence, copying, notice, and package-metadata files are preserved under
``third_party_licenses/`` and hash-indexed in ``third_party_licenses/files.json``.

- ``stackchan`` captured license files: $displayLicenseCount
- ``stackchan_servo_calibration`` captured license files: $servoLicenseCount
- ``stackchan_release_full`` captured license files: $fullLicenseCount
- OpenCV Zoo YuNet model: verbatim MIT license and source/hash record included

The pioarduino platform declares Apache-2.0. Arduino-ESP32 3.3.6 package metadata declares
LGPL-2.1-or-later. Direct libraries include MIT and Apache-2.0 components; M5GFX also carries
embedded BSD and font-license notices, which are retained from its installed tree.

These notices describe third-party components only. They do not select or grant a license for
Stackchan: Alive itself. Review ``dependency_lock.json`` for exact versions and resolved sources.
This inventory is release evidence, not legal advice.
"@ | Set-Content -LiteralPath (Join-Path $outDir "THIRD_PARTY_NOTICES.md") -Encoding UTF8

$previewRequirements = (Get-Content -LiteralPath "requirements-preview.txt" -Raw).TrimEnd()
$previewRequirementEntries = @(
  Get-Content -LiteralPath "requirements-preview.txt" |
    ForEach-Object { $_.Trim() } |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and -not $_.StartsWith("#") }
)
$declaredLibDeps = Get-DeclaredLibDeps
$dependencyAudit = Get-DependencyAudit `
  -DeclaredLibDeps $declaredLibDeps `
  -DisplayResolvedPackages $displayResolvedPackages `
  -ServoResolvedPackages $servoResolvedPackages `
  -FullResolvedPackages $fullResolvedPackages

@"
# Dependency Provenance

Version: $Version
Commit: $commit
Generated UTC: $((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ"))

$(if ($SkipBuild) {
  'This diagnostic report inventories the current local dependency state only. It is unbound to the copied firmware and cannot authorize release or hardware use.'
} else {
  'This report records the exact cycle-B dependency inventory and license metadata captured from the build worktree that generated the proved firmware. The commit-bound source configuration is copied under ``provenance/``.'
})

## Tooling

``````text
$platformioVersion
``````

## Preview Python Requirements

``````text
$previewRequirements
``````

## PlatformIO Dependencies: stackchan

``````text
$displayDeps
``````

## PlatformIO Dependencies: stackchan_servo_calibration

``````text
$servoDeps
``````

## PlatformIO Dependencies: stackchan_release_full

``````text
$fullDeps
``````

## Dependency Audit

Policy: $($dependencyAudit.policy)

Direct Git dependencies missing refs: $(@($dependencyAudit.directGitDepsMissingRef).Count)

Duplicate resolved package names: $(@($dependencyAudit.duplicateResolvedPackages).Count)

Unpinned upstream Git requirements: $(@($dependencyAudit.unpinnedGitRequirements).Count)

Resolved Git packages without SHA evidence: $(@($dependencyAudit.gitResolvedWithoutSha).Count)

The current upstream ``stackchan-arduino`` manifest declares ``SCServo`` through an unpinned Git URL. This project also declares ``SCServo#ee6ee4a`` directly, and the release verifier requires every resolved Git package to record a SHA in ``dependency_lock.json``.
"@ | Set-Content -Path (Join-Path $outDir "DEPENDENCIES.md") -Encoding UTF8

$dependencyLock = [ordered]@{
  schema = "stackchan.dependency-lock.v1"
  version = $Version
  commit = $commit
  generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  dependencyEvidencePolicy = if ($SkipBuild) { "diagnostic-current-state-unbound" } else { "exact-cycle-b-build-snapshot" }
  dependencySourceCommit = if ($SkipBuild) { $null } else { $canonicalBuildCommit }
  dependencySourceEpoch = if ($SkipBuild) { $null } else { $canonicalBuildEpoch }
  platformioCore = $platformioVersion
  previewRequirements = @($previewRequirementEntries)
  declaredLibDeps = @($declaredLibDeps)
  environments = [ordered]@{
    stackchan = [ordered]@{
      board = "m5stack-cores3"
      framework = "arduino"
      platform = "espressif32@7.0.1"
      platformSourceLeaf = $displayPlatformSourceLeaf
      resolvedPackages = @($displayResolvedPackages)
      corePackageNames = @($displayCorePackageNames)
    }
    stackchan_servo_calibration = [ordered]@{
      board = "m5stack-cores3"
      framework = "arduino"
      platform = "espressif32@7.0.1"
      platformSourceLeaf = $servoPlatformSourceLeaf
      resolvedPackages = @($servoResolvedPackages)
      corePackageNames = @($servoCorePackageNames)
    }
    stackchan_release_full = [ordered]@{
      board = "m5stack-cores3"
      framework = "arduino"
      platform = "pioarduino/platform-espressif32@55.03.36"
      platformSourceLeaf = $fullPlatformSourceLeaf
      resolvedPackages = @($fullResolvedPackages)
      corePackageNames = @($fullCorePackageNames)
    }
  }
  dependencyAudit = $dependencyAudit
}
$dependencyLock | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $outDir "dependency_lock.json") -Encoding UTF8

function ConvertTo-CanonicalPackageInventory {
  param(
    [Parameter(Mandatory = $true)][string[]]$PackagePaths,
    [Parameter(Mandatory = $true)][ValidateSet("tools", "provenance")][string]$RequiredPrefix
  )

  $canonicalPaths = [System.Collections.Generic.List[string]]::new()
  $caseInsensitivePaths = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
  foreach ($packagePath in $PackagePaths) {
    $normalized = ([string]$packagePath).Replace('\', '/')
    $segments = @($normalized.Split('/'))
    if ([string]::IsNullOrWhiteSpace($normalized) -or
        [System.IO.Path]::IsPathRooted($normalized) -or
        $normalized.StartsWith('/') -or
        $segments.Count -lt 2 -or
        $segments[0] -cne $RequiredPrefix -or
        @($segments | Where-Object { [string]::IsNullOrWhiteSpace($_) -or $_ -in @('.', '..') }).Count -ne 0) {
      throw "Package inventory contains an invalid $RequiredPrefix path: $packagePath"
    }
    if (-not $caseInsensitivePaths.Add($normalized)) {
      throw "Package inventory contains a duplicate or case-colliding path: $normalized"
    }
    $canonicalPaths.Add($normalized)
  }

  $result = [string[]]$canonicalPaths.ToArray()
  [Array]::Sort($result, [System.StringComparer]::Ordinal)
  return @($result)
}

function Get-CanonicalPackageFileInventory {
  param(
    [Parameter(Mandatory = $true)][string]$Directory,
    [Parameter(Mandatory = $true)][ValidateSet("tools", "provenance")][string]$PackagePrefix
  )

  $resolvedDirectory = (Resolve-Path -LiteralPath $Directory).Path.TrimEnd('\', '/')
  $directoryPrefix = $resolvedDirectory + [System.IO.Path]::DirectorySeparatorChar
  $packagePaths = @(
    Get-ChildItem -LiteralPath $resolvedDirectory -File -Recurse -Force | ForEach-Object {
      $fullPath = [System.IO.Path]::GetFullPath($_.FullName)
      if (-not $fullPath.StartsWith($directoryPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Packaged file escaped its inventory root: $fullPath"
      }
      $relativePath = $fullPath.Substring($directoryPrefix.Length).Replace('\', '/')
      "$PackagePrefix/$relativePath"
    }
  )
  return @(ConvertTo-CanonicalPackageInventory -PackagePaths $packagePaths -RequiredPrefix $PackagePrefix)
}

$includedToolsInventory = @(Get-CanonicalPackageFileInventory -Directory $toolsDir -PackagePrefix "tools")
$provenanceFileInventory = @(Get-CanonicalPackageFileInventory -Directory $provenanceDir -PackagePrefix "provenance")

$manifest = [ordered]@{
  version = $Version
  commit = $commit
  commitRole = if ($SkipBuild) { "package-source-only-not-firmware-identity" } else { "package-and-firmware-source" }
  shortCommit = $shortCommit
  generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  board = "m5stack-cores3"
  defaultEnvironment = "stackchan"
  includedEnvironments = @("stackchan", "stackchan_servo_calibration", "stackchan_release_full")
  firmwareReproducibility = [ordered]@{
    mechanism = if ($SkipBuild) { "unbound-preexisting-artifacts" } else { "git-commit-epoch-builtins-v1" }
    sourceCommit = if ($SkipBuild) { $null } else { $commit }
    sourceEpoch = if ($SkipBuild) { $null } else { $commitEpoch }
    hook = "tools/platformio_reproducible_build.py"
    contract = "tools/test_firmware_reproducible_build_contract.ps1"
    hookCoverage = if ($SkipBuild) { "not-run-skip-build" } else { "exactly-one-effective-hook" }
    releaseOverridePolicy = if ($SkipBuild) { "diagnostic-artifacts-unbound" } else { "release-overrides-fail-closed" }
    scope = if ($SkipBuild) {
      "unknown/unbound-skip-build; copied pre-existing outputs whose source identity is not established"
    } else {
      "same host/core paths and clean commit across distinct equal-length fixed-width prefix-mapped project roots, canonical recorded PlatformIO toolchain/configuration, and no listed ambient build overrides"
    }
    proof = $firmwareReproducibilityProof
  }
  toolchainIdentity = if ($SkipBuild) {
    [ordered]@{
      schema = 'stackchan.release-toolchain-package-evidence.v1'
      status = 'not-applicable-diagnostic-skip-build'
      allowlistSha256 = $null
      identityHelperSha256 = $null
      semanticVerifierSha256 = $null
      preExecution = @()
      postBuild = @()
    }
  } else {
    $releaseToolchainIdentityEvidence
  }
  servoDefault = if ($SkipBuild) {
    "boot and motion state unverified; copied firmware identity is unknown; do not flash"
  } else {
    "display-only and calibration flows remain safety-gated; the production full firmware starts without requesting motion or autonomous refresh; physical servo rail and torque state require fresh /debug verification"
  }
  status = if ($SkipBuild) {
    "diagnostic-only; reproducibility not proven; release and hardware validation forbidden"
  } else {
    "test-ready prerelease; hardware validation pending"
  }
  diagnosticPackage = [bool]$SkipBuild
  packageSourceIsolationPolicy = if ($SkipBuild) { "diagnostic-mutable-source-unbound" } else { "detached-clean-worktree-pinned-to-package-commit" }
  packageSourceCommit = if ($SkipBuild) { $null } else { $canonicalBuildCommit }
  packageSourceEpoch = if ($SkipBuild) { $null } else { $canonicalBuildEpoch }
  voiceRvcSourceBindings = @($voiceRvcSourceBindings)
  releaseEligible = ($releaseToolchainEligible -and (-not $SkipBuild))
  hardwareValidationEligible = ($releaseToolchainEligible -and (-not $SkipBuild))
  distributionEligible = ($releaseToolchainEligible -and (-not $SkipBuild))
  flashEligible = ($releaseToolchainEligible -and (-not $SkipBuild))
  dirty = ($sourceDirtyFiles.Count -gt 0)
  dirtyFiles = @($sourceDirtyFiles)
  generatedMediaDirtyFiles = @($generatedMediaDirtyFiles)
  dependencyReport = "DEPENDENCIES.md"
  dependencyLock = "dependency_lock.json"
  thirdPartyNotices = "THIRD_PARTY_NOTICES.md"
  thirdPartyLicenseIndex = "third_party_licenses/files.json"
  projectLicense = "Apache-2.0"
  projectLicenseFile = "LICENSE"
  readinessReport = "READINESS_REPORT.md"
  readinessReportJson = "readiness_report.json"
  ciStatusReport = "GITHUB_ACTIONS_STATUS.md"
  ciStatusReportJson = "github_actions_status.json"
  releaseAssetManifest = "release_assets.json"
  acceptanceChecklist = "RELEASE_ACCEPTANCE.md"
  acceptanceChecklistJson = "release_acceptance.json"
  androidCompanionSpec = "docs/ANDROID_COMPANION_SPEC.md"
  androidCompanionTestPlan = "docs/ANDROID_COMPANION_TEST_PLAN.md"
  androidPlayRelease = "docs/ANDROID_PLAY_RELEASE.md"
  androidPlayPolicyDeclarations = "docs/ANDROID_PLAY_POLICY_DECLARATIONS.md"
  androidPlayPrivacyPolicy = "docs/ANDROID_PLAY_PRIVACY_POLICY.md"
  androidPlayPrivacyPolicySite = "site/privacy/index.html"
  androidPlayPrivacyPolicyUrl = "https://robvanprod.github.io/stackchan_alive/privacy/"
  pagesWorkflow = "provenance/pages.yml"
  androidPlayIcon = "docs/store-assets/play/icon-512.png"
  androidPlayFeatureGraphic = "docs/store-assets/play/feature-graphic-1024x500.png"
  desktopShortcutIcon = "docs/store-assets/desktop/stackchan-alive.ico"
  companionCrossPlatformPlan = "docs/COMPANION_CROSS_PLATFORM_PLAN.md"
  conversationV2Roadmap = "docs/CONVERSATION_V2_ROADMAP.md"
  androidCompanionSource = "provenance/companion"
  agentGuide = "AGENTS.md"
  contributorGuide = "CONTRIBUTING.md"
  securityPolicy = "SECURITY.md"
  codeOfConduct = "CODE_OF_CONDUCT.md"
  docsIndex = "docs/README.md"
  brainModelGuide = "docs/BRAIN_MODEL.md"
  characterLock = "docs/CHARACTER_LOCK.md"
  faceCustomizationGuide = "docs/CUSTOMIZING_THE_FACE.md"
  gapAnalysis = "docs/GAP_ANALYSIS.md"
  johnnyAlivePathway = "docs/JOHNNY_ALIVE_PATHWAY.md"
  personaPacksGuide = "docs/PERSONA_PACKS.md"
  personaIndex = "data/persona_index.json"
  voicePersonalityGuide = "docs/VOICE_PERSONALITY.md"
  voiceV2Guide = "docs/VOICE_V2_DIRECTML.md"
  hardwareFeatureRoadmap = "docs/HARDWARE_FEATURE_ROADMAP.md"
  ltr553CalibrationGuide = "docs/LTR553_CALIBRATION.md"
  localResearchTooling = "docs/LOCAL_RESEARCH_TOOLING.md"
  localResearchChecker = "tools/check_local_research.ps1"
  localResearchStarter = "tools/start_local_research.ps1"
  localResearchCompose = "tools/searxng/compose.yaml"
  localVisionGuide = "docs/LOCAL_VISION.md"
  bodySensorValidator = "tools/body_sensor_validation.ps1"
  bodySensorValidatorContract = "tools/test_body_sensor_validation_contract.ps1"
  finalSoakRunner = "tools/run_full_system_soak_http_motion.ps1"
  finalSoakWrapper = "tools/start_warm_rocm_full_system_soak.ps1"
  productionFinalSoakWrapper = "tools/start_production_full_system_soak.ps1"
  finalSoakChecker = "tools/check_full_system_soak_evidence.ps1"
  finalSoakCheckerContract = "tools/test_full_system_soak_evidence_contract.ps1"
  currentLeadChecker = "tools/check_current_lead_reproducibility.ps1"
  currentLeadCheckerContract = "tools/test_current_lead_reproducibility_contract.ps1"
  currentLeadArchiver = "tools/archive_current_lead.ps1"
  currentLeadArchiverContract = "tools/test_archive_current_lead_contract.ps1"
  finalSoakWrapperContract = "tools/test_start_warm_rocm_full_system_soak_contract.ps1"
  productionFinalSoakWrapperContract = "tools/test_start_production_full_system_soak_contract.ps1"
  cameraFollowWakeValidator = "tools/camera_follow_wake_validation.ps1"
  cameraFollowWakeValidatorContract = "tools/test_camera_follow_wake_validation_contract.ps1"
  cameraFollowWakeCompletion = "tools/complete_camera_follow_wake_validation.ps1"
  cameraFollowWakeCompletionContract = "tools/test_complete_camera_follow_wake_validation_contract.ps1"
  consumerPromotionContract = "tools/test_consumer_promotion_contract.ps1"
  visionWorker = "bridge/vision_service.py"
  visionRequirements = "bridge/requirements-vision.txt"
  visionModel = "bridge/models/face_detection_yunet_2023mar.onnx"
  visionModelSha256 = "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4"
  includedPersonaPacks = @("spark", "glow")
  activePersona = "spark"
  activePersonaPack = "personas/spark"
  activePersonaVerification = "persona_pack_status.json"
  activePersonaPromptAssets = "persona_prompt_assets.json"
  characterRedTeamReport = "character-red-team/CHARACTER_RED_TEAM.md"
  characterRedTeamReportJson = "character-red-team/character_red_team.json"
  bridgeProtocol = "docs/BRIDGE_PROTOCOL.md"
  bridgeDashboard = "docs/BRIDGE_DASHBOARD.md"
  bridgeDashboardService = "bridge/dashboard_service.py"
  bridgeDashboardLauncher = "tools/start_stackchan_dashboard.ps1"
  privacyModel = "docs/PRIVACY.md"
  expressionProfiles = "data/expressions.yaml"
  voicePersona = "data/voice_persona.yaml"
  voiceSourceProvenanceTemplate = "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md"
  voiceSourceProvenance = "data/voice_source_provenance.yaml"
  ciAccountBlockExceptionTemplate = "docs/CI_ACCOUNT_BLOCK_EXCEPTION_TEMPLATE.json"
  voiceSourceStatusReport = "VOICE_SOURCE_STATUS.md"
  voiceSourceStatusReportJson = "voice_source_status.json"
  voiceRvcBase = "data/voice_rvc_base.yaml"
  voiceRvcBaseMetadata = "data/voice_rvc_base_metadata.json"
  voiceRvcBaseStatusReport = "RVC_VOICE_BASE_STATUS.md"
  voiceRvcBaseStatusReportJson = "rvc_voice_base_status.json"
  companionEvidenceManifest = "companion/evidence/c6-evidence/EVIDENCE.json"
  companionEvidence = @(
    "companion/evidence/c6-evidence/EVIDENCE.json",
    "companion/evidence/c6-evidence/EVIDENCE.md",
    "companion/evidence/c6-brain-supervisor/BRAIN_SUPERVISOR_SMOKE.json",
    "companion/evidence/c6-brain-supervisor/BRAIN_SUPERVISOR_SMOKE.md",
    "companion/evidence/c6-brain-supervisor/DIAGNOSTICS_EXPORT.json",
    "companion/evidence/c6-gui-rehearsal/GUI_REHEARSAL.json",
    "companion/evidence/c6-gui-rehearsal/GUI_REHEARSAL.md",
    "companion/evidence/c6-gui-rehearsal/DIAGNOSTICS_EXPORT.json"
  )
  mediaArtifacts = @(
    "media/stackchan_alive_preview.png",
    "media/stackchan_alive_expression_sheet.png",
    "media/face_gallery.png",
    "media/stackchan_alive_preview.mp4",
    "media/stackchan_alive_preview.gif",
    "media/stackchan_alive_speech_preview.gif",
    "media/diagrams/01-system-overview.png",
    "media/diagrams/02-firmware-task-architecture.png",
    "media/diagrams/03-persona-engine.png",
    "media/diagrams/04-face-runtime.png",
    "media/diagrams/05-motion-servo-safety.png",
    "media/diagrams/06-brain-bridge-protocol.png",
    "media/diagrams/08-io-abstraction-builds.png",
    "artifacts/face/phase_a_idle_10s.gif",
    "artifacts/face/phase_a_blink_filmstrip_50ms.png",
    "artifacts/face/phase_a_unlabeled_expression_sheet.png",
    "artifacts/face/phase_b_unlabeled_expression_sheet.png",
    "artifacts/face/phase_c_idle_10s.gif",
    "artifacts/face/phase_d_idle_to_listen_filmstrip_50ms.png",
    "artifacts/face/phase_d_think_to_speak_filmstrip_50ms.png",
    "artifacts/face/phase_d_idle_to_sleep_filmstrip_50ms.png",
    "artifacts/face/phase_e_speech_reactive_6s.gif",
    "media/voice/stackchan_spark_greeting.wav",
    "media/voice/stackchan_spark_thinking.wav",
    "media/voice/stackchan_spark_safety.wav",
    "media/voice/stackchan_spark_audition_warm_slow_greeting.wav",
    "media/voice/stackchan_spark_audition_bright_robot_greeting.wav",
    "media/voice/stackchan_spark_audition_bright_robot_greeting.mp3",
    "media/voice/stackchan_spark_thinking.mp3",
    "media/voice/sidecars/stackchan_spark_greeting.speech_envelope.json",
    "media/voice/sidecars/stackchan_spark_thinking.speech_envelope.json",
    "media/voice/sidecars/stackchan_spark_safety.speech_envelope.json",
    "media/voice/VOICE_SAMPLES.md",
    "media/voice/VOICE_AUDITION.html",
    "media/voice/rvc/README.md",
    "media/voice/rvc/model.pth",
    "media/voice/rvc/model.index"
  )
  includedTools = @($includedToolsInventory)
  provenanceFiles = @($provenanceFileInventory)
}

$manifest | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $outDir "release_manifest.json") -Encoding UTF8

$ciStatus = [ordered]@{
  schema = "stackchan.github-actions-status.v1"
  version = $Version
  commit = $commit
  repo = "RobVanProd/stackchan_alive"
  generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  status = if ($SkipBuild) { "diagnostic-not-applicable" } else { "post-push-check-required" }
  promotionReady = $false
  firmwareCandidateReady = $false
  externalBlock = $false
  interpretation = if ($SkipBuild) {
    "GitHub Actions candidate evidence is not applicable to an unqualified diagnostic archive. Do not push a tag or treat these files as a firmware candidate."
  } else {
    "This package was generated before the matching GitHub Actions runs could be observed. After pushing main and the release tag, run tools/export_github_actions_status.cmd to replace this placeholder with the observed GitHub Actions result."
  }
  requiredWorkflows = @(if ($SkipBuild) { @() } else { @("Firmware", "Release") })
  missingRequiredWorkflows = @(if ($SkipBuild) { @() } else { @("Firmware", "Release") })
  workflows = @()
}
$ciStatus | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $outDir "github_actions_status.json") -Encoding UTF8

if ($SkipBuild) {
@"
# GitHub Actions Status -- Diagnostic Only

Diagnostic package: $Version
Package-source commit only: $commit
Repository: RobVanProd/stackchan_alive
Status: diagnostic-not-applicable
Firmware candidate ready: False
Promotion ready: False

GitHub Actions candidate evidence is not applicable to this unqualified diagnostic archive.
Do not push a release tag or treat the copied firmware files as a candidate.

Machine-readable status: ``github_actions_status.json``
"@ | Set-Content -Path (Join-Path $outDir "GITHUB_ACTIONS_STATUS.md") -Encoding UTF8
} else {
@"
# GitHub Actions Status

Release: $Version
Commit: $commit
Repository: RobVanProd/stackchan_alive
Status: post-push-check-required
Required workflows: Firmware, Release
Firmware candidate ready: False

This package was generated before the matching GitHub Actions runs could be observed. After pushing main and the release tag, run:

    .\tools\export_github_actions_status.cmd -Version $Version -Commit $commit -OutputDir .

If GitHub reports that jobs did not start because of account billing or spending limits, keep the exported report with the release evidence and use local release verification plus device preflight as the available technical evidence until the account issue is fixed.

Machine-readable status: ``github_actions_status.json``
"@ | Set-Content -Path (Join-Path $outDir "GITHUB_ACTIONS_STATUS.md") -Encoding UTF8
}

if ($ObserveCandidateActions) {
  $actionsExporter = Join-Path $releaseToolsRoot "export_github_actions_status.ps1"
  $actionsOutput = @(
    & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -File $actionsExporter `
      -Repo "RobVanProd/stackchan_alive" `
      -Version $Version `
      -Commit $commit `
      -OutputDir $outDir `
      -RequiredWorkflows "Firmware,Release" `
      -AcceptFirmwareCandidate 2>&1
  )
  $actionsExit = $LASTEXITCODE
  $actionsOutput | ForEach-Object { Write-Host ([string]$_) }
  if ($actionsExit -ne 0) {
    throw "Exact-commit Firmware Actions evidence is not ready for candidate packaging."
  }

  $observedActions = Get-Content -LiteralPath (Join-Path $outDir "github_actions_status.json") -Raw | ConvertFrom-Json
  if ($observedActions.firmwareCandidateReady -ne $true -or $observedActions.promotionReady -ne $false) {
    throw "Observed Actions report is not the required prerelease candidate state."
  }
  if (
    $observedActions.status -ne "missing-required-workflow" -or
    @($observedActions.missingRequiredWorkflows).Count -ne 1 -or
    @($observedActions.missingRequiredWorkflows)[0] -ne "Release"
  ) {
    throw "Candidate packaging requires successful Firmware evidence with only the tag-only Release workflow pending."
  }
}

$readinessReport = [ordered]@{
  schema = "stackchan.readiness-report.v1"
  version = $Version
  commit = $commit
  commitRole = if ($SkipBuild) { "package-source-only-not-firmware-identity" } else { "package-and-firmware-source" }
  firmwareIdentity = if ($SkipBuild) { "unknown-unbound-preexisting-outputs" } else { $commit }
  generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  status = if ($SkipBuild) { "diagnostic-only-unqualified" } else { "test-ready-prerelease" }
  consumerRollout = if ($SkipBuild) { "forbidden-diagnostic-package" } else { "blocked-pending-hardware-validation" }
  diagnosticPackage = [bool]$SkipBuild
  releaseAndHardwareUse = if ($SkipBuild) { "forbidden" } else { "pending-source-matched-qualification" }
  noHardwareProof = @(
    [ordered]@{ gate = "release-package-created"; status = "pass"; evidence = "release_manifest.json" },
    [ordered]@{ gate = "firmware-binaries-present"; status = "pass"; evidence = "firmware/display_only and firmware/servo_calibration" },
    [ordered]@{ gate = "preview-media-present"; status = "pass"; evidence = "media/stackchan_alive_preview.png, media/stackchan_alive_preview.mp4, media/stackchan_alive_preview.gif" },
    [ordered]@{ gate = "voice-samples-present"; status = "pass"; evidence = "media/voice/stackchan_spark_greeting.wav, media/voice/stackchan_spark_thinking.wav, media/voice/stackchan_spark_safety.wav, warm-slow and bright-robot WAV variants, plus MP3 quick auditions" },
    [ordered]@{ gate = "voice-source-provenance-template-present"; status = "pass"; evidence = "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md and data/voice_source_provenance.yaml" },
    [ordered]@{ gate = "voice-source-status-report-present"; status = "pass"; evidence = "VOICE_SOURCE_STATUS.md and voice_source_status.json" },
    [ordered]@{ gate = "rvc-voice-base-status-report-present"; status = "pass"; evidence = "RVC_VOICE_BASE_STATUS.md and rvc_voice_base_status.json; production file hashes verified" },
    [ordered]@{ gate = "character-red-team-dry-run"; status = "pass"; evidence = "character-red-team/CHARACTER_RED_TEAM.md and character_red_team.json; real gate still requires a configured model runner" },
    [ordered]@{ gate = "companion-c6-brain-supervision-evidence"; status = "pass"; evidence = "companion/evidence/c6-evidence/EVIDENCE.json plus C6 brain supervisor, GUI rehearsal, and diagnostics exports" },
    [ordered]@{ gate = "expression-sheet-present"; status = "pass"; evidence = "media/stackchan_alive_expression_sheet.png" },
    [ordered]@{ gate = "dependency-provenance-present"; status = "pass"; evidence = "DEPENDENCIES.md and dependency_lock.json" },
    [ordered]@{ gate = "checksums-present"; status = "pass"; evidence = "SHA256SUMS.txt" },
    [ordered]@{ gate = "github-actions-status-report-present"; status = "pass"; evidence = "GITHUB_ACTIONS_STATUS.md and github_actions_status.json" },
    [ordered]@{ gate = "arrival-tools-present"; status = "pass"; evidence = "tools/prepare_device_arrival.cmd, tools/start_hardware_evidence.cmd, and tools/check_hardware_evidence_progress.cmd" },
    [ordered]@{ gate = "hardware-media-importer-present"; status = "pass"; evidence = "tools/add_hardware_evidence_media.cmd validates phone media and writes media_manifest.json" },
    [ordered]@{ gate = "servo-risk-acknowledgement-required"; status = "pass"; evidence = "tools/flash_release_firmware.ps1 requires -ConfirmServoRisk for servo_calibration" }
  )
  hardwareGates = @(
    [ordered]@{ gate = "display-only-flash"; status = "pending-device"; requiredEvidence = "display-only serial log, real photo/video, 10-minute idle observation" },
    [ordered]@{ gate = "speech-mouth-demo-evidence"; status = "pending-device"; requiredEvidence = "logs/speech_mouth_demo_serial.log with streamed speech envelope commands, speech clear, and completion; logs/speak_all_intents_serial.log with every packaged speech intent, earcon, and audio-output handoff" },
    [ordered]@{ gate = "servo-calibration"; status = "pending-device"; requiredEvidence = "supervised servo log, yaw classification, calibration values" },
    [ordered]@{ gate = "mixed-mode-soak"; status = "pending-device"; requiredEvidence = "30-minute soak log with heartbeat and runtime health markers" },
    [ordered]@{ gate = "power-cycle-recovery"; status = "pending-device"; requiredEvidence = "USB power-cycle observation marked pass" },
    [ordered]@{ gate = "target-speaker-audio-evidence"; status = "pending-device"; requiredEvidence = "completed AUDIO_REVIEW.md plus a real-device speaker recording under audio/" },
    [ordered]@{ gate = "hardware-evidence-verification"; status = "pending-device"; requiredEvidence = "tools/verify_hardware_evidence.cmd passes on the completed packet" },
    [ordered]@{ gate = "production-voice-assets"; status = "pass"; requiredEvidence = "media/voice/rvc/model.pth and model.index match the pinned production SHA-256 values" }
  )
  promotionRule = if ($SkipBuild) {
    "Diagnostic packages cannot be promoted, flashed, or used as hardware evidence. Create a governed two-cycle package from a clean immutable commit."
  } else {
    "Promotion requires source-matched supervised hardware qualification, bridge AI qualification, the required soak, successful release checks, and explicit owner approval."
  }
  nextOperatorCommand = $null
  nextOperatorGuidance = if ($SkipBuild) {
    'Diagnostic packages have no arrival or hardware authority.'
  } else {
    'Return to the exact clean trusted source checkout, define the six-value releaseToolchain splat from docs/RELEASE_PROCESS.md, and pass this ZIP to tools/prepare_device_arrival.ps1. The archive does not confer release authority.'
  }
}

if ($SkipBuild) {
  foreach ($gate in @($readinessReport.noHardwareProof)) {
    $gate["status"] = "not-qualified-diagnostic"
    $gate["evidence"] = "Present only for diagnostic inspection; not accepted as release evidence"
  }
  $readinessReport.noHardwareProof[0]["gate"] = "diagnostic-archive-created"
  $readinessReport.noHardwareProof[1]["gate"] = "unbound-preexisting-firmware-files-present"
  foreach ($gate in @($readinessReport.hardwareGates)) {
    $gate["status"] = "forbidden-diagnostic"
    $gate["requiredEvidence"] = "Create and verify a governed two-cycle clean package before any hardware use"
  }
}

$readinessReport | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $outDir "readiness_report.json") -Encoding UTF8

$acceptanceChecklist = [ordered]@{
  schema = "stackchan.release-acceptance.v1"
  version = $Version
  commit = $commit
  commitRole = if ($SkipBuild) { "package-source-only-not-firmware-identity" } else { "package-and-firmware-source" }
  firmwareIdentity = if ($SkipBuild) { "unknown-unbound-preexisting-outputs" } else { $commit }
  generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  releaseClass = if ($SkipBuild) { "diagnostic-only-unqualified" } else { "test-ready-prerelease" }
  currentDecision = if ($SkipBuild) { "release-and-hardware-use-forbidden" } else { "test-ready-for-device-arrival" }
  consumerRolloutDecision = if ($SkipBuild) { "forbidden-diagnostic-package" } else { "blocked-pending-hardware-validation" }
  diagnosticPackage = [bool]$SkipBuild
  noHardwareAcceptance = @(
    [ordered]@{ requirement = "clean-release-package"; status = "pass"; evidence = "release_manifest.json" },
    [ordered]@{ requirement = "firmware-artifacts-present"; status = "pass"; evidence = "firmware/display_only and firmware/servo_calibration" },
    [ordered]@{ requirement = "dependency-provenance-present"; status = "pass"; evidence = "DEPENDENCIES.md and dependency_lock.json" },
    [ordered]@{ requirement = "checksums-present"; status = "pass"; evidence = "SHA256SUMS.txt" },
    [ordered]@{ requirement = "github-actions-status-report-present"; status = "pass"; evidence = "GITHUB_ACTIONS_STATUS.md and github_actions_status.json" },
    [ordered]@{ requirement = "visual-review-media-present"; status = "pass"; evidence = "media/stackchan_alive_preview.png, media/stackchan_alive_expression_sheet.png, media/stackchan_alive_preview.mp4" },
    [ordered]@{ requirement = "voice-review-samples-present"; status = "pass"; evidence = "media/voice/stackchan_spark_greeting.wav, media/voice/stackchan_spark_thinking.wav, media/voice/stackchan_spark_safety.wav, warm-slow and bright-robot WAV variants, plus MP3 quick auditions" },
    [ordered]@{ requirement = "voice-source-provenance-template-present"; status = "pass"; evidence = "docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md and data/voice_source_provenance.yaml" },
    [ordered]@{ requirement = "voice-source-status-report-present"; status = "pass"; evidence = "VOICE_SOURCE_STATUS.md and voice_source_status.json" },
    [ordered]@{ requirement = "rvc-voice-base-status-report-present"; status = "pass"; evidence = "RVC_VOICE_BASE_STATUS.md and rvc_voice_base_status.json; production file hashes verified" },
    [ordered]@{ requirement = "character-red-team-dry-run-present"; status = "pass"; evidence = "character-red-team/CHARACTER_RED_TEAM.md and character_red_team.json" },
    [ordered]@{ requirement = "companion-c6-brain-supervision-evidence"; status = "pass"; evidence = "companion/evidence/c6-evidence/EVIDENCE.json plus C6 brain supervisor, GUI rehearsal, and diagnostics exports" },
    [ordered]@{ requirement = "arrival-tools-present"; status = "pass"; evidence = "tools/prepare_device_arrival.cmd, tools/start_hardware_evidence.cmd, tools/check_hardware_evidence_progress.cmd, tools/verify_hardware_evidence.cmd" },
    [ordered]@{ requirement = "hardware-media-importer-present"; status = "pass"; evidence = "tools/add_hardware_evidence_media.cmd validates imported photos/videos/audio and records hashes" },
    [ordered]@{ requirement = "servo-risk-gated"; status = "pass"; evidence = "tools/flash_release_firmware.ps1 requires -ConfirmServoRisk for servo_calibration" },
    [ordered]@{ requirement = "share-page-verifiable"; status = "pass"; evidence = "tools/share_release.cmd and tools/verify_share_release.cmd" }
  )
  hardwareAcceptanceRequired = @(
    [ordered]@{ requirement = "display-only-flash"; status = "pending-device"; requiredEvidence = "display-only serial log, real photo/video, 10-minute idle observation" },
    [ordered]@{ requirement = "speech-mouth-demo-evidence"; status = "pending-device"; requiredEvidence = "logs/speech_mouth_demo_serial.log with streamed speech envelope commands, speech clear, and completion; logs/speak_all_intents_serial.log with every packaged speech intent, earcon, and audio-output handoff" },
    [ordered]@{ requirement = "servo-calibration"; status = "pending-device"; requiredEvidence = "supervised servo log, yaw classification, calibration values" },
    [ordered]@{ requirement = "mixed-mode-soak"; status = "pending-device"; requiredEvidence = "30-minute soak log with heartbeat and runtime health markers" },
    [ordered]@{ requirement = "power-cycle-recovery"; status = "pending-device"; requiredEvidence = "USB power-cycle observation marked pass" },
    [ordered]@{ requirement = "target-speaker-audio-evidence"; status = "pending-device"; requiredEvidence = "completed AUDIO_REVIEW.md plus a real-device speaker recording under audio/" },
    [ordered]@{ requirement = "hardware-evidence-verification"; status = "pending-device"; requiredEvidence = "tools/verify_hardware_evidence.cmd passes on the completed packet" },
    [ordered]@{ requirement = "production-voice-assets"; status = "pass"; requiredEvidence = "bundled model and index match the pinned production SHA-256 values" }
  )
  promotionRule = if ($SkipBuild) {
    "This diagnostic artifact cannot be promoted, flashed, or used as release or hardware evidence."
  } else {
    "This candidate remains blocked until source-matched supervised hardware qualification, bridge AI qualification, the required soak, successful release checks, and explicit owner approval."
  }
}

if ($SkipBuild) {
  foreach ($requirement in @($acceptanceChecklist.noHardwareAcceptance)) {
    $requirement["status"] = "not-accepted-diagnostic"
    $requirement["evidence"] = "Present only for diagnostic inspection; not accepted as release evidence"
  }
  $acceptanceChecklist.noHardwareAcceptance[0]["requirement"] = "diagnostic-archive-structure-present"
  $acceptanceChecklist.noHardwareAcceptance[1]["requirement"] = "unbound-preexisting-firmware-files-present"
  foreach ($requirement in @($acceptanceChecklist.hardwareAcceptanceRequired)) {
    $requirement["status"] = "forbidden-diagnostic"
    $requirement["requiredEvidence"] = "Create and verify a governed two-cycle clean package before any hardware use"
  }
}

$acceptanceChecklist | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $outDir "release_acceptance.json") -Encoding UTF8

if ($SkipBuild) {
@"
# Diagnostic Package -- No Release Acceptance

Diagnostic package: $Version
Commit: $commit
Decision: release and hardware use forbidden
Consumer rollout: forbidden diagnostic package

This package was created with ``-SkipBuild -AllowDirty``. Firmware provenance and
reproducibility were not proven. Nothing in this package is accepted as release evidence.
Do not flash it, run its hardware tools, qualify a robot with it, or publish it as a candidate.

Create a governed package from a clean immutable commit and pass its two independent clean
firmware build cycles before beginning any hardware qualification.

Machine-readable checklist: ``release_acceptance.json``
"@ | Set-Content -Path (Join-Path $outDir "RELEASE_ACCEPTANCE.md") -Encoding UTF8
} else {
@"
# Release Acceptance Checklist

Release: $Version
Commit: $commit
Decision: test-ready for device arrival
Consumer rollout: blocked pending hardware validation

## Accepted Without Hardware

- [x] Clean release package: ``release_manifest.json``
- [x] Firmware artifacts present: ``firmware/display_only`` and ``firmware/servo_calibration``
- [x] Dependency provenance present: ``DEPENDENCIES.md`` and ``dependency_lock.json``
- [x] Checksums present: ``SHA256SUMS.txt``
- [x] GitHub Actions status report present: ``GITHUB_ACTIONS_STATUS.md`` and ``github_actions_status.json``
- [x] Visual review media present: preview image, expression sheet, and preview video
- [x] Voice review samples present: Stackchan Spark greeting, thinking, safety, warm-slow audition, and bright-robot audition WAVs
- [x] Voice source provenance template present: ``docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md`` and ``data/voice_source_provenance.yaml``
- [x] Voice source status report present: ``VOICE_SOURCE_STATUS.md`` and ``voice_source_status.json``
- [x] Character red-team dry-run report present: ``character-red-team/CHARACTER_RED_TEAM.md`` and ``character-red-team/character_red_team.json``
- [x] Companion C6 brain-supervision evidence present: ``companion/evidence/c6-evidence/EVIDENCE.json``
- [x] Arrival tools present: prepare, evidence capture, and evidence verification scripts
- [x] Hardware media importer present: ``tools/add_hardware_evidence_media.cmd`` validates imported photos/videos/audio and records hashes
- [x] Evidence progress checker present: ``tools/check_hardware_evidence_progress.cmd``
- [x] Servo risk gated by explicit ``-ConfirmServoRisk``
- [x] Share page can be verified by ``tools/verify_share_release.cmd``

## Required Physical Qualification

These gates apply to this release candidate. Historical private paired-reference evidence is
recorded in ``docs/FIRST_DEPLOY_STATUS.md`` and ``docs/ARRIVAL_DAY_RUNBOOK.md``, but it applies
only to the source commit and firmware SHA-256 named by that evidence. It does not qualify this
candidate or another recipient's power source, calibration, voice model, credentials, or
assembled hardware.

- [ ] Display-only flash with serial log, real photo/video, and 10-minute idle observation
- [ ] Speech-mouth demo evidence: ``logs/speech_mouth_demo_serial.log`` with streamed speech envelope commands, ``speech clear``, and completion, plus ``logs/speak_all_intents_serial.log`` proving every packaged speech intent, earcon, and audio-output handoff
- [ ] Supervised servo calibration with yaw classification and calibration values
- [ ] 30-minute mixed idle/listen/think/speak soak with heartbeat and runtime health markers
- [ ] Power-cycle recovery: USB power-cycle observation marked pass
- [ ] Target-speaker audio evidence: completed ``AUDIO_REVIEW.md`` plus a real-device speaker recording under ``audio/``
- [ ] Completed hardware evidence packet that passes ``tools/verify_hardware_evidence.cmd``
- [x] Production RVC model and index match their pinned SHA-256 values

Owner approval has not been recorded for this candidate. Promotion remains blocked until the
source-matched physical qualification and release checks are complete.

Machine-readable checklist: ``release_acceptance.json``
"@ | Set-Content -Path (Join-Path $outDir "RELEASE_ACCEPTANCE.md") -Encoding UTF8
}

if ($SkipBuild) {
@"
# Diagnostic Readiness Report

Diagnostic package: $Version
Commit: $commit
Status: diagnostic-only unqualified
Consumer rollout: forbidden diagnostic package
Release and hardware use: forbidden

This package copied pre-existing outputs whose source identity is not established because
``-SkipBuild`` was selected. It proves no firmware identity, reproducibility, release readiness,
or physical readiness.
Do not flash it or use it as evidence. The only valid next step is to create a governed two-cycle
package from a clean immutable commit.
"@ | Set-Content -Path (Join-Path $outDir "READINESS_REPORT.md") -Encoding UTF8
} else {
@"
# Readiness Report

Release: $Version
Commit: $commit
Status: test-ready prerelease
Consumer rollout: blocked pending hardware validation

## Proven Without Hardware

- Release package is generated with a clean manifest: ``release_manifest.json``.
- Display-only and servo-calibration firmware binaries are present under ``firmware/``.
- Preview image, animation, video, and expression QA sheet are present under ``media/``.
- Dependency provenance is present in ``DEPENDENCIES.md`` and ``dependency_lock.json``.
- Package checksums are present in ``SHA256SUMS.txt`` and verified by ``tools/verify_release_package.cmd``.
- GitHub Actions status is recorded in ``GITHUB_ACTIONS_STATUS.md`` and ``github_actions_status.json``. If hosted jobs cannot start because of account billing or spending limits, local release verification and device preflight are the available technical evidence until billing is fixed.
- Production voice metadata is recorded in ``docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md`` and ``data/voice_source_provenance.yaml``; ``VOICE_SOURCE_STATUS.md`` and ``voice_source_status.json`` verify the released model and index hashes.
- Character red-team dry-run evidence is present in ``character-red-team/CHARACTER_RED_TEAM.md`` and ``character-red-team/character_red_team.json``. It proves the adversarial corpus and validator path; the gate only passes after the same suite runs with ``--require-runner`` against a configured local model.
- Companion C6 brain-supervision evidence is present under ``companion/evidence/`` and proves the desktop GUI can start the Python brain, drive simulated robot turns, stop, restart, and export diagnostics before the physical robot arrives.
- Arrival-day helpers are included under ``tools/``, including the progress checker and strict evidence verifier.
- Hardware media import helper is included as ``tools/add_hardware_evidence_media.cmd`` for copying phone photos/videos and speaker recordings into evidence packets with SHA256 hashes.
- Servo calibration flashing requires explicit ``-ConfirmServoRisk`` acknowledgement.

## Required Physical Qualification

This candidate includes the production voice. Historical private paired-reference evidence is
recorded in ``docs/FIRST_DEPLOY_STATUS.md`` and ``docs/ARRIVAL_DAY_RUNBOOK.md``, but it applies
only to the source commit and firmware SHA-256 named by that evidence. It does not qualify this
candidate or another recipient's assembled hardware, power path, calibration, credentials, or
local voice model. The following package-level gates therefore remain explicit:

- Display-only flash, visible procedural face, and 10-minute idle run.
- Speech-mouth demo evidence: ``logs/speech_mouth_demo_serial.log`` with streamed speech envelope commands, ``speech clear``, and completion, plus ``logs/speak_all_intents_serial.log`` proving every packaged speech intent, earcon, and audio-output handoff.
- Supervised servo calibration, yaw classification, and calibration values.
- 30-minute mixed idle/listen/think/speak soak.
- Power-cycle recovery: USB power-cycle observation marked pass.
- Target-speaker audio evidence: completed ``AUDIO_REVIEW.md`` plus a real-device speaker recording under ``audio/``.
- Completed hardware evidence packet that passes ``tools/verify_hardware_evidence.cmd``.
- Production RVC model and index hash verification.

Owner approval has not been recorded for this candidate. Promotion requires source-matched
supervised hardware qualification, bridge AI qualification, the required soak, successful
release checks, and explicit owner approval.

Arrival authority is intentionally not embedded in this archive. Return to the exact clean trusted
source checkout, define the six-value ``releaseToolchain`` splat from ``docs/RELEASE_PROCESS.md``,
and pass this ZIP to ``tools/prepare_device_arrival.ps1``. The archive does not confer release
authority.
"@ | Set-Content -Path (Join-Path $outDir "READINESS_REPORT.md") -Encoding UTF8
}

if ($SkipBuild) {
@"
# Stackchan: Alive $Version -- Diagnostic Package

Commit: $commit

This artifact was generated with ``-SkipBuild -AllowDirty``. Its firmware provenance and
reproducibility are not proven. It is not a prerelease candidate, is not publicly shareable as a
release, and must not be flashed, run on hardware, or used as qualification evidence.

Create a governed two-cycle package from a clean immutable commit before any release or hardware
workflow.
"@ | Set-Content -Path (Join-Path $outDir "RELEASE_NOTES.md") -Encoding UTF8
} else {
@"
# Stackchan: Alive $Version

Commit: $commit

This is the publicly shareable $Version prerelease candidate for Stackchan: Alive, a character OS for Stackchan hardware. It is built, native-tested, and compile-checked, and includes preview media plus an expression QA sheet. The production full firmware starts without requesting motion or autonomous refresh; physical servo rail and torque state require fresh /debug verification. Consumer rollout remains blocked pending source-matched physical qualification and explicit owner approval.

Dependency provenance is recorded in ``DEPENDENCIES.md`` and ``dependency_lock.json``, with copied build inputs under ``provenance/``. Production voice hashes are recorded in ``docs/VOICE_SOURCE_PROVENANCE_TEMPLATE.md``, ``data/voice_source_provenance.yaml``, ``VOICE_SOURCE_STATUS.md``, and ``voice_source_status.json``. Readiness status is recorded in ``READINESS_REPORT.md`` and ``readiness_report.json``. GitHub Actions status is recorded in ``GITHUB_ACTIONS_STATUS.md`` and ``github_actions_status.json``. Preflight, hardware simulation, flashing, publishing, evidence capture, and package verification helpers are included under ``tools/``.

Engine readiness quick check:

- Run ``tools/run_engine_probe.cmd -Json`` to check whether local model, STT, and TTS commands are configured.
- Run ``tools/run_engine_probe.cmd -RunModelSmoke -Json`` after exporting a runner command to capture the first real smoke result. This is setup evidence; full model selection still requires ``bridge/model_benchmark.py --require-runner`` with a passing ``summary.candidate_gate`` and recorded ``recommended_profile``.
- Run ``python bridge/model_benchmark.py --profile gemma4-e2b-gguf --require-runner --json`` after the real runner is configured to write ``MODEL_BENCHMARK.md/json`` with candidate blockers, ``ready_profiles``, and the fastest ready profile recommendation.
- Run ``tools/run_character_red_team.cmd -Json`` to regenerate the dry-run Character Lock red-team report. After a real runner is configured, run ``tools/run_character_red_team.cmd -RequireRunner -Json`` so the B7 gate is backed by an actual model instead of deterministic fallback responses.
- For the mobile/low-footprint brain path, configure ``STACKCHAN_LITERT_LM_COMMAND`` and use ``bridge/litert_lm_stackchan_wrapper.py`` as ``STACKCHAN_GEMMA4_E2B_LITERT_COMMAND`` before running the LiteRT-LM profile benchmark.

No-hardware simulation quick check:

- Run ``tools/run_prearrival_sim_check.cmd`` to create ``output/prearrival-sim/latest/PREARRIVAL_SIM_CHECK.md/json`` with the combined virtual CoreS3/LAN/audio proxy status, nested LAN smoke report, and engine-readiness status.
- After a real runner command is configured, run ``tools/run_prearrival_sim_check.cmd -RunModelBenchmark -Json`` to include nested ``model-benchmark/MODEL_BENCHMARK.md/json`` output and the ``model-benchmark-candidate`` gate in the same pre-arrival report.
- Run ``tools/run_lan_smoke.cmd`` to create ``output/lan-smoke/latest/LAN_SMOKE.md/json`` with a real local TCP/WebSocket bridge handshake, text turn, fake mic upload, fake STT, fake TTS, PCM16 binary downlink check, and visible ``thinking-latency`` timing while delayed speech is still running.
- Run ``tools/run_litert_lm_smoke.cmd`` to create ``output/litert-lm-smoke/latest/LITERT_LM_SMOKE.md/json`` with a deterministic two-layer LiteRT-LM wrapper contract check.
- Run ``tools/run_hardware_simulation.cmd`` to exercise the virtual Stackchan bridge proxy before the physical unit is available.
- The simulator proves bridge frame ordering, LAN text turns, fake mic PCM upload through fake STT, conversation timing, fake WAV TTS normalization to PCM16 downlink, speech-envelope handoff, binary TTS audio stream accounting, virtual CoreS3 input/display/speaker counters, offline command fallback, power-cycle recovery, bridge-kill recovery, and timeout failure behavior. It does not replace real hardware evidence.
- After an evidence packet has simulator output plus real display, speech, and bridge replay logs, run ``RUN_SIM_HARDWARE_COMPARE.cmd`` inside that packet to write advisory ``SIM_HARDWARE_COMPARE.md/json`` reports.

Voice audition quick check:

- Run ``tools/open_voice_audition.cmd`` from the extracted package to open the local MP3 audition page.
- Run ``tools/open_voice_audition.cmd -All`` to review every included voice sample and production-voice artifact.
- Published releases upload ``stackchan_spark_audition_bright_robot_greeting.mp3`` and ``stackchan_spark_thinking.mp3`` as standalone quick previews.
- The exact production ``model.pth`` and ``model.index`` are included under ``media/voice/rvc/`` and verified by SHA-256.
- Run ``tools/verify_tracked_rvc_assets.cmd`` to verify the bundled production RVC hashes.
- The exact active production model and index are included under ``media/voice/rvc``.

Hardware validation is still required for each recipient unit. The repository's private paired reference robot
is tracked separately through exact-image evidence in ``docs/FIRST_DEPLOY_STATUS.md`` and
``docs/ARRIVAL_DAY_RUNBOOK.md``; that reference evidence does not validate another assembled unit,
power path, calibration, credentials, or local voice model.

Package and recipient gates:

1. Display-only flash and 10-minute idle run.
2. Speech-mouth demo evidence: ``logs/speech_mouth_demo_serial.log`` with streamed speech envelope commands, ``speech clear``, and completion, plus ``logs/speak_all_intents_serial.log`` proving every packaged speech intent, earcon, and audio-output handoff.
3. Supervised servo-enable test.
4. Yaw classification and calibration.
5. 30-minute mixed idle/listen/speak soak.
6. Power-cycle recovery: USB power-cycle observation marked pass.
7. Target-speaker audio evidence: completed ``AUDIO_REVIEW.md`` plus a real-device speaker recording under ``audio/``.
8. Verify the bundled production voice hashes.

See ``docs/DEVICE_BRINGUP.md`` and ``docs/PRODUCTION_READINESS.md``.
"@ | Set-Content -Path (Join-Path $outDir "RELEASE_NOTES.md") -Encoding UTF8
}

$packageRootPrefix = $outDir.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
function Get-PackageRelativePath {
  param([string]$Path)

  $absolutePath = [System.IO.Path]::GetFullPath($Path)
  if (-not $absolutePath.StartsWith($packageRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    return ""
  }
  return $absolutePath.Substring($packageRootPrefix.Length).Replace("\", "/")
}

$releaseAssetEntries = Get-ReleaseFinalAssetEntries -Version $Version -PackageRoot $outDir -ZipPath $zipPath -ZipSidecarPath $zipSidecarPath
$allowedAuditEntries = Get-ReleaseAllowedAuditAssetEntries -AuditRoot "output/release-audit/$Version"
$releaseAssets = @($releaseAssetEntries | ForEach-Object {
  $relativePath = Get-PackageRelativePath -Path $_.Path
  [ordered]@{
    name = $_.Name
    phase = $_.Phase
    packagePath = $relativePath
    external = [string]::IsNullOrWhiteSpace($relativePath)
  }
})
$allowedAuditAssets = @($allowedAuditEntries | ForEach-Object {
  [ordered]@{
    name = $_.Name
    phase = $_.Phase
  }
})
$releaseAssetManifest = [ordered]@{
  schema = "stackchan.release-assets.v1"
  version = $Version
  commit = $commit
  generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  contract = "tools/release_asset_contract.ps1"
  releaseAssets = $releaseAssets
  allowedAuditAssets = $allowedAuditAssets
  counts = [ordered]@{
    releaseAssets = @($releaseAssets).Count
    allowedAuditAssets = @($allowedAuditAssets).Count
  }
}
$releaseAssetManifest | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $outDir "release_assets.json") -Encoding UTF8

function Assert-NoRestrictedVoicePayload {
  param([Parameter(Mandatory = $true)][string]$RootPath)

  $rootPrefix = [System.IO.Path]::GetFullPath($RootPath).TrimEnd('\') + '\'
  $violations = @(
    Get-ChildItem -LiteralPath $RootPath -File -Recurse | Where-Object {
      $relative = $_.FullName.Substring($rootPrefix.Length).Replace('\', '/')
      $extension = $_.Extension.ToLowerInvariant()
      $allowedVisionModel = $relative -match '(?i)^(provenance/)?bridge/models/face_detection_yunet_2023mar\.onnx$'
      $allowedProductionVoice = $relative -match '(?i)^media/voice/rvc/(model\.pth|model\.index)$'
      (($extension -in @('.pth', '.index')) -and -not $allowedProductionVoice) -or
      ($extension -eq '.onnx' -and -not $allowedVisionModel) -or
      ($_.Name -match '(?i)weightsgg|weights\.gg') -or
      ($relative -match '(?i)(^|/)media/voice/rvc/(?!README\.md$|model\.pth$|model\.index$)') -or
      ($_.Name -match '(?i)rvc.*\.(wav|mp3|html)$')
    } | ForEach-Object {
      $_.FullName.Substring($rootPrefix.Length).Replace('\', '/')
    }
  )
  if ($violations.Count -gt 0) {
    throw "Release package contains restricted RVC/model payloads: $($violations -join ', ')"
  }
}

Assert-NoRestrictedVoicePayload -RootPath $outDir

if (-not $SkipBuild) {
  Assert-ReleaseSourceIdentity `
    -ExpectedCommit $canonicalBuildCommit `
    -ExpectedEpoch $canonicalBuildEpoch `
    -Phase "final release checkout audit" `
    -ProjectRoot $repoRoot
  Assert-ReleaseSourceIdentity `
    -ExpectedCommit $canonicalBuildCommit `
    -ExpectedEpoch $canonicalBuildEpoch `
    -Phase "final commit-bound package source staging" `
    -ProjectRoot $releaseSourceRoot `
    -RejectIgnored
}

$hashLines = Get-ChildItem -LiteralPath $outDir -File -Recurse |
  Where-Object { $_.Name -ne "SHA256SUMS.txt" } |
  Sort-Object FullName |
  ForEach-Object {
    $relative = $_.FullName.Substring($outDir.Length + 1).Replace("\", "/")
    $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName
    "$($hash.Hash.ToLowerInvariant())  $relative"
  }

$hashLines | Set-Content -Path (Join-Path $outDir "SHA256SUMS.txt") -Encoding ASCII

if (Test-Path -LiteralPath $zipPath) {
  Remove-Item -LiteralPath $zipPath -Force
}
$zipEntries = @(New-StackchanDeterministicReleaseZip `
  -RootPath $outDir -ZipPath $zipPath -SourceEpoch $commitEpoch)
$restrictedZipEntries = @($zipEntries | Where-Object {
  $allowedVisionModel = $_ -match '(?i)(^|/)(provenance/)?bridge/models/face_detection_yunet_2023mar\.onnx$'
  $allowedProductionVoice = $_ -match '(?i)(^|/)media/voice/rvc/(model\.pth|model\.index)$'
  ($_.Trim() -match '(?i)(^|/)[^/]+\.(pth|index)$' -and -not $allowedProductionVoice) -or
  ($_ -match '(?i)(^|/)[^/]+\.onnx$' -and -not $allowedVisionModel) -or
  $_ -match '(?i)weightsgg|weights\.gg' -or
  $_ -match '(?i)(^|/)media/voice/rvc/(?!README\.md$|model\.pth$|model\.index$).+' -or
  $_ -match '(?i)(^|/)[^/]*rvc[^/]*\.(wav|mp3|html)$'
})
if ($restrictedZipEntries.Count -gt 0) {
  throw "Release ZIP contains restricted RVC/model payloads: $($restrictedZipEntries -join ', ')"
}
$zipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
"$zipHash  $(Split-Path -Leaf $zipPath)" | Set-Content -Path $zipSidecarPath -Encoding ASCII

$packageVerifyLog = Join-Path $releaseOutputRoot "$Version-package-verify.log"
$packageVerifyArgs = @(
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-File", $trustedVerifierScriptPath,
  "-Version", $Version,
  "-ZipPath", $zipPath,
  "-ExpectedCommit", $commit,
  "-ExpectedSourceEpoch", $commitEpoch
)
if ($AllowDirty) {
  $packageVerifyArgs += "-AllowDirtyPackage"
}
if (-not $SkipBuild) {
  $packageVerifyArgs += @(
    '-RequireReleaseEligible',
    '-ToolchainAllowlistPath', $ToolchainAllowlistPath,
    '-GitExecutable', $resolvedGitExecutable,
    '-PythonExecutable', $resolvedPythonExecutable,
    '-PlatformioExecutable', $resolvedPlatformioExecutable,
    '-LegacyCoreDir', $resolvedLegacyCore,
    '-ReleaseCoreDir', $resolvedReleaseCore)
}
$previousVerifyErrorPreference = $ErrorActionPreference
try {
  $ErrorActionPreference = "Continue"
  $packageVerifyOutput = @(& $windowsPowerShell @packageVerifyArgs 2>&1)
  $packageVerifyExit = $LASTEXITCODE
} finally {
  $ErrorActionPreference = $previousVerifyErrorPreference
}
$packageVerifyOutput | ForEach-Object { [string]$_ } |
  Set-Content -LiteralPath $packageVerifyLog -Encoding UTF8
if ($packageVerifyExit -ne 0) {
  throw "Package ZIP verification failed with exit code $packageVerifyExit. See $packageVerifyLog"
}

if (-not $SkipBuild) {
  Remove-ReleaseSourceWorktree
  if (-not [string]::IsNullOrWhiteSpace($firmwareBuildCacheRoot) -and
      (Test-Path -LiteralPath $firmwareBuildCacheRoot -PathType Container)) {
    Remove-Item -LiteralPath $firmwareBuildCacheRoot -Recurse -Force
  }
  $builtFirmwareCache = $null
  $firmwareBuildCacheRoot = $null
  $firmwareDependencySnapshotRoot = $null
  Close-StackchanToolchainLeaseState `
    -LeaseState $script:releaseToolchainLeaseState -RequireUnchanged `
    -Context 'completed governed release package'
}

Close-ReleaseToolchainResources

if ($SkipBuild) {
  Write-Host "Diagnostic archive only -- release and hardware use forbidden:"
} else {
  Write-Host "Release package:"
}
Write-Host $outDir
Write-Host $zipPath
Write-Host $zipSidecarPath
Write-Host $packageVerifyLog
