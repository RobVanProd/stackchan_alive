$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$packagePath = Join-Path $PSScriptRoot 'package_release.ps1'
$verifierPath = Join-Path $PSScriptRoot 'verify_release_package.ps1'
$helperPath = Join-Path $PSScriptRoot 'release_toolchain_identity.ps1'
$allowlistPath = Join-Path $PSScriptRoot 'release_toolchain_identity_allowlist.json'
$documentationContractPath = Join-Path $PSScriptRoot 'test_release_toolchain_documentation_contract.ps1'
$cacheContractPath = Join-Path $PSScriptRoot 'test_release_toolchain_cache_contract.ps1'
$pioarduinoSealPath = Join-Path $PSScriptRoot 'seal_pioarduino_release_core.ps1'

function Require-Text {
  param([string]$Text, [string]$Needle, [string]$Message)
  if (-not $Text.Contains($Needle)) { throw $Message }
}

function Require-Order {
  param([string]$Text, [string]$First, [string]$Second, [string]$Message)
  $firstIndex = $Text.IndexOf($First, [StringComparison]::Ordinal)
  $secondIndex = $Text.IndexOf($Second, [StringComparison]::Ordinal)
  if ($firstIndex -lt 0 -or $secondIndex -lt 0 -or $firstIndex -ge $secondIndex) {
    throw $Message
  }
}

$packageText = Get-Content -LiteralPath $packagePath -Raw
$verifierText = Get-Content -LiteralPath $verifierPath -Raw
$helperText = Get-Content -LiteralPath $helperPath -Raw
$semanticVerifierPath = Join-Path $PSScriptRoot 'verify_git_pack_semantics.py'
$authorityRelativePaths = @(
  'tools/release_toolchain_identity_allowlist.json',
  'tools/release_toolchain_identity.ps1',
  'tools/verify_git_pack_semantics.py'
)
$attributeOutput = @(& git -C (Split-Path -Parent $PSScriptRoot) `
    check-attr text eol -- @authorityRelativePaths)
if ($LASTEXITCODE -ne 0) {
  throw 'Release authority line-ending policy could not be queried through Git.'
}
foreach ($relativePath in $authorityRelativePaths) {
  if ("$relativePath`: text: set" -cnotin $attributeOutput -or
      "$relativePath`: eol: lf" -cnotin $attributeOutput) {
    throw "Release byte authority is not forced to LF in every checkout: $relativePath"
  }
}
$exactBootstrapPins = [ordered]@{
  'allowlist' = (Get-FileHash -Algorithm SHA256 -LiteralPath $allowlistPath).Hash
  'identity helper' = (Get-FileHash -Algorithm SHA256 -LiteralPath $helperPath).Hash
  'semantic verifier' = (Get-FileHash -Algorithm SHA256 -LiteralPath $semanticVerifierPath).Hash
}
foreach ($entry in $exactBootstrapPins.GetEnumerator()) {
  $literal = "'$([string]$entry.Value)' # reviewed $([string]$entry.Key) SHA-256"
  Require-Text $packageText $literal `
    "Release packager has a stale reviewed $([string]$entry.Key) bootstrap pin."
  Require-Text $verifierText $literal `
    "Release verifier has a stale reviewed $([string]$entry.Key) bootstrap pin."
}

foreach ($parameter in @(
    'ToolchainAllowlistPath', 'GitExecutable', 'PythonExecutable',
    'PlatformioExecutable', 'LegacyCoreDir', 'ReleaseCoreDir')) {
  Require-Text $packageText "`$$parameter" "Release packager is missing explicit $parameter authority."
  Require-Text $verifierText "`$$parameter" "Release verifier is missing explicit $parameter authority."
}

