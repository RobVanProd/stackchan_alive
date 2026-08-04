$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'release_toolchain_identity.ps1')

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Assert-Throws {
  param([scriptblock]$Action, [string]$Pattern)
  try {
    & $Action
  } catch {
    if ([string]$_.Exception.Message -notmatch $Pattern) {
      throw "Expected failure matching '$Pattern', got: $($_.Exception.Message)"
    }
    return
  }
  throw "Expected failure matching '$Pattern', but the action succeeded."
}

function Copy-FixtureComponents {
  param([object[]]$Components)
  return @(Copy-StackchanToolchainIdentityComponents -Components $Components)
}

$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
  'stackchan-toolchain-cache-contract-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$savedPythonPath = [Environment]::GetEnvironmentVariable(
  'STACKCHAN_CACHE_TEST_PYTHON_POISON', [EnvironmentVariableTarget]::Process)
try {
  $pythonHome = Join-Path $testRoot 'python'
  $gitHome = Join-Path $testRoot 'git'
  $legacyCore = Join-Path $testRoot 'legacy-core'
  $releaseCore = Join-Path $testRoot 'release-core'
  $projectRoot = Join-Path $testRoot 'project'
  $libdepsRoot = Join-Path $testRoot 'libdeps'
  foreach ($directory in @(
      $pythonHome, (Join-Path $pythonHome 'Scripts'), $gitHome,
      (Join-Path $gitHome 'cmd'), $legacyCore, $releaseCore,
      $projectRoot, $libdepsRoot)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
  }
  $python = Join-Path $pythonHome 'python.exe'
  $pio = Join-Path $pythonHome 'Scripts/pio.exe'
  $git = Join-Path $gitHome 'cmd/git.exe'
  [IO.File]::WriteAllText($python, 'fixture-python')
  [IO.File]::WriteAllText($pio, 'fixture-pio')
  [IO.File]::WriteAllText($git, 'fixture-git')
  $rootMap = @{
    pythonHome = $pythonHome
    gitHome = $gitHome
    legacyCore = $legacyCore
    releaseCore = $releaseCore
    projectRoot = $projectRoot
    libdepsRoot = $libdepsRoot
  }

  $script:fixturePreCalls = 0
  $script:fixturePostCalls = 0
  $script:fixturePreRecord = [pscustomobject][ordered]@{
    name = 'python-installation'; phase = 'preBuild'
    identitySchema = 'stackchan.byte-tree.v1'; treeSha256 = ('A' * 64)
    fileCount = 1; bytes = 10
  }
  $script:fixturePostRecord = [pscustomobject][ordered]@{
    name = 'project-libdeps-stackchan'; phase = 'postBuild'
    identitySchema = 'stackchan.canonical-libdeps.v1'; treeSha256 = ('B' * 64)
    fileCount = 2; bytes = 20
  }

  function Get-StackchanReleaseToolchainObservedComponents {
    param(
      [hashtable]$RootMap, [string]$Phase, [string]$Environment,
      [string]$PythonExecutable, [string]$PlatformKey, $LeaseState,
      [string]$LeaseScope, [switch]$PostBuildComponentsOnly)
    if ($Phase -ceq 'PreBuild') {
      if ($PostBuildComponentsOnly) { throw 'PreBuild cannot be post-only.' }
      $script:fixturePreCalls++
      return @($script:fixturePreRecord)
    }
    if (-not $PostBuildComponentsOnly) {
      throw 'Guarded PostBuild did not request only fresh dependency components.'
    }
    $script:fixturePostCalls++
    return @($script:fixturePostRecord)
  }

  function Assert-StackchanPythonImportIsolation {
    param([string]$PythonHome, [string]$PythonExecutable)
    if (-not [string]::IsNullOrWhiteSpace(
        [Environment]::GetEnvironmentVariable(
          'STACKCHAN_CACHE_TEST_PYTHON_POISON', [EnvironmentVariableTarget]::Process))) {
      throw 'mock Python isolation rejected ambient state'
    }
  }

  $allowlistPath = Join-Path $testRoot 'allowlist.json'
  [ordered]@{
    schema = 'stackchan.release-toolchain-identity.v3'
    platformKey = 'windows_amd64'
    platformioCoreVersion = '6.1.19'
    pythonVersion = '3.12.10'
    identityScope = 'exact-host-installed-bytes'
    portableAcrossHosts = $false
    canonicalLibdepsSchema = 'stackchan.canonical-libdeps.v1'
    platformioExecutableRelativePaths = @('Scripts/pio.exe', 'Scripts/platformio.exe')
    pythonExecutableRelativePath = 'python.exe'
    gitExecutableRelativePath = 'cmd/git.exe'
    review = [ordered]@{ status = 'reviewed'; reviewer = 'fixture'; reason = 'cache contract' }
    components = @($script:fixturePreRecord, $script:fixturePostRecord)
  } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $allowlistPath -Encoding UTF8

  $common = @{
    AllowlistPath = $allowlistPath
    RootMap = $rootMap
    PlatformioExecutable = $pio
    PythonExecutable = $python
    GitExecutable = $git
    PlatformKey = 'windows_amd64'
  }

  $beforePreState = New-StackchanToolchainLeaseState
  try {
    Assert-Throws {
      Assert-StackchanReleaseToolchainIdentity @common -Phase PostBuild `
        -Environment stackchan -LeaseState $beforePreState -LeaseScope cycle-a
    } 'requires the same session to verify PreBuild first'
  } finally {
    Close-StackchanToolchainLeaseState -LeaseState $beforePreState
  }

  $state = New-StackchanToolchainLeaseState
  $preResult = Assert-StackchanReleaseToolchainIdentity @common -Phase PreBuild `
    -LeaseState $state -LeaseScope pre-build
  Assert-True ($preResult.componentCount -eq 1 -and $script:fixturePreCalls -eq 1) `
    'Guarded PreBuild fixture did not authenticate exactly once.'
  Assert-True ([bool]$state.preBuildVerified -and
      @($state.preBuildComponents).Count -eq 1 -and
      [string]$state.preBuildScope -ceq 'pre-build' -and
      [string]$state.preBuildAuthorityKey -match '^[0-9A-F]{64}$') `
    'Guarded PreBuild did not establish a complete cache binding.'

  $script:fixturePreRecord.treeSha256 = ('C' * 64)
  $postResult = Assert-StackchanReleaseToolchainIdentity @common -Phase PostBuild `
    -Environment stackchan -LeaseState $state -LeaseScope cycle-a
  Assert-True ($postResult.componentCount -eq 2 -and
      $script:fixturePreCalls -eq 1 -and $script:fixturePostCalls -eq 1) `
    'Guarded PostBuild rehashed PreBuild or omitted its fresh dependency record.'
  $script:fixturePreRecord.treeSha256 = ('A' * 64)
  $expectedObservationText = @(
    "project-libdeps-stackchan`0postBuild`0stackchan.canonical-libdeps.v1`0$('B' * 64)`02`020",
    "python-installation`0preBuild`0stackchan.byte-tree.v1`0$('A' * 64)`01`010"
  ) -join "`n"
  $expectedObservationText += "`n"
  $observationHasher = [Security.Cryptography.SHA256]::Create()
  try {
    $expectedObservation = ([BitConverter]::ToString($observationHasher.ComputeHash(
      [Text.Encoding]::UTF8.GetBytes($expectedObservationText))) -replace '-', '').ToUpperInvariant()
  } finally {
    $observationHasher.Dispose()
  }
  Assert-True ([string]$postResult.observationSha256 -ceq $expectedObservation) `
    'Cached plus fresh observation changed the established manifest semantics.'

  Assert-Throws {
    Assert-StackchanReleaseToolchainIdentity @common -Phase PreBuild `
      -LeaseState $state -LeaseScope pre-build
  } 'verify PreBuild only once'
  Assert-Throws {
    Assert-StackchanReleaseToolchainIdentity @common -Phase PostBuild `
      -Environment stackchan -LeaseState $state -LeaseScope pre-build
  } 'scope distinct'

  $postCallsBeforeAuthorityMismatch = $script:fixturePostCalls
  $alternateRoot = Join-Path $testRoot 'alternate-release-core'
  New-Item -ItemType Directory -Path $alternateRoot | Out-Null
  $alternateRootMap = $rootMap.Clone()
  $alternateRootMap.releaseCore = $alternateRoot
  $alternateCommon = $common.Clone()
  $alternateCommon.RootMap = $alternateRootMap
  Assert-Throws {
    Assert-StackchanReleaseToolchainIdentity @alternateCommon -Phase PostBuild `
      -Environment stackchan -LeaseState $state -LeaseScope cycle-a
  } 'authority differs'
  Assert-True ($script:fixturePostCalls -eq $postCallsBeforeAuthorityMismatch) `
    'Alternate authority reached fresh dependency scanning before rejection.'
  $alternatePio = Join-Path $pythonHome 'Scripts/platformio.exe'
  [IO.File]::WriteAllText($alternatePio, 'fixture-platformio')
  $alternateExecutableCommon = $common.Clone()
  $alternateExecutableCommon.PlatformioExecutable = $alternatePio
  Assert-Throws {
    Assert-StackchanReleaseToolchainIdentity @alternateExecutableCommon -Phase PostBuild `
      -Environment stackchan -LeaseState $state -LeaseScope cycle-a
  } 'authority differs'
  Assert-True ($script:fixturePostCalls -eq $postCallsBeforeAuthorityMismatch) `
    'Alternate executable reached fresh dependency scanning before rejection.'

  Close-StackchanToolchainLeaseScope -LeaseState $state -Scope cycle-a
  Assert-True ([bool]$state.preBuildVerified -and
      @($state.preBuildComponents).Count -eq 1) `
    'Closing a PostBuild scope invalidated the verified PreBuild cache.'
  [void](Assert-StackchanReleaseToolchainIdentity @common -Phase PostBuild `
    -Environment stackchan -LeaseState $state -LeaseScope cycle-b)

  $goodCache = @(Copy-FixtureComponents -Components @($state.preBuildComponents))
  $state.preBuildComponents = @()
  $postCallsBeforeCacheMutation = $script:fixturePostCalls
  Assert-Throws {
    Assert-StackchanReleaseToolchainIdentity @common -Phase PostBuild `
      -Environment stackchan -LeaseState $state -LeaseScope cycle-a
  } 'no verified PreBuild component cache'
  Assert-True ($script:fixturePostCalls -eq $postCallsBeforeCacheMutation) `
    'Empty PreBuild cache reached fresh dependency scanning.'
  $state.preBuildComponents = @(Copy-FixtureComponents -Components $goodCache)
  $state.preBuildComponents[0].treeSha256 = ('D' * 64)
  Assert-Throws {
    Assert-StackchanReleaseToolchainIdentity @common -Phase PostBuild `
      -Environment stackchan -LeaseState $state -LeaseScope cycle-a
  } 'byte identity mismatch'
  Assert-True ($script:fixturePostCalls -eq $postCallsBeforeCacheMutation) `
    'Hash-corrupt PreBuild cache reached fresh dependency scanning.'
  $state.preBuildComponents = @(
    (Copy-FixtureComponents -Components $goodCache)[0],
    (Copy-FixtureComponents -Components $goodCache)[0])
  Assert-Throws {
    Assert-StackchanReleaseToolchainIdentity @common -Phase PostBuild `
      -Environment stackchan -LeaseState $state -LeaseScope cycle-a
  } 'component count mismatch'
  Assert-True ($script:fixturePostCalls -eq $postCallsBeforeCacheMutation) `
    'Duplicate PreBuild cache reached fresh dependency scanning.'
  $state.preBuildComponents = @(Copy-FixtureComponents -Components $goodCache)

  $script:fixturePostRecord.treeSha256 = ('E' * 64)
  Assert-Throws {
    Assert-StackchanReleaseToolchainIdentity @common -Phase PostBuild `
      -Environment stackchan -LeaseState $state -LeaseScope cycle-a
  } 'byte identity mismatch'
  $script:fixturePostRecord.treeSha256 = ('B' * 64)

  [Environment]::SetEnvironmentVariable(
    'STACKCHAN_CACHE_TEST_PYTHON_POISON', '1', [EnvironmentVariableTarget]::Process)
  Assert-Throws {
    Assert-StackchanReleaseToolchainIdentity @common -Phase PostBuild `
      -Environment stackchan -LeaseState $state -LeaseScope cycle-a
  } 'mock Python isolation rejected ambient state'
  [Environment]::SetEnvironmentVariable(
    'STACKCHAN_CACHE_TEST_PYTHON_POISON', $null, [EnvironmentVariableTarget]::Process)

  $poisonRoot = Join-Path $testRoot 'poison-root'
  New-Item -ItemType Directory -Path $poisonRoot | Out-Null
  [IO.File]::WriteAllText((Join-Path $poisonRoot 'input.txt'), 'reviewed')
  Protect-StackchanToolchainTree -LeaseState $state -Root $poisonRoot -Scope pre-build
  $transient = Join-Path $poisonRoot 'transient.py'
  [IO.File]::WriteAllText($transient, 'unreviewed')
  Remove-Item -LiteralPath $transient -Force
  Start-Sleep -Milliseconds 250
  $postCallsBeforePoison = $script:fixturePostCalls
  Assert-Throws {
    Assert-StackchanReleaseToolchainIdentity @common -Phase PostBuild `
      -Environment stackchan -LeaseState $state -LeaseScope cycle-a
  } 'changed after authentication'
  Assert-True ($script:fixturePostCalls -eq $postCallsBeforePoison) `
    'Poisoned cache session reached fresh dependency scanning.'
  Close-StackchanToolchainLeaseState -LeaseState $state
  Assert-True (-not [bool]$state.preBuildVerified -and
      @($state.preBuildComponents).Count -eq 0 -and [bool]$state.closed) `
    'Closing a lease state did not invalidate its PreBuild cache.'

  $scopeState = New-StackchanToolchainLeaseState
  [void](Assert-StackchanReleaseToolchainIdentity @common -Phase PreBuild `
    -LeaseState $scopeState -LeaseScope pre-build)
  Close-StackchanToolchainLeaseScope -LeaseState $scopeState -Scope pre-build
  Assert-True (-not [bool]$scopeState.preBuildVerified -and
      @($scopeState.preBuildComponents).Count -eq 0) `
    'Closing the PreBuild scope did not invalidate its cache.'
  Assert-Throws {
    Assert-StackchanReleaseToolchainIdentity @common -Phase PostBuild `
      -Environment stackchan -LeaseState $scopeState -LeaseScope cycle-a
  } 'requires the same session to verify PreBuild first'
  Close-StackchanToolchainLeaseState -LeaseState $scopeState

  [pscustomobject][ordered]@{
    schema = 'stackchan.release-toolchain-cache-contract.v1'
    status = 'pass'
    preBuildScans = $script:fixturePreCalls
    freshPostBuildScans = $script:fixturePostCalls
  } | ConvertTo-Json -Compress
} finally {
  [Environment]::SetEnvironmentVariable(
    'STACKCHAN_CACHE_TEST_PYTHON_POISON', $savedPythonPath,
    [EnvironmentVariableTarget]::Process)
  $resolved = [IO.Path]::GetFullPath($testRoot)
  $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
  if ($resolved.StartsWith($temp + [IO.Path]::DirectorySeparatorChar,
      [StringComparison]::OrdinalIgnoreCase) -and
      (Split-Path -Leaf $resolved) -like 'stackchan-toolchain-cache-contract-*') {
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
  }
}
