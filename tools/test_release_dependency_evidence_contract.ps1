$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'release_dependency_evidence.ps1')

$packageText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'package_release.ps1') -Raw
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