foreach ($text in @($packageText, $verifierText)) {
  if ($text.Contains('No tracked reviewed exact toolchain allowlist currently authorizes')) {
    throw 'Permanent release-toolchain refusal remains in an operational release path.'
  }
  foreach ($needle in @(
      'release_toolchain_identity_allowlist.json', 'release_toolchain_identity.ps1',
      'verify_git_pack_semantics.py', 'Assert-StackchanReleaseToolchainIdentity',
      '-Phase PreBuild', 'allowlistSha256', 'observationSha256')) {
    Require-Text $text $needle "Release path is missing toolchain authority/provenance logic: $needle"
  }
  if ($text -notmatch "(?m)'[0-9A-F]{64}'\s*# reviewed allowlist SHA-256" -or
      $text -notmatch "(?m)'[0-9A-F]{64}'\s*# reviewed identity helper SHA-256" -or
      $text -notmatch "(?m)'[0-9A-F]{64}'\s*# reviewed semantic verifier SHA-256") {
    throw 'Release entry point lacks literal pre-Git byte authority for its allowlist/helper/verifier.'
  }
}

Require-Order $packageText 'Assert-StackchanReleaseToolchainIdentity' `
  'Assert-ReleaseBootstrapTrust -Root' `
  'Packager does not assert exact PreBuild identity before first trusted Git execution.'
Require-Order $verifierText 'Assert-StackchanReleaseToolchainIdentity' `
  "Invoke-TrustedVerifierGit -Arguments @('describe'" `
  'Verifier does not assert exact PreBuild identity before first trusted Git execution.'

foreach ($needle in @(
    'Assert-StackchanReleaseBuildPythonEnvironment', 'Remove-Item Env:\PYTHONSAFEPATH',
    'previousPythonSafePath', 'releaseToolchainIdentityRecords',
    "'preExecution'", "'postBuild'", "'pkg', 'install'",
    '-Environment $Environment', '$releaseToolchainEligible')) {
  Require-Text $packageText $needle "Packager is missing fail-closed build identity behavior: $needle"
}
Require-Order $packageText "'pkg', 'install'" '-Phase PostBuild' `
  'Packager does not semantically authenticate resolved dependencies after staging.'
Require-Order $packageText '-Phase PostBuild' '@("run", "-d", $BuildProjectRoot' `
  'Packager executes clean/build before staged dependencies are authenticated.'

foreach ($needle in @(
    'toolchainIdentity', 'allowlistSha256', 'identityHelperSha256',
    'semanticVerifierSha256', 'preExecution', 'postBuild',
    '$releaseToolchainEligible -and (-not $SkipBuild)')) {
  Require-Text $packageText $needle "Release manifest/eligibility is not bound to toolchain proof: $needle"
}
foreach ($needle in @(
    'toolchainIdentity', 'allowlistSha256', 'identityHelperSha256',
    'semanticVerifierSha256', 'preExecution', 'postBuild',
    'Assert-OperationalFirmwareMatchesTrustedRebuild')) {
  Require-Text $verifierText $needle "Verifier does not independently enforce toolchain proof: $needle"
}
Require-Order $verifierText 'Assert-StackchanReleaseBuildPythonEnvironment -ProjectRoot $rebuildWorktree' `
  '$pioExecutable --version' `
  'Verifier executes PlatformIO before establishing the approved build-Python environment.'
