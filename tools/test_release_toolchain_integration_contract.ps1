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

function Require-Count {
  param([string]$Text, [string]$Needle, [int]$Expected, [string]$Message)
  $count = [regex]::Matches($Text, [regex]::Escape($Needle)).Count
  if ($count -ne $Expected) { throw "$Message Observed count: $count" }
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
foreach ($needle in @(
    'Get-ReleaseShortPathPhysicalRoot',
    "'rev-parse', '--show-prefix'",
    '-not [string]::IsNullOrEmpty($prefix)',
    "'^(?<drive>[A-Za-z]):\\: => (?<target>.+)$'",
    'requires exactly one verified subst mapping',
    'refuses a missing, non-directory, or redirected subst target',
    '-ExpectedGitTopLevel $bootstrapGitTopLevel',
    'detected a changed subst mapping during bootstrap trust verification',
    "Join-Path `$bootstrapGitTopLevel 'tools/verify_release_package.ps1'",
    '"-File", $trustedVerifierScriptPath')) {
  Require-Text $packageText $needle `
    "Packager is missing fail-closed subst/Git top-level reconciliation: $needle"
}
Require-Count $packageText `
  'Get-ReleaseShortPathPhysicalRoot -LogicalRoot $physicalRepoRoot' 2 `
  'Packager must verify the subst target both before and after Git bootstrap trust.'
$packageTokens = $null
$packageParseErrors = $null
$packageAst = [System.Management.Automation.Language.Parser]::ParseFile(
  $packagePath, [ref]$packageTokens, [ref]$packageParseErrors)
if (@($packageParseErrors).Count -ne 0) {
  throw 'Release packager cannot be parsed for short-path regression testing.'
}
$bootstrapTrustFunctions = @($packageAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Assert-ReleaseBootstrapTrust'
}, $true))
if ($bootstrapTrustFunctions.Count -ne 1) {
  throw 'Release packager must define one bootstrap-trust function.'
}
$bootstrapFileAssignments = @($bootstrapTrustFunctions[0].Body.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -ceq '$bootstrapFiles'
}, $true))
$bootstrapVerifierEntries = @(if ($bootstrapFileAssignments.Count -eq 1) {
  $bootstrapFileAssignments[0].Right.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
      $node.Value -ceq 'tools/verify_release_package.ps1'
  }, $true)
})
if ($bootstrapFileAssignments.Count -ne 1 -or $bootstrapVerifierEntries.Count -ne 1) {
  throw 'Release packager bootstrap trust must authenticate the physical verifier exactly once.'
}
$shortPathFunction = $packageAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Get-ReleaseShortPathPhysicalRoot'
  }, $true)
if ($null -eq $shortPathFunction) {
  throw 'Release packager short-path resolver function is unavailable for regression testing.'
}
. ([scriptblock]::Create($shortPathFunction.Extent.Text))
$script:releaseSubstExecutable = Join-Path ([Environment]::SystemDirectory) 'subst.exe'
$shortPathRepoRoot = (Resolve-Path (Split-Path -Parent $PSScriptRoot)).Path
$canonicalShortPathRepoRoot = (& git -C $shortPathRepoRoot rev-parse --show-toplevel |
  Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($canonicalShortPathRepoRoot)) {
  throw 'Release short-path regression test could not resolve the canonical Git top-level.'
}
$canonicalShortPathRepoRoot = [IO.Path]::GetFullPath(
  $canonicalShortPathRepoRoot).TrimEnd('\', '/')
$allowedShortPathRoots = @('R:\', 'Q:\', 'P:\', 'O:\')
$shortPathRepoFull = [IO.Path]::GetFullPath($shortPathRepoRoot)
$shortPathRepoDriveRoot = [IO.Path]::GetPathRoot($shortPathRepoFull)
$createdShortPathMapping = $false
if ($allowedShortPathRoots -contains $shortPathRepoDriveRoot -and
    $shortPathRepoFull.TrimEnd('\', '/').Equals(
      $shortPathRepoDriveRoot.TrimEnd('\', '/'),
      [StringComparison]::OrdinalIgnoreCase)) {
  $shortPathDrive = $shortPathRepoDriveRoot.TrimEnd('\')
  $shortPathLogicalRoot = $shortPathRepoDriveRoot
} else {
  $shortPathDrive = @('R:', 'Q:', 'P:', 'O:') |
    Where-Object { -not (Test-Path -LiteralPath "$_\") } |
    Select-Object -First 1
  if ([string]::IsNullOrWhiteSpace($shortPathDrive)) {
    throw 'Release short-path regression test requires one free governed subst drive.'
  }
  & $script:releaseSubstExecutable $shortPathDrive $shortPathRepoRoot
  if ($LASTEXITCODE -ne 0) {
    throw 'Release short-path regression test could not create its temporary subst mapping.'
  }
  $createdShortPathMapping = $true
  $shortPathLogicalRoot = "$shortPathDrive\"
}
try {
  $observedPhysicalRoot = Get-ReleaseShortPathPhysicalRoot -LogicalRoot $shortPathLogicalRoot
  if (-not $observedPhysicalRoot.Equals(
      $canonicalShortPathRepoRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Release short-path regression test did not recover the exact physical repository root.'
  }
  $physicalVerifierScript = [IO.Path]::GetFullPath(
    (Join-Path $observedPhysicalRoot 'tools/verify_release_package.ps1'))
  $expectedPhysicalVerifierScript = [IO.Path]::GetFullPath(
    (Join-Path $canonicalShortPathRepoRoot 'tools/verify_release_package.ps1'))
  $logicalVerifierScript = [IO.Path]::GetFullPath(
    (Join-Path "$shortPathDrive\tools" 'verify_release_package.ps1'))
  if (-not $physicalVerifierScript.Equals(
      $expectedPhysicalVerifierScript, [System.StringComparison]::OrdinalIgnoreCase) -or
      $physicalVerifierScript.Equals(
        $logicalVerifierScript, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Release short-path regression test did not select the physical verifier checkout.'
  }
  $nestedRejected = $false
  try {
    Get-ReleaseShortPathPhysicalRoot -LogicalRoot "$shortPathDrive\tools" | Out-Null
  } catch {
    $nestedRejected = $true
  }
  if (-not $nestedRejected) {
    throw 'Release short-path regression test accepted a nested logical checkout root.'
  }
} finally {
  if ($createdShortPathMapping) {
    & $script:releaseSubstExecutable $shortPathDrive /D | Out-Null
    if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath "$shortPathDrive\")) {
      throw 'Release short-path regression test did not remove its temporary subst mapping.'
    }
  }
}
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
$verifierTokens = $null
$verifierParseErrors = $null
$verifierAst = [System.Management.Automation.Language.Parser]::ParseFile(
  $verifierPath, [ref]$verifierTokens, [ref]$verifierParseErrors)
if (@($verifierParseErrors).Count -ne 0) {
  throw 'Release verifier cannot be parsed for PlatformIO execution-order testing.'
}
$operationalRebuildFunctions = @($verifierAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Assert-OperationalFirmwareMatchesTrustedRebuild'
}, $true))
if ($operationalRebuildFunctions.Count -ne 1) {
  throw 'Release verifier must define one operational independent-rebuild function.'
}
$operationalCommands = @($operationalRebuildFunctions[0].Body.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.CommandAst]
}, $true))
$buildPythonAssertions = @($operationalCommands | Where-Object {
  $_.GetCommandName() -ceq 'Assert-StackchanReleaseBuildPythonEnvironment'
})
$nativeCaptureCalls = @($operationalCommands | Where-Object {
  $_.GetCommandName() -ceq 'Invoke-StackchanVerifierNativeCapture'
})
$captureSpecifications = @(
  [ordered]@{
    result = '$pioVersionResult'; arguments = "@('--version')"
    consumer = '$pioVersion'
    consumerRhs = '((@($pioVersionResult.output) | Out-String).Trim())'
  },
  [ordered]@{
    result = '$dependencyStageResult'
    arguments = "@('pkg', 'install', '-d', `$rebuildWorktree, '-e', `$environment)"
    consumer = '$dependencyStageOutput'; consumerRhs = '@($dependencyStageResult.output)'
  },
  [ordered]@{
    result = '$phaseResult'; arguments = '$pioArguments'
    consumer = '$phaseOutput'; consumerRhs = '@($phaseResult.output)'
  },
  [ordered]@{
    result = '$packageListResult'
    arguments = "@('pkg', 'list', '-d', `$rebuildWorktree, '-e', `$environment)"
    consumer = '$packageListOutput'; consumerRhs = '@($packageListResult.output)'
  },
  [ordered]@{
    result = '$verbosePackageResult'
    arguments = "@('pkg', 'list', '-d', `$rebuildWorktree, '-e', `$environment, '-v')"
    consumer = '$verbosePackageOutput'; consumerRhs = '@($verbosePackageResult.output)'
  }
)
if ($buildPythonAssertions.Count -ne 1 -or
    $nativeCaptureCalls.Count -ne $captureSpecifications.Count) {
  throw 'Verifier operational PlatformIO execution topology is not the reviewed five-site shape.'
}
$boundCaptureCalls = @{}
$operationalAssignments = @($operationalRebuildFunctions[0].Body.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.AssignmentStatementAst]
}, $true))
foreach ($specification in $captureSpecifications) {
  $matches = @($nativeCaptureCalls | Where-Object {
    $_.Parent -is [System.Management.Automation.Language.PipelineAst] -and
    $_.Parent.Parent -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $_.Parent.Parent.Left.Extent.Text -ceq [string]$specification.result
  })
  if ($matches.Count -ne 1) {
    throw "Verifier PlatformIO capture is not bound to its reviewed result: $($specification.result)"
  }
  $call = $matches[0]
  $elements = @($call.CommandElements)
  if ($call.Parent.Parent.Operator -ne
        [System.Management.Automation.Language.TokenKind]::Equals -or
      $call.Parent.Parent.Right -ne $call.Parent -or $elements.Count -ne 5 -or
      $elements[1] -isnot [System.Management.Automation.Language.CommandParameterAst] -or
      $elements[1].ParameterName -cne 'Executable' -or
      $elements[2] -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
      $elements[2].VariablePath.UserPath -cne 'pioExecutable' -or
      $elements[3] -isnot [System.Management.Automation.Language.CommandParameterAst] -or
      $elements[3].ParameterName -cne 'Arguments' -or
      [regex]::Replace($elements[4].Extent.Text.Trim(), '\s+', ' ') -cne
        [string]$specification.arguments) {
    throw "Verifier PlatformIO executable/arguments differ from reviewed topology: $($specification.result)"
  }
  $resultAssignments = @($operationalAssignments | Where-Object {
    $_.Left.Extent.Text -ceq [string]$specification.result
  })
  $consumerAssignments = @($operationalAssignments | Where-Object {
    $_.Left.Extent.Text -ceq [string]$specification.consumer
  })
  if ($resultAssignments.Count -ne 1 -or
      $resultAssignments[0].Extent.StartOffset -ne $call.Parent.Parent.Extent.StartOffset -or
      $consumerAssignments.Count -ne 1 -or
      $consumerAssignments[0].Operator -ne
        [System.Management.Automation.Language.TokenKind]::Equals -or
      [regex]::Replace($consumerAssignments[0].Right.Extent.Text.Trim(), '\s+', ' ') -cne
        [string]$specification.consumerRhs -or
      $call.Extent.StartOffset -ge $consumerAssignments[0].Extent.StartOffset) {
    throw "Verifier PlatformIO output is not uniquely bound to its reviewed consumer: $($specification.result)"
  }
  $boundCaptureCalls[[string]$specification.result] = $call
}
$pioArgumentAssignments = @($operationalRebuildFunctions[0].Body.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -ceq '$pioArguments'
}, $true))
$phaseLoops = @($operationalRebuildFunctions[0].Body.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
    $node.Variable.VariablePath.UserPath -ceq 'phase' -and
    [regex]::Replace($node.Condition.Extent.Text.Trim(), '\s+', ' ') -ceq
      "@('clean', 'build')"
}, $true))
if ($pioArgumentAssignments.Count -ne 2 -or $phaseLoops.Count -ne 1 -or
    @($pioArgumentAssignments | Where-Object {
      $_.Operator -eq [System.Management.Automation.Language.TokenKind]::Equals -and
      [regex]::Replace($_.Right.Extent.Text.Trim(), '\s+', ' ') -ceq
        "@('run', '-d', `$rebuildWorktree, '-e', `$environment)"
    }).Count -ne 1 -or
    @($pioArgumentAssignments | Where-Object {
      $_.Operator -eq [System.Management.Automation.Language.TokenKind]::PlusEquals -and
      [regex]::Replace($_.Right.Extent.Text.Trim(), '\s+', ' ') -ceq "@('-t', 'clean')"
    }).Count -ne 1) {
  throw 'Verifier clean/build PlatformIO argument construction is not the reviewed loop topology.'
}
$pioVersionCall = $boundCaptureCalls['$pioVersionResult']
$dependencyStageCall = $boundCaptureCalls['$dependencyStageResult']
if ($buildPythonAssertions[0].Extent.StartOffset -ge $pioVersionCall.Extent.StartOffset) {
  throw 'Verifier executes PlatformIO before establishing the approved build-Python environment.'
}
if ($pioVersionCall.Extent.StartOffset -ge $dependencyStageCall.Extent.StartOffset) {
  throw 'Verifier does not validate the exact PlatformIO launcher before dependency staging.'
}

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
    '756B5AAF863F0BCC0E7CB88C9DDBA3FCE2055E1DC6A4D7362ADC057F813324F8',
    'DCABDC11CA1DEA4FBF3854811BF24CD2ADC9AD692785FB27B1EBA0CF41C924E7',
    '"pioarduino-core"', 'name in ("platformio", "pioarduino-core")',
    'if lib_ignore_entries:', 'self._backup_pioarduino_build_py()',
    'self.backup_manager.backup_pioarduino_build_py()',
    'component-manager-noop-and-lto',
    'Assert-ExistingPathChainReal', 'Assert-PathContained',
    'Get-PathVolumeRoot', "ParameterSetName = 'SelfTest'",
    'Invoke-SealTargetTransaction', 'stackchan.pioarduino-seal-selftest.v1',
    "'prepare-second'", "'install-second'",
    'Refusing stale $([string]$target.label) transaction artifact',
    '[IO.File]::Replace', 'stackchan-displaced-',
    'stackchan-rollback-', '$rollbackFailures',
    'output/private/toolchain-backups')) {
  Require-Text $sealText $sealNeedle "Pioarduino release-core seal is missing: $sealNeedle"
}
$newIgnoreStart = $sealText.IndexOf('$newIgnoreBlock = (', [StringComparison]::Ordinal)
$newIgnoreEnd = $sealText.IndexOf('$oldLtoBlock = (', $newIgnoreStart,
  [StringComparison]::Ordinal)
if ($newIgnoreStart -lt 0 -or $newIgnoreEnd -le $newIgnoreStart) {
  throw 'Pioarduino seal does not expose one reviewable nonempty-lib-ignore transform.'
}
$newIgnoreText = $sealText.Substring($newIgnoreStart, $newIgnoreEnd - $newIgnoreStart)
Require-Order $newIgnoreText 'lib_ignore_entries = self._get_lib_ignore_entries()' `
  'if lib_ignore_entries:' `
  'Pioarduino seal does not normalize lib_ignore before deciding to back up.'
Require-Order $newIgnoreText 'if lib_ignore_entries:' 'self._backup_pioarduino_build_py()' `
  'Pioarduino seal can back up for an empty normalized lib_ignore configuration.'
Require-Order $newIgnoreText 'self._backup_pioarduino_build_py()' `
  'self.ignored_libs.update(lib_ignore_entries)' `
  'Pioarduino seal does not back up before its lib_ignore edit.'
Require-Count $newIgnoreText 'self._backup_pioarduino_build_py()' 1 `
  'Pioarduino nonempty-lib-ignore transform has ambiguous backup behavior.'

$newLtoStart = $sealText.IndexOf('$newLtoBlock = $oldLtoBlock.Replace(',
  [StringComparison]::Ordinal)
$newLtoEnd = $sealText.IndexOf('if ([regex]::Matches($originalText', $newLtoStart,
  [StringComparison]::Ordinal)
if ($newLtoStart -lt 0 -or $newLtoEnd -le $newLtoStart) {
  throw 'Pioarduino seal does not expose one reviewable LTO-preservation transform.'
}
$newLtoText = $sealText.Substring($newLtoStart, $newLtoEnd - $newLtoStart)
Require-Order $newLtoText 'return False' `
  'self.backup_manager.backup_pioarduino_build_py()' `
  'Pioarduino LTO transform backs up before proving its build script exists.'
$ltoBackupIndex = $newLtoText.IndexOf(
  'self.backup_manager.backup_pioarduino_build_py()', [StringComparison]::Ordinal)
$ltoReplacementTryIndex = $newLtoText.LastIndexOf('try:', [StringComparison]::Ordinal)
if ($ltoBackupIndex -lt 0 -or $ltoReplacementTryIndex -lt 0 -or
    $ltoBackupIndex -ge $ltoReplacementTryIndex) {
  throw 'Pioarduino LTO transform does not back up before its first edit.'
}
Require-Count $newLtoText 'self.backup_manager.backup_pioarduino_build_py()' 1 `
  'Pioarduino LTO transform has ambiguous backup behavior.'

Require-Order $sealText 'Refusing pre-existing seal transaction path' `
  '[void][IO.Directory]::CreateDirectory([string]$PlanSet.backupRoot)' `
  'Pioarduino seal can mutate before every target transaction path passes preflight.'
Require-Order $sealText 'Refusing stale $([string]$target.label) transaction artifact' `
  '[void][IO.Directory]::CreateDirectory([string]$PlanSet.backupRoot)' `
  'Pioarduino seal can mutate before stale prior-process transaction artifacts are rejected.'
Require-Order $sealText 'Private $([string]$target.label) backup is not the reviewed original file.' `
  '[void][IO.Directory]::CreateDirectory([string]$PlanSet.backupRoot)' `
  'Pioarduino seal can mutate before every existing backup passes preflight.'
Require-Order $sealText '$preparedPlans = ' '$installedPlans = ' `
  'Pioarduino seal can install before all candidate files are prepared and verified.'
Require-Order $sealText '$installedPlans = ' '$rollbackFailures = ' `
  'Pioarduino seal lacks rollback after an installation-stage failure.'

$powerShellPath = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $powerShellPath -PathType Leaf)) {
  throw "PowerShell executable for pioarduino seal self-test is missing: $powerShellPath"
}
$sealSelfTestOutput = @(& $powerShellPath -NoProfile -NonInteractive -ExecutionPolicy Bypass `
    -File $pioarduinoSealPath -SelfTest 2>&1 | ForEach-Object { [string]$_ })
$sealSelfTestExitCode = $LASTEXITCODE
if ($sealSelfTestExitCode -ne 0) {
  throw "Pioarduino seal behavioral self-test failed with exit $sealSelfTestExitCode`: $($sealSelfTestOutput -join ' | ')"
}
if ($sealSelfTestOutput.Count -ne 1) {
  throw "Pioarduino seal behavioral self-test produced $($sealSelfTestOutput.Count) output lines instead of one."
}
try {
  $sealSelfTest = $sealSelfTestOutput[0] | ConvertFrom-Json -ErrorAction Stop
} catch {
  throw "Pioarduino seal behavioral self-test output is not exact JSON: $($_.Exception.Message)"
}
$expectedSealScenarios = @(
  'preparationFailure', 'secondInstallRollback', 'successfulCommit',
  'alreadySealedIdempotence', 'mixedState', 'staleArtifactPreflight'
)
$actualSealScenarios = @($sealSelfTest.scenarios.PSObject.Properties.Name | Sort-Object)
if ([string]$sealSelfTest.schema -cne 'stackchan.pioarduino-seal-selftest.v1' -or
    [string]$sealSelfTest.status -cne 'pass' -or
    -not [bool]$sealSelfTest.usedSystemTemp -or
    -not [bool]$sealSelfTest.tempRootRemoved -or
    @(Compare-Object ($expectedSealScenarios | Sort-Object) $actualSealScenarios).Count -ne 0) {
  throw 'Pioarduino seal behavioral self-test result has the wrong authority shape.'
}
foreach ($scenario in $expectedSealScenarios) {
  if ([string]$sealSelfTest.scenarios.$scenario -cne 'pass') {
    throw "Pioarduino seal behavioral scenario did not pass: $scenario"
  }
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
