$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release_dependency_evidence.ps1')
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$packageText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'package_release.ps1') -Raw
$verifyText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'verify_release_package.ps1') -Raw
foreach ($required in @(
  "@('pkg', 'list', '-d', `$BuildProjectRoot, '-e', `$Environment, '-v')",
  'Get-StackchanVerbosePlatformSource',
  'platform/$PlatformSourceLeaf/$metadataName',
  'Copy-StackchanResolvedCorePackageEvidence'
)) {
  if (-not $packageText.Contains($required)) {
    throw "Production dependency snapshot wiring is missing: $required"
  }
}
if ($packageText.Contains('platform/espressif32/$metadataName') -or
    $packageText.Contains("-SourceRoot (Join-Path `$coreDir 'packages')")) {
  throw 'Production dependency evidence still contains a broad or hard-coded source path'
}
if (-not $verifyText.Contains('Assert-StackchanSingleResolvedPackageVersion') -or
    -not $verifyText.Contains('-Name "M5GFX" -ExpectedVersion "0.2.24"') -or
    -not $verifyText.Contains('-Name "M5Unified" -ExpectedVersion "0.2.17"') -or
    $verifyText.Contains('$knownPinnedM5GfxWithTransitiveCopy') -or
    $verifyText.Contains('$duplicateVersions[1] -eq "0.2.26"')) {
  throw 'Release verifier does not require one exact M5GFX 0.2.24 package or still permits the rejected duplicate'
}

$exactM5Gfx = [pscustomobject]@{
  kind = 'package'; name = 'M5GFX'; version = '0.2.24'; required = 'M5Stack/M5GFX @ 0.2.24'
}
Assert-StackchanSingleResolvedPackageVersion `
  -ResolvedPackages @($exactM5Gfx) -Environment stackchan_release_full `
  -Name M5GFX -ExpectedVersion 0.2.24
$rejectedResolvedPackageCases = @(
  [pscustomobject]@{ packages = @(
      $exactM5Gfx,
      [pscustomobject]@{
        kind = 'package'; name = 'M5GFX'; version = '0.2.26'; required = 'M5GFX @ >=0.2.22'
      }
    ) },
  [pscustomobject]@{ packages = @(
      $exactM5Gfx,
      [pscustomobject]@{
        kind = 'PACKAGE'; name = 'm5gfx'; version = '0.2.26'; required = 'M5GFX @ >=0.2.22'
      }
    ) },
  [pscustomobject]@{ packages = @(
      [pscustomobject]@{
        kind = 'package'; name = 'M5GFX'; version = '0.2.26'; required = 'M5GFX @ >=0.2.22'
      }
    ) }
)
if ($rejectedResolvedPackageCases.Count -ne 3 -or
    @($rejectedResolvedPackageCases[0].packages).Count -ne 2 -or
    @($rejectedResolvedPackageCases[1].packages).Count -ne 2 -or
    @($rejectedResolvedPackageCases[2].packages).Count -ne 1) {
  throw 'Resolved-package rejection fixtures lost their duplicate/wrong-version shapes'
}
foreach ($resolvedPackageCase in $rejectedResolvedPackageCases) {
  $rejected = $false
  try {
    Assert-StackchanSingleResolvedPackageVersion `
      -ResolvedPackages @($resolvedPackageCase.packages) -Environment stackchan_release_full `
      -Name M5GFX -ExpectedVersion 0.2.24
  } catch {
    if ($_.Exception.Message -notmatch 'must appear exactly once at the reviewed version') { throw }
    $rejected = $true
  }
  if (-not $rejected) {
    throw 'Exact resolved-package contract accepted a wrong or duplicate M5GFX inventory'
  }
}
$exactM5Unified = [pscustomobject]@{
  kind = 'package'; name = 'M5Unified'; version = '0.2.17'; required = 'M5Stack/M5Unified @ 0.2.17'
}
Assert-StackchanSingleResolvedPackageVersion `
  -ResolvedPackages @($exactM5Unified) -Environment stackchan `
  -Name M5Unified -ExpectedVersion 0.2.17
$rejectedUnifiedDuplicate = $false
try {
  Assert-StackchanSingleResolvedPackageVersion `
    -ResolvedPackages @(
      $exactM5Unified,
      [pscustomobject]@{
        kind = 'package'; name = 'm5unified'; version = '0.2.19'; required = 'M5Stack/M5Unified @ ^0.2.5'
      }) `
    -Environment stackchan -Name M5Unified -ExpectedVersion 0.2.17
} catch {
  if ($_.Exception.Message -notmatch 'must appear exactly once at the reviewed version') { throw }
  $rejectedUnifiedDuplicate = $true
}
if (-not $rejectedUnifiedDuplicate) {
  throw 'Exact resolved-package contract accepted a duplicate M5Unified inventory'
}