Require-Order $verifierText '$pioExecutable --version' "& `$pioExecutable 'pkg' 'install'" `
  'Verifier does not validate the exact PlatformIO launcher before dependency staging.'

foreach ($needle in @(
    'release-toolchain-identity-policy-source', 'Environment',
    'allowlistSha256', 'observationSha256',
    'Release build Python environment refuses ambient import/runtime override',
    'New-StackchanToolchainLeaseState', 'Add-StackchanToolchainFileLease',
    'FileSystemWatcher', 'InternalBufferSize = 65536', 'Register-ObjectEvent',
    'watcher subscription missing', 'VerifyNamespace', 'preBuildVerified',
    'Guarded PostBuild identity requires the same session to verify PreBuild first',
    'preBuildComponents', 'preBuildAuthorityKey', 'preBuildScope',
    'PostBuild cached PreBuild reuse', 'PostBuildComponentsOnly',
    'Copy-StackchanToolchainIdentityComponents')) {
  Require-Text $helperText $needle "Identity helper is missing required integration behavior: $needle"
}

$sealText = Get-Content -LiteralPath $pioarduinoSealPath -Raw
foreach ($sealNeedle in @(
    '6FC4C8912CBB1FA65A84A527EC5A3CB1280BBA399B02D4885C8C1D91AB7CC9D0',
    'D16479CFAD23EF7C392B48C66B9E2422C0294E185746814ED4F7F9E4EFFACB60',
    '"pioarduino-core"', 'name in ("platformio", "pioarduino-core")',
    '[IO.File]::Replace', 'output/private/toolchain-backups')) {
  Require-Text $sealText $sealNeedle "Pioarduino release-core seal is missing: $sealNeedle"
}
foreach ($packagedSealInput in @(
    'tools/test_release_toolchain_cache_contract.ps1',
    'tools/seal_pioarduino_release_core.ps1')) {
  Require-Text $packageText $packagedSealInput `
    "Packager does not bind/copy sealed-toolchain governance input: $packagedSealInput"
}
$guardedAssertText = $helperText.Substring(
  $helperText.IndexOf('function Assert-StackchanReleaseToolchainIdentity', [StringComparison]::Ordinal))
Require-Order $guardedAssertText 'Release toolchain byte identity mismatch' `
  'Assert-StackchanPythonImportIsolation' `
  'Guarded identity executes Python before installed bytes match the reviewed allowlist.'

foreach ($entry in @(
    [ordered]@{
      text = $packageText; state = '$script:releaseToolchainLeaseState'; label = 'packager'
      cleanup = 'Close-ReleaseToolchainResources'; leases = '$script:releaseToolchainReadLeases.Clear()'
    },
    [ordered]@{
      text = $verifierText; state = '$script:verifierToolchainLeaseState'; label = 'verifier'
      cleanup = 'Close-VerifierToolchainResources'; leases = '$script:verifierToolchainReadLeases.Clear()'
    })) {
  foreach ($needle in @(
      'New-StackchanToolchainLeaseState', '-LeaseState ' + [string]$entry.state,
      '-LeaseScope', 'Assert-StackchanToolchainLeaseStateUnchanged',
      'Close-StackchanToolchainLeaseScope', 'Close-StackchanToolchainLeaseState',
      '-RequireUnchanged')) {
    Require-Text ([string]$entry.text) $needle `
      "Release $([string]$entry.label) is missing lifetime-guard behavior: $needle"
  }
  foreach ($cleanupNeedle in @([string]$entry.cleanup, [string]$entry.leases, '.Dispose()')) {
    Require-Text ([string]$entry.text) $cleanupNeedle `
      "Release $([string]$entry.label) is missing explicit resource cleanup: $cleanupNeedle"
  }
}
Require-Order $packageText 'trap {' 'if (-not $SkipBuild) {' `
  'Packager failure cleanup is not registered before guarded pre-build authentication.'
Require-Order $verifierText 'trap {' '$ambientGitOverrides =' `
  'Verifier failure cleanup is not registered before guarded pre-build authentication.'
Require-Order $packageText "-Context 'release toolchain eligibility decision' -VerifyNamespace" `
  '$releaseToolchainEligible = $true' `
  'Packager can establish eligibility before its final guarded namespace barrier.'
