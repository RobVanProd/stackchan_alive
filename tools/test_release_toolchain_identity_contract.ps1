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

$testRoot = Join-Path ([IO.Path]::GetTempPath()) (
  'stackchan-toolchain-identity-contract-' + [guid]::NewGuid().ToString('N'))
$isolationEnvironmentNames = @(
  'PYTHONNOUSERSITE', 'PYTHONSAFEPATH', 'PYTHONDONTWRITEBYTECODE',
  'PYTHONHASHSEED', 'PYTHONUTF8', 'PYTHONIOENCODING',
  '__PYVENV_LAUNCHER__', '_PYTHON_HOST_PLATFORM',
  'CONDA_DEFAULT_ENV', 'CONDA_PREFIX', 'VIRTUAL_ENV',
  'PYTHONBREAKPOINT', 'PYTHONCASEOK', 'PYTHONCOERCECLOCALE', 'PYTHONDEBUG',
  'PYTHONEXECUTABLE', 'PYTHONFAULTHANDLER', 'PYTHONHOME', 'PYTHONINSPECT',
  'PYTHONINTMAXSTRDIGITS', 'PYTHONMALLOC', 'PYTHONNODEBUGRANGES', 'PYTHONPATH',
  'PYTHONOPTIMIZE', 'PYTHONPERFSUPPORT', 'PYTHONPLATLIBDIR', 'PYTHONPROFILEIMPORTTIME',
  'PYTHONPYCACHEPREFIX', 'PYTHONSTARTUP', 'PYTHONTRACEMALLOC', 'PYTHONUSERBASE',
  'PYTHONWARNDEFAULTENCODING', 'PYTHONWARNINGS'
)
$savedIsolationEnvironment = @{}
foreach ($name in $isolationEnvironmentNames) {
  $savedIsolationEnvironment[$name] = [Environment]::GetEnvironmentVariable(
    $name, [EnvironmentVariableTarget]::Process)
}
New-Item -ItemType Directory -Path $testRoot | Out-Null
try {
  $first = Join-Path $testRoot 'first'
  $second = Join-Path $testRoot 'second'
  New-Item -ItemType Directory -Path (Join-Path $first 'nested') -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $second 'nested') -Force | Out-Null

  # Deliberately create the two path-independent fixtures in opposite orders.
  [IO.File]::WriteAllBytes((Join-Path $first 'alpha.txt'), [byte[]](0, 1, 2, 255))
  [IO.File]::WriteAllText((Join-Path $first 'nested/zeta.txt'), "zeta`n", [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText((Join-Path $second 'nested/zeta.txt'), "zeta`n", [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllBytes((Join-Path $second 'alpha.txt'), [byte[]](0, 1, 2, 255))
  $firstIdentity = Get-StackchanToolchainTreeIdentity -Root $first
  $secondIdentity = Get-StackchanToolchainTreeIdentity -Root $second
  Assert-True ($firstIdentity.treeSha256 -ceq $secondIdentity.treeSha256) `
    'Tree identity depends on absolute path or creation/enumeration order.'
  Assert-True ($firstIdentity.fileCount -eq 2 -and $firstIdentity.bytes -eq 9) `
    'Tree identity count/size accounting is incorrect.'

  New-Item -ItemType Directory -Path (Join-Path $second '.git') | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $second '__pycache__') | Out-Null
  [IO.File]::WriteAllText((Join-Path $second '.git/noise'), 'ignored')
  [IO.File]::WriteAllText((Join-Path $second '__pycache__/noise.pyc'), 'ignored')
  [IO.File]::WriteAllText((Join-Path $second 'noise.pyc'), 'ignored')
  $cacheIdentity = Get-StackchanToolchainTreeIdentity -Root $second
  Assert-True ($cacheIdentity.treeSha256 -cne $firstIdentity.treeSha256) `
    'Executable bytecode or Git metadata was silently excluded from byte identity.'

  [IO.File]::WriteAllBytes((Join-Path $second 'alpha.txt'), [byte[]](0, 1, 3, 255))
  $mutatedIdentity = Get-StackchanToolchainTreeIdentity -Root $second
  Assert-True ($mutatedIdentity.treeSha256 -cne $cacheIdentity.treeSha256) `
    'A same-length byte mutation did not change the tree identity.'

  [IO.File]::WriteAllBytes((Join-Path $second 'alpha.txt'), [byte[]](0, 1, 2, 255))
  Move-Item -LiteralPath (Join-Path $second 'alpha.txt') -Destination (Join-Path $second 'case-tmp.txt')
  Move-Item -LiteralPath (Join-Path $second 'case-tmp.txt') -Destination (Join-Path $second 'ALPHA.txt')
  $caseIdentity = Get-StackchanToolchainTreeIdentity -Root $second
  Assert-True ($caseIdentity.treeSha256 -cne $cacheIdentity.treeSha256) `
    'A relative-path case mutation did not change the tree identity.'

  foreach ($unsafe in @('../escape', 'safe/../escape', 'C:/escape', '/escape', './escape', "bad`0name")) {
    Assert-Throws { ConvertTo-StackchanSafeIdentityRelativePath $unsafe } '(Unsafe|Non-canonical)'
  }

  if ($env:OS -ne 'Windows_NT') {
    $caseRoot = Join-Path $testRoot 'case-ambiguous'
    New-Item -ItemType Directory -Path $caseRoot | Out-Null
    [IO.File]::WriteAllText((Join-Path $caseRoot 'A'), 'a')
    [IO.File]::WriteAllText((Join-Path $caseRoot 'a'), 'b')
    Assert-Throws { Get-StackchanToolchainTreeIdentity -Root $caseRoot } 'Case-ambiguous'
  }

  $policy = @(Get-StackchanReleaseToolchainComponentPolicy -PlatformKey 'windows_amd64')
  $names = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($component in @($policy | Where-Object phase -ceq 'preBuild')) {
    Assert-True ($names.Add([string]$component.name)) "Duplicate policy component: $($component.name)"
    [void](ConvertTo-StackchanSafeIdentityRelativePath ([string]$component.relativePath))
    Assert-True ([string]$component.phase -in @('preBuild', 'postBuild')) `
      "Invalid component phase: $($component.name)"
  }
  Assert-True (@($policy | Where-Object { $_.name -like 'project-libdeps-*' }).Count -eq 3) `
    'Policy does not bind all three release libdeps trees after build.'
  Assert-True (@($policy | Where-Object { $_.name -like '*toolchain*' }).Count -ge 3) `
    'Policy does not bind the installed compiler toolchains.'
  Assert-True (@($policy | Where-Object { $_.name -eq 'legacy-core-penv' }).Count -eq 1 -and
    @($policy | Where-Object { $_.name -eq 'release-core-penv' }).Count -eq 1) `
    'Policy does not bind both PlatformIO-managed Python environments.'
  $pythonPolicy = @($policy | Where-Object { $_.name -eq 'python-installation' })
  Assert-True ($pythonPolicy.Count -eq 1 -and [string]$pythonPolicy[0].relativePath -ceq '@root') `
    'Policy does not bind the complete Python installation as one closed root.'
  Assert-Throws {
    Get-StackchanReleaseToolchainComponentPolicy -PlatformKey 'linux_amd64'
  } 'No reviewed release toolchain component policy'

  $fixtureRoots = @{
    pythonHome = Join-Path $testRoot 'identity-host/python'
    legacyCore = Join-Path $testRoot 'identity-host/legacy-core'
    releaseCore = Join-Path $testRoot 'identity-host/release-core'
    projectRoot = Join-Path $testRoot 'identity-host/project'
  }
  foreach ($root in $fixtureRoots.Values) {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
  }
  foreach ($component in $policy) {
    $componentPath = Resolve-StackchanIdentityComponentPath `
      -RootMap $fixtureRoots -Component $component
    if ([IO.Path]::GetExtension($componentPath) -in @('.exe', '.dll')) {
      New-Item -ItemType Directory -Path (Split-Path -Parent $componentPath) -Force | Out-Null
      [IO.File]::WriteAllText($componentPath, [string]$component.name)
    } else {
      New-Item -ItemType Directory -Path $componentPath -Force | Out-Null
      [IO.File]::WriteAllText((Join-Path $componentPath 'identity.fixture'), [string]$component.name)
    }
  }
  New-Item -ItemType Directory -Path (Join-Path $fixtureRoots.pythonHome 'Scripts') -Force | Out-Null
  foreach ($relative in @('python.exe', 'python312.zip', 'Scripts/pio.exe', 'Scripts/platformio.exe')) {
    [IO.File]::WriteAllText((Join-Path $fixtureRoots.pythonHome $relative), "fixture:$relative")
  }
  $fixturePio = Join-Path $fixtureRoots.pythonHome 'Scripts/platformio.exe'
  $fixturePython = Join-Path $fixtureRoots.pythonHome 'python.exe'
  $fixtureAllowlist = Join-Path $testRoot 'reviewed-fixture-allowlist.json'
  $candidate = [pscustomobject][ordered]@{
    schema = 'stackchan.release-toolchain-identity.v2'
    platformKey = 'windows_amd64'
    platformioCoreVersion = '6.1.19'
    pythonVersion = '3.12.10'
    identityScope = 'exact-host-installed-bytes'
    portableAcrossHosts = $false
    canonicalLibdepsSchema = 'stackchan.canonical-libdeps.v1'
    platformioExecutableRelativePaths = @('Scripts/pio.exe', 'Scripts/platformio.exe')
    pythonExecutableRelativePath = 'python.exe'
    review = [pscustomobject][ordered]@{
      status = 'reviewed'
      reviewer = 'fixture-reviewer'
      reason = 'contract fixture'
    }
    components = @(Get-StackchanReleaseToolchainObservedComponents `
      -RootMap $fixtureRoots -Phase PreBuild -PlatformKey 'windows_amd64')
  }
  $candidate | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureAllowlist -Encoding UTF8
  $observedPython = @($candidate.components | Where-Object name -ceq 'python-installation')
  Assert-True ($observedPython.Count -eq 1 -and $observedPython[0].fileCount -ge 5) `
    'Complete Python installation inventory omitted root, archive, or Scripts bytes.'

  $pythonHomeFull = (Get-Item -LiteralPath $fixtureRoots.pythonHome).FullName.TrimEnd('\', '/')
  $fixturePythonFull = (Get-Item -LiteralPath $fixturePython).FullName
  $validProbe = [pscustomobject]@{
    executable = $fixturePythonFull
    prefix = $pythonHomeFull
    base_prefix = $pythonHomeFull
    path = @(
      (Join-Path $pythonHomeFull 'python312.zip'), (Join-Path $pythonHomeFull 'DLLs'),
      (Join-Path $pythonHomeFull 'Lib'), $pythonHomeFull,
      (Join-Path $pythonHomeFull 'Lib/site-packages'))
    enable_user_site = $false
    flags = [pscustomobject]@{
      no_user_site = 1; safe_path = $true; dont_write_bytecode = 1; optimize = 0
    }
  }
  Assert-StackchanPythonImportIsolationState `
    -Probe $validProbe -PythonHome $pythonHomeFull -PythonExecutable $fixturePythonFull
  $escapedProbe = $validProbe | ConvertTo-Json -Depth 5 | ConvertFrom-Json
  $escapedProbe.path += (Join-Path $testRoot 'external-python')
  Assert-Throws {
    Assert-StackchanPythonImportIsolationState `
      -Probe $escapedProbe -PythonHome $pythonHomeFull -PythonExecutable $fixturePythonFull
  } 'import path contains an external'
  $userSiteProbe = $validProbe | ConvertTo-Json -Depth 5 | ConvertFrom-Json
  $userSiteProbe.enable_user_site = $true
  Assert-Throws {
    Assert-StackchanPythonImportIsolationState `
      -Probe $userSiteProbe -PythonHome $pythonHomeFull -PythonExecutable $fixturePythonFull
  } 'no-user-site/safe-path'
  $unsafePathProbe = $validProbe | ConvertTo-Json -Depth 5 | ConvertFrom-Json
  $unsafePathProbe.flags.safe_path = $false
  Assert-Throws {
    Assert-StackchanPythonImportIsolationState `
      -Probe $unsafePathProbe -PythonHome $pythonHomeFull -PythonExecutable $fixturePythonFull
  } 'no-user-site/safe-path'
  $optimizedProbe = $validProbe | ConvertTo-Json -Depth 5 | ConvertFrom-Json
  $optimizedProbe.flags.optimize = 1
  Assert-Throws {
    Assert-StackchanPythonImportIsolationState `
      -Probe $optimizedProbe -PythonHome $pythonHomeFull -PythonExecutable $fixturePythonFull
  } 'no-user-site/safe-path'
  $wrongExecutableProbe = $validProbe | ConvertTo-Json -Depth 5 | ConvertFrom-Json
  $wrongExecutable = Join-Path $fixtureRoots.pythonHome 'other-python.exe'
  [IO.File]::WriteAllText($wrongExecutable, 'other')
  $wrongExecutableProbe.executable = $wrongExecutable
  Assert-Throws {
    Assert-StackchanPythonImportIsolationState `
      -Probe $wrongExecutableProbe -PythonHome $pythonHomeFull -PythonExecutable $fixturePythonFull
  } 'no-user-site/safe-path'

  foreach ($name in $isolationEnvironmentNames) {
    [Environment]::SetEnvironmentVariable($name, $null, [EnvironmentVariableTarget]::Process)
  }
  $requiredIsolation = [ordered]@{
    PYTHONNOUSERSITE = '1'; PYTHONSAFEPATH = '1'; PYTHONDONTWRITEBYTECODE = '1'
    PYTHONHASHSEED = '0'; PYTHONUTF8 = '1'; PYTHONIOENCODING = 'utf-8'
  }
  foreach ($entry in $requiredIsolation.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable(
      [string]$entry.Key, [string]$entry.Value, [EnvironmentVariableTarget]::Process)
  }
  $escapePath = Join-Path $fixtureRoots.pythonHome 'Lib/site-packages/escape.pth'
  New-Item -ItemType Directory -Path (Split-Path -Parent $escapePath) -Force | Out-Null
  [IO.File]::WriteAllText($escapePath, (Join-Path $testRoot 'outside'))
  Assert-Throws {
    Assert-StackchanPythonImportIsolation `
      -PythonHome $pythonHomeFull -PythonExecutable $fixturePythonFull
  } 'escape files'
  Remove-Item -LiteralPath $escapePath -Force
  [Environment]::SetEnvironmentVariable(
    'PYTHONNOUSERSITE', $null, [EnvironmentVariableTarget]::Process)
  Assert-Throws {
    Assert-StackchanPythonImportIsolation `
      -PythonHome $pythonHomeFull -PythonExecutable $fixturePythonFull
  } 'requires PYTHONNOUSERSITE=1'
  [Environment]::SetEnvironmentVariable(
    'PYTHONNOUSERSITE', '1', [EnvironmentVariableTarget]::Process)
  [Environment]::SetEnvironmentVariable(
    'PYTHONOPTIMIZE', '1', [EnvironmentVariableTarget]::Process)
  Assert-Throws {
    Assert-StackchanPythonImportIsolation `
      -PythonHome $pythonHomeFull -PythonExecutable $fixturePythonFull
  } 'ambient import/runtime override: PYTHONOPTIMIZE'
  [Environment]::SetEnvironmentVariable(
    'PYTHONOPTIMIZE', $null, [EnvironmentVariableTarget]::Process)

  $candidate.platformioExecutableRelativePaths = @(
    'Scripts/pio.exe', 'Scripts/platformio.exe', 'Scripts/fake-pio.exe')
  $candidate | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureAllowlist -Encoding UTF8
  Assert-Throws {
    Assert-StackchanReleaseToolchainIdentity `
      -AllowlistPath $fixtureAllowlist -RootMap @{} `
      -PlatformioExecutable $fixturePio -PythonExecutable $fixturePython `
      -Phase PreBuild -PlatformKey 'windows_amd64'
  } 'executable paths are not the canonical policy'
  $candidate.platformioExecutableRelativePaths = @('Scripts/pio.exe', 'Scripts/platformio.exe')
  $candidate.pythonExecutableRelativePath = 'Scripts/python.exe'
  $candidate | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureAllowlist -Encoding UTF8
  Assert-Throws {
    Assert-StackchanReleaseToolchainIdentity `
      -AllowlistPath $fixtureAllowlist -RootMap @{} `
      -PlatformioExecutable $fixturePio -PythonExecutable $fixturePython `
      -Phase PreBuild -PlatformKey 'windows_amd64'
  } 'executable paths are not the canonical policy'
  $candidate.pythonExecutableRelativePath = 'python.exe'

  $missingAllowlist = Join-Path $testRoot 'missing-allowlist.json'
  Assert-Throws {
    Assert-StackchanReleaseToolchainIdentity `
      -AllowlistPath $missingAllowlist -RootMap @{} `
      -PlatformioExecutable $fixturePio -PythonExecutable $fixturePython `
      -Phase PreBuild -PlatformKey 'windows_amd64'
  } '(Cannot find path|does not exist)'
  $candidate.review.status = 'candidate-unreviewed'
  $candidate | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureAllowlist -Encoding UTF8
  Assert-Throws {
    Assert-StackchanReleaseToolchainIdentity `
      -AllowlistPath $fixtureAllowlist -RootMap @{} `
      -PlatformioExecutable $fixturePio -PythonExecutable $fixturePython `
      -Phase PreBuild -PlatformKey 'windows_amd64'
  } '(absent|unreviewed|another platform)'
  $candidate.review.status = 'reviewed'
  $candidate.platformKey = 'linux_amd64'
  $candidate | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureAllowlist -Encoding UTF8
  Assert-Throws {
    Assert-StackchanReleaseToolchainIdentity `
      -AllowlistPath $fixtureAllowlist -RootMap @{} `
      -PlatformioExecutable $fixturePio -PythonExecutable $fixturePython `
      -Phase PreBuild -PlatformKey 'windows_amd64'
  } '(absent|unreviewed|another platform)'
  $candidate.platformKey = 'windows_amd64'
  $candidate.identityScope = 'portable-version-only'
  $candidate | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureAllowlist -Encoding UTF8
  Assert-Throws {
    Assert-StackchanReleaseToolchainIdentity `
      -AllowlistPath $fixtureAllowlist -RootMap @{} `
      -PlatformioExecutable $fixturePio -PythonExecutable $fixturePython `
      -Phase PreBuild -PlatformKey 'windows_amd64'
  } 'version policy mismatch'
  $candidate.identityScope = 'exact-host-installed-bytes'
  $candidate | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixtureAllowlist -Encoding UTF8
  $beforeMutation = @(Get-StackchanReleaseToolchainObservedComponents `
    -RootMap $fixtureRoots -Phase PreBuild -PlatformKey 'windows_amd64')
  [IO.File]::AppendAllText((
    Join-Path $fixtureRoots.legacyCore 'packages/toolchain-riscv32-esp/identity.fixture'), 'wrong-host')
  $afterMutation = @(Get-StackchanReleaseToolchainObservedComponents `
    -RootMap $fixtureRoots -Phase PreBuild -PlatformKey 'windows_amd64')
  $beforeCompiler = @($beforeMutation | Where-Object name -ceq 'legacy-package-toolchain-riscv32-esp')[0]
  $afterCompiler = @($afterMutation | Where-Object name -ceq 'legacy-package-toolchain-riscv32-esp')[0]
  Assert-True ($beforeCompiler.treeSha256 -cne $afterCompiler.treeSha256) `
    'A compiler-toolchain byte mutation did not change the observed pre-build identity.'

  $staleLibdeps = Join-Path $fixtureRoots.projectRoot '.pio/libdeps/stackchan'
  $stalePolicy = Get-StackchanExpectedLibdepsPolicy -Environment stackchan
  New-Item -ItemType Directory -Path $staleLibdeps -Force | Out-Null
  foreach ($leaf in @($stalePolicy.leaves) + @('unexpected-stale-library')) {
    New-Item -ItemType Directory -Path (Join-Path $staleLibdeps $leaf) -Force | Out-Null
  }
  [IO.File]::WriteAllLines((Join-Path $staleLibdeps 'integrity.dat'), [string[]]$stalePolicy.requirements)
  Assert-Throws {
    Get-StackchanCanonicalLibdepsIdentity -Root $staleLibdeps -Environment stackchan
  } 'stale or has unexpected packages/files'
  Assert-Throws {
    New-StackchanReleaseToolchainIdentityCandidate `
      -RootMap $fixtureRoots -PlatformioExecutable $fixturePio `
      -PythonExecutable $fixturePython -PlatformKey windows_amd64
  } 'isolation probe failed'
  Assert-Throws {
    Get-StackchanReleaseToolchainObservedComponents `
      -RootMap $fixtureRoots -Phase PostBuild -PlatformKey windows_amd64
  } 'PostBuild toolchain eligibility is disabled'

  function Invoke-FixtureGit {
    param([string[]]$Arguments)
    $previousPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      $output = @(& git @Arguments 2>&1)
      $exitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $previousPreference
    }
    if ($exitCode -ne 0) {
      throw "Fixture Git failed: git $($Arguments -join ' ')`n$($output -join "`n")"
    }
    return @($output)
  }
  $gitSeed = Join-Path $testRoot 'git-seed'
  $gitFirst = Join-Path $testRoot 'git-first'
  $gitSecond = Join-Path $testRoot 'git-second'
  Invoke-FixtureGit @('init', '--initial-branch=main', $gitSeed) | Out-Null
  Invoke-FixtureGit @('-C', $gitSeed, 'config', 'user.name', 'Fixture Builder') | Out-Null
  Invoke-FixtureGit @('-C', $gitSeed, 'config', 'user.email', 'fixture@example.invalid') | Out-Null
  Invoke-FixtureGit @('-C', $gitSeed, 'config', 'core.autocrlf', 'false') | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $gitSeed 'src') | Out-Null
  [IO.File]::WriteAllText((Join-Path $gitSeed 'src/source.cpp'), "int fixture = 1;`n")
  [IO.File]::WriteAllText((Join-Path $gitSeed 'builder.py'), "print('fixture')`n")
  Invoke-FixtureGit @('-C', $gitSeed, 'add', '--', 'src/source.cpp', 'builder.py') | Out-Null
  Invoke-FixtureGit @('-C', $gitSeed, 'commit', '-m', 'fixture source') | Out-Null
  Invoke-FixtureGit @('clone', '--no-local', $gitSeed, $gitFirst) | Out-Null
  Invoke-FixtureGit @('clone', '--no-local', $gitSeed, $gitSecond) | Out-Null
  $fixtureCommit = (Invoke-FixtureGit @('-C', $gitSeed, 'rev-parse', 'HEAD') | Select-Object -Last 1).Trim()
  $fixtureShortCommit = $fixtureCommit.Substring(0, 7)
  $fixtureUri = "git+https://github.com/fixture/example.git#$fixtureShortCommit"
  $installStamps = @('20260803101010', '20260803111111')
  $cloneNumber = 0
  foreach ($clone in @($gitFirst, $gitSecond)) {
    Invoke-FixtureGit @('-C', $clone, 'remote', 'set-url', 'origin', 'https://github.com/fixture/example.git') | Out-Null
    $metadata = [ordered]@{
      type = 'library'
      name = 'FixtureGitLibrary'
      version = "0.0.0+$($installStamps[$cloneNumber]).sha.$fixtureShortCommit"
      spec = [ordered]@{
        owner = $null
        id = $null
        name = 'FixtureGitLibrary'
        requirements = $null
        uri = $fixtureUri
      }
    }
    [IO.File]::WriteAllText((Join-Path $clone '.git/.piopm'), ($metadata | ConvertTo-Json -Compress -Depth 4))
    $libraryMetadata = [ordered]@{ name = 'FixtureGitLibrary'; version = "0.0.0+$($installStamps[$cloneNumber])" }
    [IO.File]::WriteAllText((Join-Path $clone 'library.json'), ($libraryMetadata | ConvertTo-Json -Depth 2))
    $cloneNumber++
  }
  $gitFirstRecords = Get-StackchanCanonicalGitLibraryRecords `
    -LibraryRoot $gitFirst -LibraryLeaf FixtureGitLibrary `
    -ExpectedPackageName FixtureGitLibrary -ExpectedSourceUri $fixtureUri `
    -ExpectedCommit $fixtureCommit
  $gitSecondRecords = Get-StackchanCanonicalGitLibraryRecords `
    -LibraryRoot $gitSecond -LibraryLeaf FixtureGitLibrary `
    -ExpectedPackageName FixtureGitLibrary -ExpectedSourceUri $fixtureUri `
    -ExpectedCommit $fixtureCommit
  $gitFirstIdentity = Get-StackchanIdentityFromRecords `
    -Records $gitFirstRecords.records -Schema 'stackchan.git-fixture.v1'
  $gitSecondIdentity = Get-StackchanIdentityFromRecords `
    -Records $gitSecondRecords.records -Schema 'stackchan.git-fixture.v1'
  Assert-True ($gitFirstIdentity.treeSha256 -ceq $gitSecondIdentity.treeSha256) `
    'Install timestamps or path/stat-bearing Git metadata changed canonical Git identity.'

  $gitFirstTree = Get-StackchanCanonicalGitLibraryTreeIdentity `
    -LibraryRoot $gitFirst -LibraryLeaf FixtureGitLibrary `
    -ExpectedPackageName FixtureGitLibrary -ExpectedSourceUri $fixtureUri `
    -ExpectedCommit $fixtureCommit
  $sourceBefore = Get-StackchanCanonicalGitLibraryTreeIdentity `
    -LibraryRoot $gitSecond -LibraryLeaf FixtureGitLibrary `
    -ExpectedPackageName FixtureGitLibrary -ExpectedSourceUri $fixtureUri `
    -ExpectedCommit $fixtureCommit
  Assert-True ($gitFirstTree.treeSha256 -ceq $sourceBefore.treeSha256) `
    'Complete canonical Git library identity varies across equivalent installs.'
  [IO.File]::WriteAllText((Join-Path $gitSecond 'src/source.cpp'), "int fixture = 2;`n")
  $sourceAfter = Get-StackchanCanonicalGitLibraryTreeIdentity `
    -LibraryRoot $gitSecond -LibraryLeaf FixtureGitLibrary `
    -ExpectedPackageName FixtureGitLibrary -ExpectedSourceUri $fixtureUri `
    -ExpectedCommit $fixtureCommit
  Assert-True ($sourceBefore.treeSha256 -cne $sourceAfter.treeSha256) `
    'Canonical libdeps identity did not bind an actual source-byte mutation.'
  [IO.File]::WriteAllText((Join-Path $gitSecond 'src/source.cpp'), "int fixture = 1;`n")
  $builderBefore = Get-StackchanCanonicalGitLibraryTreeIdentity `
    -LibraryRoot $gitSecond -LibraryLeaf FixtureGitLibrary `
    -ExpectedPackageName FixtureGitLibrary -ExpectedSourceUri $fixtureUri `
    -ExpectedCommit $fixtureCommit
  [IO.File]::WriteAllText((Join-Path $gitSecond 'builder.py'), "print('fixturf')`n")
  $builderAfter = Get-StackchanCanonicalGitLibraryTreeIdentity `
    -LibraryRoot $gitSecond -LibraryLeaf FixtureGitLibrary `
    -ExpectedPackageName FixtureGitLibrary -ExpectedSourceUri $fixtureUri `
    -ExpectedCommit $fixtureCommit
  Assert-True ($builderBefore.treeSha256 -cne $builderAfter.treeSha256) `
    'Canonical libdeps identity did not bind a build-readable builder.py mutation.'
  [IO.File]::WriteAllText((Join-Path $gitSecond 'builder.py'), "print('fixture')`n")

  $headPath = Join-Path $gitSecond '.git/HEAD'
  $headBytes = [IO.File]::ReadAllBytes($headPath)
  [IO.File]::WriteAllText($headPath, "ref: refs/heads/unreviewed`n")
  Assert-Throws {
    Get-StackchanCanonicalGitLibraryTreeIdentity `
      -LibraryRoot $gitSecond -LibraryLeaf FixtureGitLibrary `
      -ExpectedPackageName FixtureGitLibrary -ExpectedSourceUri $fixtureUri `
      -ExpectedCommit $fixtureCommit
  } 'HEAD ref is missing'
  [IO.File]::WriteAllBytes($headPath, $headBytes)

  $headRefPath = Join-Path $gitSecond '.git/refs/heads/main'
  $headRefBytes = [IO.File]::ReadAllBytes($headRefPath)
  [IO.File]::WriteAllText($headRefPath, (('0' * 40) + "`n"))
  Assert-Throws {
    Get-StackchanCanonicalGitLibraryTreeIdentity `
      -LibraryRoot $gitSecond -LibraryLeaf FixtureGitLibrary `
      -ExpectedPackageName FixtureGitLibrary -ExpectedSourceUri $fixtureUri `
      -ExpectedCommit $fixtureCommit
  } 'commit does not match reviewed policy'
  [IO.File]::WriteAllBytes($headRefPath, $headRefBytes)

  $wrongCommitFirst = if ($fixtureCommit[0] -ceq '0') { '1' } else { '0' }
  $wrongFullCommit = $wrongCommitFirst + $fixtureCommit.Substring(1)
  Assert-Throws {
    Get-StackchanCanonicalGitLibraryTreeIdentity `
      -LibraryRoot $gitSecond -LibraryLeaf FixtureGitLibrary `
      -ExpectedPackageName FixtureGitLibrary -ExpectedSourceUri $fixtureUri `
      -ExpectedCommit $wrongFullCommit
  } 'commit does not match reviewed policy'

  [IO.File]::WriteAllText((Join-Path $gitSecond '.git/hooks/pre-commit'), 'malicious hook')
  Assert-Throws {
    Get-StackchanCanonicalGitLibraryRecords `
      -LibraryRoot $gitSecond -LibraryLeaf FixtureGitLibrary `
      -ExpectedPackageName FixtureGitLibrary -ExpectedSourceUri $fixtureUri `
      -ExpectedCommit $fixtureCommit
  } 'Unexpected executable or object Git state'
  Remove-Item -LiteralPath (Join-Path $gitSecond '.git/hooks/pre-commit') -Force

  $configPath = Join-Path $gitSecond '.git/config'
  $configBytes = [IO.File]::ReadAllBytes($configPath)
  [IO.File]::WriteAllText($configPath, ([IO.File]::ReadAllText($configPath) -replace
    'https://github.com/fixture/example.git', 'https://github.com/evil/example.git'))
  Assert-Throws {
    Get-StackchanCanonicalGitLibraryRecords `
      -LibraryRoot $gitSecond -LibraryLeaf FixtureGitLibrary `
      -ExpectedPackageName FixtureGitLibrary -ExpectedSourceUri $fixtureUri `
      -ExpectedCommit $fixtureCommit
  } 'remote source does not match reviewed policy'
  [IO.File]::WriteAllBytes($configPath, $configBytes)

  $piopmPath = Join-Path $gitSecond '.git/.piopm'
  $piopmBytes = [IO.File]::ReadAllBytes($piopmPath)
  [IO.File]::WriteAllText($piopmPath, ([IO.File]::ReadAllText($piopmPath) -replace
    [regex]::Escape($fixtureUri), 'git+https://github.com/evil/example.git#0000000'))
  Assert-Throws {
    Get-StackchanCanonicalGitLibraryRecords `
      -LibraryRoot $gitSecond -LibraryLeaf FixtureGitLibrary `
      -ExpectedPackageName FixtureGitLibrary -ExpectedSourceUri $fixtureUri `
      -ExpectedCommit $fixtureCommit
  } 'Unsafe PlatformIO Git package metadata'
  [IO.File]::WriteAllBytes($piopmPath, $piopmBytes)

  $packPath = @(Get-ChildItem (Join-Path $gitSecond '.git/objects/pack') -Filter '*.pack')[0].FullName
  $packBytes = [IO.File]::ReadAllBytes($packPath)
  $packBytes[20] = $packBytes[20] -bxor 1
  (Get-Item -LiteralPath $packPath).IsReadOnly = $false
  [IO.File]::WriteAllBytes($packPath, $packBytes)
  Assert-Throws {
    Get-StackchanCanonicalGitLibraryRecords `
      -LibraryRoot $gitSecond -LibraryLeaf FixtureGitLibrary `
      -ExpectedPackageName FixtureGitLibrary -ExpectedSourceUri $fixtureUri `
      -ExpectedCommit $fixtureCommit
  } 'Git pack content identity mismatch'

  $requirementsPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'requirements-firmware-release.txt'
  $actualRequirements = @(
    Get-Content -LiteralPath $requirementsPath |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ -and -not $_.StartsWith('#') }
  )
  $expectedRequirements = @(
    'ajsonrpc==1.2.0', 'anyio==4.14.1', 'bottle==0.13.4',
    'certifi==2026.6.17', 'charset-normalizer==3.4.7', 'click==8.3.3',
    'colorama==0.4.6', 'h11==0.16.0', 'idna==3.18',
    'marshmallow==3.26.2', 'packaging==26.2', 'platformio==6.1.19',
    'pyelftools==0.33', 'pyserial==3.5', 'requests==2.34.2',
    'semantic-version==2.10.0', 'starlette==0.52.1', 'tabulate==0.10.0',
    'typing-extensions==4.15.0', 'urllib3==2.7.0', 'uvicorn==0.40.0',
    'wsproto==1.3.2'
  )
  Assert-True (($actualRequirements -join "`n") -ceq ($expectedRequirements -join "`n")) `
    'Firmware release Python requirements are not the reviewed exact transitive closure.'

  $helperText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'release_toolchain_identity.ps1') -Raw
  foreach ($pattern in @(
      'FileOptions]::SequentialScan', 'StringComparer]::OrdinalIgnoreCase',
      'FileAttributes]::ReparsePoint', 'NormalizationForm]::FormC',
      'candidate-unreviewed', 'refuses a reparse-point root',
      'entire Python installation as one closed root', 'exact-host-installed-bytes',
      'PYTHONNOUSERSITE', 'PYTHONSAFEPATH', 'python312.zip',
      'portableAcrossHosts')) {
    Assert-True ($helperText.Contains($pattern)) "Toolchain identity helper missing safety policy: $pattern"
  }
  $candidateText = Get-Content -LiteralPath (
    Join-Path $PSScriptRoot 'new_release_toolchain_identity_candidate.ps1') -Raw
  Assert-True ($candidateText.Contains('refuses to overwrite the reviewed allowlist')) `
    'Allowlist candidate workflow can overwrite reviewed policy without an explicit review step.'

  [pscustomobject][ordered]@{
    schema = 'stackchan.release-toolchain-identity-contract.v2'
    status = 'pass'
    fixtureFiles = $firstIdentity.fileCount
    policyComponents = $policy.Count
    pinnedPythonDistributions = $actualRequirements.Count
  } | ConvertTo-Json -Compress
} finally {
  foreach ($name in $isolationEnvironmentNames) {
    [Environment]::SetEnvironmentVariable(
      $name, $savedIsolationEnvironment[$name], [EnvironmentVariableTarget]::Process)
  }
  $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
  $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/')
  if ($resolvedTestRoot.StartsWith($resolvedTemp + [IO.Path]::DirectorySeparatorChar,
      [StringComparison]::OrdinalIgnoreCase) -and
      (Split-Path -Leaf $resolvedTestRoot).StartsWith(
        'stackchan-toolchain-identity-contract-', [StringComparison]::Ordinal)) {
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