$platformioLines = Get-Content -LiteralPath (Join-Path $RepoRoot 'platformio.ini')
$qualifiedM5Gfx = 'M5Stack/M5GFX@0.2.24'
$qualifiedM5Unified = 'M5Stack/M5Unified@0.2.17'
$m5DependencyBlocks = 0
for ($lineIndex = 0; $lineIndex -lt $platformioLines.Count; $lineIndex++) {
  if ($platformioLines[$lineIndex] -notmatch '^\s*lib_deps\s*=\s*$') { continue }
  $dependencies = [Collections.Generic.List[string]]::new()
  for ($dependencyIndex = $lineIndex + 1;
      $dependencyIndex -lt $platformioLines.Count;
      $dependencyIndex++) {
    $dependencyLine = [string]$platformioLines[$dependencyIndex]
    if ($dependencyLine -match '^\s*\[' -or $dependencyLine -match '^\s*\S+\s*=') { break }
    if ($dependencyLine -match '^\s+(?<dependency>\S.*\S|\S)\s*$') {
      $dependencies.Add($Matches.dependency) | Out-Null
    }
  }
  $m5GfxEntries = @($dependencies | Where-Object { $_ -match '(?:^|/)M5GFX@' })
  $m5UnifiedEntries = @($dependencies | Where-Object { $_ -match '(?:^|/)M5Unified@' })
  if ($m5GfxEntries.Count -eq 0 -and $m5UnifiedEntries.Count -eq 0) { continue }
  $m5DependencyBlocks++
  if ($m5GfxEntries.Count -ne 1 -or $m5GfxEntries[0] -cne $qualifiedM5Gfx -or
      $m5UnifiedEntries.Count -ne 1 -or $m5UnifiedEntries[0] -cne $qualifiedM5Unified) {
    throw "PlatformIO lib_deps block lacks one owner-qualified exact M5GFX/M5Unified pair at line $($lineIndex + 1)"
  }
  if ($dependencies.IndexOf($qualifiedM5Gfx) -ne 0 -or
      $dependencies.IndexOf($qualifiedM5Unified) -ne 1) {
    throw "PlatformIO lib_deps must install the exact M5GFX/M5Unified pair before every transitive dependency at line $($lineIndex + 1)"
  }
}
if ($m5DependencyBlocks -ne 8) {
  throw "PlatformIO owner-qualified M5 dependency block count changed: $m5DependencyBlocks"
}

$root = Join-Path ([System.IO.Path]::GetTempPath()) (
  'stackchan-dependency-evidence-contract-' + [guid]::NewGuid().ToString('N'))
try {
  $corePackages = Join-Path $root 'core/packages'
  $corePlatforms = Join-Path $root 'core/platforms'
  $destination = Join-Path $root 'snapshot/packages'
  foreach ($name in @('tool-alpha', 'stale-evil')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $corePackages $name) | Out-Null
    Set-Content -LiteralPath (Join-Path $corePackages "$name/package.json") -Value "{}`n" -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $corePackages "$name/LICENSE") -Value "$name license`n" -Encoding ASCII
  }
  foreach ($leaf in @('espressif32', 'espressif32@7.0.1')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $corePlatforms $leaf) | Out-Null
  }
  $selectedPlatform = Get-StackchanVerbosePlatformSource `
    -VerbosePackageList (
      'Platform espressif32 @ 7.0.1 (required: espressif32 @ 7.0.1, ' +
      (Join-Path $corePlatforms 'espressif32@7.0.1') + ')') `
    -PlatformioCoreDir (Join-Path $root 'core')
  if ($selectedPlatform.sourceLeaf -cne 'espressif32@7.0.1') {
    throw 'Verbose dependency evidence selected a stale same-name platform directory'
  }
  $resolved = @(
    [pscustomobject]@{ kind = 'package'; name = 'tool-alpha'; version = '1.0.0'; required = 'tool-alpha' },
    [pscustomobject]@{ kind = 'package'; name = 'library-only'; version = '2.0.0'; required = 'library-only' }
  )
  $names = @(Get-StackchanResolvedCorePackageNames `
    -ResolvedPackages $resolved -CorePackagesRoot $corePackages)
  if ($names.Count -ne 1 -or $names[0] -cne 'tool-alpha') {
    throw "Resolved core-package selection included stale or non-core packages"
  }
  Copy-StackchanResolvedCorePackageEvidence `
    -CorePackagesRoot $corePackages -DestinationRoot $destination -CorePackageNames $names
  if (-not (Test-Path -LiteralPath (Join-Path $destination 'tool-alpha/LICENSE')) -or
      (Test-Path -LiteralPath (Join-Path $destination 'stale-evil'))) {
    throw "Dependency snapshot did not isolate the resolved core-package allowlist"
  }
  Assert-StackchanCorePackageEvidenceAllowlisted `
    -Environment 'stackchan' -CorePackageNames $names `
    -IndexedThirdPartyPaths @('stackchan/packages/tool-alpha/LICENSE')
  try {
    Assert-StackchanCorePackageEvidenceAllowlisted `
      -Environment 'stackchan' -CorePackageNames $names `
      -IndexedThirdPartyPaths @(
        'stackchan/packages/tool-alpha/LICENSE',
        'stackchan/packages/stale-evil/LICENSE')
    throw "Dependency evidence allowlist accepted a stale shared-core package"
  } catch {
    if ($_.Exception.Message -eq 'Dependency evidence allowlist accepted a stale shared-core package') { throw }
  }
} finally {
  if (Test-Path -LiteralPath $root) {
    [System.IO.Directory]::Delete($root, $true)
  }
}

Write-Host 'Release dependency-evidence contract passed.'