foreach ($scopeContext in @(
    "-RequireUnchanged -Context 'cycle-a final authenticated namespace'",
    "-RequireUnchanged -Context 'cycle-b final authenticated namespace'")) {
  Require-Text $packageText $scopeContext `
    "Packager scope closure lacks its final guarded namespace barrier: $scopeContext"
}
foreach ($context in @(
    'before trusted Git execution', 'after trusted Git execution',
    'before PlatformIO execution', 'after PlatformIO execution')) {
  Require-Text $packageText $context "Packager does not guard external execution: $context"
}
foreach ($context in @(
    'before trusted verifier Git execution', 'after trusted verifier Git execution',
    'before PlatformIO version execution', 'after PlatformIO version execution',
    'independent rebuild final authenticated namespace',
    'completed release-eligible verification')) {
  Require-Text $verifierText $context "Verifier does not guard external execution: $context"
}

if (-not (Test-Path -LiteralPath $allowlistPath -PathType Leaf)) {
  throw 'Reviewed release toolchain allowlist is missing.'
}
$allowlist = Get-Content -LiteralPath $allowlistPath -Raw | ConvertFrom-Json
if ([string]$allowlist.review.status -cne 'reviewed' -or
    [string]::IsNullOrWhiteSpace([string]$allowlist.review.reviewer) -or
    [string]::IsNullOrWhiteSpace([string]$allowlist.review.reason) -or
    @($allowlist.components).Count -ne 24) {
  throw 'Tracked release toolchain allowlist is not the reviewed 24-component policy.'
}

$broadContract = Get-Content -LiteralPath (
  Join-Path $PSScriptRoot 'test_firmware_reproducible_build_contract.ps1') -Raw
Require-Text $broadContract 'test_release_toolchain_integration_contract.ps1' `
  'Firmware reproducibility gate does not run the release-toolchain integration contract.'

$authorityNames = @(
  'ToolchainAllowlistPath', 'GitExecutable', 'PythonExecutable',
  'PlatformioExecutable', 'LegacyCoreDir', 'ReleaseCoreDir')
foreach ($relative in @(
    'audit_published_release.ps1', 'export_rollout_status.ps1',
    'flash_release_firmware.ps1', 'prepare_device_arrival.ps1',
    'publish_release.ps1', 'run_device_preflight.ps1', 'share_release.ps1',
    'start_bridge_ai_supervised_qualification.ps1', 'start_hardware_evidence.ps1',
    'verify_consumer_promotion.ps1', 'verify_published_release.ps1')) {
  $callerText = Get-Content -LiteralPath (Join-Path $PSScriptRoot $relative) -Raw
  if ($relative -cne 'audit_published_release.ps1') {
    Require-Text $callerText 'RequireReleaseEligible' `
      "Operational caller does not preserve the release-eligibility gate: $relative"
  }
  foreach ($authorityName in $authorityNames) {
    Require-Text $callerText $authorityName `
      "Operational caller does not propagate $authorityName authority: $relative"
  }
}
$hardwareEvidenceText = Get-Content -LiteralPath (
  Join-Path $PSScriptRoot 'start_hardware_evidence.ps1') -Raw
foreach ($generatedCommand in @(
    '$displayCommand', '$servoCommand', '$verifyCommand',
    '$rolloutStatusCommand', '$consumerPromotionCommand')) {
  if ($hardwareEvidenceText -notmatch (
      '(?m)^\s*' + [regex]::Escape($generatedCommand) +
      '.*\$toolchainCommandArguments')) {
    throw "Generated evidence command does not carry reviewed toolchain authority: $generatedCommand"
  }
}

$workflowText = Get-Content -LiteralPath (
  Join-Path (Split-Path -Parent $PSScriptRoot) '.github/workflows/release.yml') -Raw
foreach ($needle in @(
    'runs-on: [self-hosted, Windows, X64, stackchan-release-toolchain-20260803]',
    'STACKCHAN_RELEASE_GIT_EXECUTABLE', 'STACKCHAN_RELEASE_PYTHON_EXECUTABLE',
    'STACKCHAN_RELEASE_PLATFORMIO_EXECUTABLE', 'STACKCHAN_RELEASE_LEGACY_CORE_DIR',
    'STACKCHAN_RELEASE_RELEASE_CORE_DIR', 'release_toolchain_identity_allowlist.json')) {
  Require-Text $workflowText $needle "Release workflow is missing exact-host authority: $needle"
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $documentationContractPath
if ($LASTEXITCODE -ne 0) {
  throw 'Release toolchain documentation contract failed.'
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $cacheContractPath
if ($LASTEXITCODE -ne 0) {
  throw 'Release toolchain cache contract failed.'
}

Write-Output 'Release toolchain integration contract passed.'
