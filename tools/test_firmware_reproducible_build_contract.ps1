param(
  [string]$CompilerProbeCoreDir
)

$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
. (Join-Path $PSScriptRoot "platformio_resolver.ps1")
$hookRelative = "tools/platformio_reproducible_build.py"
$hookMarker = "pre:$hookRelative"
$hookPath = Join-Path $repoRoot $hookRelative
$platformioPath = Join-Path $repoRoot "platformio.ini"
$packagePath = Join-Path $repoRoot "tools/package_release.ps1"
$verifyPath = Join-Path $repoRoot "tools/verify_release_package.ps1"
$workflowPath = Join-Path $repoRoot ".github/workflows/firmware.yml"
$proofContractPath = Join-Path $repoRoot "tools/test_firmware_reproducibility_proof_contract.ps1"
$failureContractPath = Join-Path $repoRoot "tools/test_firmware_reproducibility_failure_contract.ps1"
$verifierTrustContractPath = Join-Path $repoRoot "tools/test_release_package_verifier_trust_contract.ps1"
$selectorPolicyContractPath = Join-Path $repoRoot "tools/test_release_ota_selector_policy_contract.ps1"
$flashSnapshotContractPath = Join-Path $repoRoot "tools/test_release_flash_snapshot_contract.ps1"
$sourceBindingContractPath = Join-Path $repoRoot "tools/test_release_source_binding_contract.ps1"
$dependencyEvidenceContractPath = Join-Path $repoRoot "tools/test_release_dependency_evidence_contract.ps1"
$toolchainIntegrationContractPath = Join-Path $repoRoot "tools/test_release_toolchain_integration_contract.ps1"
$toolchainDocumentationContractPath = Join-Path $repoRoot "tools/test_release_toolchain_documentation_contract.ps1"
$issues = New-Object 'System.Collections.Generic.List[string]'

function Require-ReproAssertion {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { $script:issues.Add($Message) }
}

function Get-StrictLiteralArray {
  param([System.Management.Automation.Language.Ast]$Ast)

  $node = $Ast
  if ($node -is [System.Management.Automation.Language.PipelineAst]) {
    if ($node.PipelineElements.Count -ne 1 -or
        $node.PipelineElements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst]) {
      return [pscustomobject]@{ valid = $false; values = @() }
    }
    $node = $node.PipelineElements[0].Expression
  }
  if ($node -is [System.Management.Automation.Language.CommandExpressionAst]) {
    $node = $node.Expression
  }
  if ($node -is [System.Management.Automation.Language.ArrayExpressionAst]) {
    $statements = @($node.SubExpression.Statements)
    if ($statements.Count -ne 1 -or
        $statements[0] -isnot [System.Management.Automation.Language.PipelineAst] -or
        $statements[0].PipelineElements.Count -ne 1 -or
        $statements[0].PipelineElements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst]) {
      return [pscustomobject]@{ valid = $false; values = @() }
    }
    $node = $statements[0].PipelineElements[0].Expression
  }

  $elements = if ($node -is [System.Management.Automation.Language.ArrayLiteralAst]) {
    @($node.Elements)
  } elseif ($node -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
    @($node)
  } else {
    @()
  }
  if ($elements.Count -eq 0 -or
      @($elements | Where-Object {
        $_ -isnot [System.Management.Automation.Language.StringConstantExpressionAst]
      }).Count -ne 0) {
    return [pscustomobject]@{ valid = $false; values = @() }
  }
  return [pscustomobject]@{
    valid = $true
    values = @($elements | ForEach-Object { [string]$_.Value })
  }
}

function Get-EnvironmentBlock {
  param([string]$Text, [string]$Name)
  $escaped = [regex]::Escape($Name)
  return [regex]::Match(
    $Text,
    "(?ms)^\[env:$escaped\]\s*(.*?)(?=^\[env:|\z)"
  ).Value
}

$expectedFirmwareEnvironments = @(
  "stackchan",
  "stackchan_servo_calibration",
  "stackchan_wifi",
  "stackchan_wifi_uplink",
  "stackchan_wake_sr_probe",
  "stackchan_wake_mww_probe",
  "stackchan_wake_mww_uplink",
  "stackchan_wake_mww_uplink_servos",
  "stackchan_wake_mww_uplink_servos_hi",
  "stackchan_wake_mww_uplink_servos_m5",
  "stackchan_wake_mww_uplink_servos_m5_voiceout",
  "stackchan_voice_v2",
  "stackchan_release_forensics",
  "stackchan_camera_probe",
  "stackchan_camera_probe_pmic_telemetry_only",
  "stackchan_camera_probe_pmic_policy_only",
  "stackchan_camera_probe_pmic_all_off",
  "stackchan_release_full",
  "stackchan_sd_provisioner",
  "stackchan_wake_sr_direct_probe",
  "stackchan_wake_sr_afe_lite",
  "stackchan_full_online"
)
$rootHookEnvironments = @(
  "stackchan",
  "stackchan_servo_calibration",
  "stackchan_wifi_uplink",
  "stackchan_wake_sr_probe",
  "stackchan_wake_mww_probe",
  "stackchan_wake_mww_uplink",
  "stackchan_sd_provisioner",
  "stackchan_wake_sr_direct_probe",
  "stackchan_wake_sr_afe_lite",
  "stackchan_full_online"
)

$platformioText = Get-Content -LiteralPath $platformioPath -Raw
$packageText = Get-Content -LiteralPath $packagePath -Raw
$packageTokens = $null
$packageParseErrors = $null
$packageAst = [System.Management.Automation.Language.Parser]::ParseFile(
  $packagePath, [ref]$packageTokens, [ref]$packageParseErrors)
$failureHelperText = Get-Content -LiteralPath (Join-Path $repoRoot 'tools/firmware_reproducibility_failure.ps1') -Raw
$packageGovernanceText = $packageText + "`n" + $failureHelperText
$verifyText = Get-Content -LiteralPath $verifyPath -Raw
$verifyTokens = $null
$verifyParseErrors = $null
$verifyAst = [System.Management.Automation.Language.Parser]::ParseFile(
  $verifyPath, [ref]$verifyTokens, [ref]$verifyParseErrors)
$proofHelperText = Get-Content -LiteralPath `
  (Join-Path $repoRoot 'tools/firmware_reproducibility_proof.ps1') -Raw
$verifyGovernanceText = $verifyText + "`n" + $proofHelperText
$workflowText = Get-Content -LiteralPath $workflowPath -Raw
$contractText = Get-Content -LiteralPath $PSCommandPath -Raw

$packageTopologyFunctions = @($packageAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Assert-StackchanReleaseCycleSourceTopology'
}, $true))
$verifierTopologyFunctions = @($verifyAst.FindAll({
  param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -ceq 'Assert-StackchanVerifierSourceTopology'
}, $true))
Require-ReproAssertion ($packageTopologyFunctions.Count -eq 1) `
  'package-source-topology-contract: expected one executable cycle-root guard'
Require-ReproAssertion ($verifierTopologyFunctions.Count -eq 1) `
  'verifier-source-topology-contract: expected one executable rebuild-root guard'
if ($packageTopologyFunctions.Count -eq 1 -and $verifierTopologyFunctions.Count -eq 1) {
  . ([scriptblock]::Create($packageTopologyFunctions[0].Extent.Text))
  . ([scriptblock]::Create($verifierTopologyFunctions[0].Extent.Text))

  $topologyParent = [System.IO.Path]::GetTempPath()
  $cycleARootFixture = Join-Path $topologyParent 'sc-fw-a-0000000001-deadbeef'
  $cycleBRootFixture = Join-Path $topologyParent 'sc-fw-b-0000000001-feedface'
  try {
    Assert-StackchanReleaseCycleSourceTopology `
      -CycleASourceRoot $cycleARootFixture -CycleBSourceRoot $cycleBRootFixture
  } catch {
    $issues.Add("package-source-topology-valid-case: $($_.Exception.Message)")
  }
  $mismatchedCycleBRoot = Join-Path (Join-Path $topologyParent 'x') `
    'sc-fw-b-0000000001-feedface'
  $cycleMismatchRejected = $false
  try {
    Assert-StackchanReleaseCycleSourceTopology `
      -CycleASourceRoot $cycleARootFixture -CycleBSourceRoot $mismatchedCycleBRoot
  } catch {
    $cycleMismatchRejected = $true
  }
  Require-ReproAssertion $cycleMismatchRejected `
    'package-source-topology-mutation: unequal total root lengths must fail'

  $verifierRootFixture = Join-Path $topologyParent 'sc-vrfy-0000000001-cafebabe'
  try {
    Assert-StackchanVerifierSourceTopology `
      -SourceRoot $verifierRootFixture -ExpectedLength $verifierRootFixture.Length
  } catch {
    $issues.Add("verifier-source-topology-valid-case: $($_.Exception.Message)")
  }
  foreach ($invalidLength in @(
      ([int]$verifierRootFixture.Length - 1),
      ([int]$verifierRootFixture.Length + 1))) {
    $verifierMismatchRejected = $false
    try {
      Assert-StackchanVerifierSourceTopology `
        -SourceRoot $verifierRootFixture -ExpectedLength $invalidLength
    } catch {
      $verifierMismatchRejected = $true
    }
    Require-ReproAssertion $verifierMismatchRejected `
      "verifier-source-topology-mutation: root length $invalidLength must fail"
  }
}

foreach ($workflowCompilerProbeMarker in @(
    '$pioarduinoCoreDir = Join-Path $env:RUNNER_TEMP "stackchan-pioarduino"',
    '-CompilerProbeCoreDir $pioarduinoCoreDir'
  )) {
  Require-ReproAssertion ($workflowText.Contains($workflowCompilerProbeMarker)) `
    "workflow-explicit-compiler-probe: missing $workflowCompilerProbeMarker"
}

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $proofContractPath
if ($LASTEXITCODE -ne 0) {
  $issues.Add("proof-mutation-contract-failed: exit $LASTEXITCODE")
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $failureContractPath
if ($LASTEXITCODE -ne 0) {
  $issues.Add("failed-build-retention-contract-failed: exit $LASTEXITCODE")
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $verifierTrustContractPath
if ($LASTEXITCODE -ne 0) {
  $issues.Add("verifier-trust-contract-failed: exit $LASTEXITCODE")
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $selectorPolicyContractPath
if ($LASTEXITCODE -ne 0) {
  $issues.Add("release-ota-selector-policy-contract-failed: exit $LASTEXITCODE")
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $flashSnapshotContractPath
if ($LASTEXITCODE -ne 0) {
  $issues.Add("release-flash-snapshot-contract-failed: exit $LASTEXITCODE")
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sourceBindingContractPath
if ($LASTEXITCODE -ne 0) {
  $issues.Add("release-source-binding-contract-failed: exit $LASTEXITCODE")
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dependencyEvidenceContractPath
if ($LASTEXITCODE -ne 0) {
  $issues.Add("release-dependency-evidence-contract-failed: exit $LASTEXITCODE")
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $toolchainIntegrationContractPath
if ($LASTEXITCODE -ne 0) {
  $issues.Add("release-toolchain-integration-contract-failed: exit $LASTEXITCODE")
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $toolchainDocumentationContractPath
if ($LASTEXITCODE -ne 0) {
  $issues.Add("release-toolchain-documentation-contract-failed: exit $LASTEXITCODE")
}

Require-ReproAssertion ($contractText.Contains('platformio_resolver.ps1') -and
    $contractText.Contains('Invoke-StackchanPlatformio project config --json-output') -and
    -not ($contractText -match '(?m)&\s+pio\s+project\s+config')) `
  "contract-resolver-missing: effective configuration must use the repository PlatformIO resolver"

Require-ReproAssertion (Test-Path -LiteralPath $hookPath -PathType Leaf) `
  "repro-script-missing: $hookRelative"
if (Test-Path -LiteralPath $hookPath -PathType Leaf) {
  $hookText = Get-Content -LiteralPath $hookPath -Raw
  foreach ($pathMarker in @('-ffile-prefix-map=', '_CANONICAL_DEBUG_ROOT', '_CANONICAL_CORE_ROOT', 'PROJECT_CORE_DIR')) {
    Require-ReproAssertion ($hookText.Contains($pathMarker)) `
      "repro-path-normalization-missing: $pathMarker"
  }
}

try {
  $config = ((Invoke-StackchanPlatformio project config --json-output | Out-String) | ConvertFrom-Json)
  $firmwareEnvironments = @()
  $nativeHookCount = -1
  $effectiveBuildCacheDir = ""
  foreach ($section in $config) {
    $name = [string]$section[0]
    if ($name -eq "platformio") {
      foreach ($item in $section[1]) {
        if ([string]$item[0] -eq "build_cache_dir") {
          $effectiveBuildCacheDir = [string]$item[1]
        }
      }
    }
    if (-not $name.StartsWith("env:")) { continue }
    $framework = @()
    $scripts = @()
    foreach ($item in $section[1]) {
      if ([string]$item[0] -eq "framework") { $framework = @($item[1]) }
      if ([string]$item[0] -eq "extra_scripts") { $scripts = @($item[1]) }
    }
    $environment = $name.Substring(4)
    $hookCount = @($scripts | Where-Object { [string]$_ -ceq $hookMarker }).Count
    if ($framework -contains "arduino") {
      $firmwareEnvironments += $environment
      Require-ReproAssertion ($hookCount -eq 1) `
        "effective-hook-count: $environment expected 1, found $hookCount"
    }
    if ($environment -eq "native_logic") { $nativeHookCount = $hookCount }
  }
  Require-ReproAssertion ($firmwareEnvironments.Count -eq 22) `
    "effective-environment-count: expected 22 Arduino firmware environments, found $($firmwareEnvironments.Count)"
  Require-ReproAssertion ((Compare-Object `
        ($expectedFirmwareEnvironments | Sort-Object) `
        ($firmwareEnvironments | Sort-Object)).Count -eq 0) `
    "effective-environment-set: Arduino firmware environment classification changed"
  Require-ReproAssertion ($nativeHookCount -eq 0) `
    "effective-hook-count: native_logic expected 0, found $nativeHookCount"
  Require-ReproAssertion ([string]::IsNullOrWhiteSpace($effectiveBuildCacheDir)) `
    "effective-build-cache: platformio.build_cache_dir must be empty outside the package's isolated per-cycle caches"
} catch {
  $issues.Add("effective-config-unavailable: $($_.Exception.Message)")
}

$rawHookCount = ([regex]::Matches($platformioText, "(?m)^\s+$([regex]::Escape($hookMarker))\s*$")).Count
Require-ReproAssertion ($rawHookCount -eq 10) `
  "raw-hook-count: expected 10 independent roots, found $rawHookCount"
Require-ReproAssertion (-not ($platformioText -match '(?mi)^\s*build_cache_dir\s*=')) `
  "raw-build-cache: platformio.ini must not configure a persistent firmware build cache"
foreach ($environment in $rootHookEnvironments) {
  $block = Get-EnvironmentBlock -Text $platformioText -Name $environment
  $extraScripts = [regex]::Match(
    $block,
    '(?ms)^extra_scripts\s*=\s*\r?\n(?<entries>(?:[ \t]+[^\r\n]+\r?\n?)*)')
  $entries = if ($extraScripts.Success) {
    @($extraScripts.Groups['entries'].Value -split '\r?\n' |
      ForEach-Object { $_.Trim() } | Where-Object { $_ })
  } else { @() }
  Require-ReproAssertion ($entries.Count -gt 0 -and $entries[0] -ceq $hookMarker) `
    "raw-hook-order: $environment must put $hookMarker first"
  Require-ReproAssertion (([regex]::Matches($block, [regex]::Escape($hookMarker))).Count -eq 1) `
    "raw-hook-count: $environment must contain the hook exactly once"
}
foreach ($environment in $expectedFirmwareEnvironments | Where-Object { $rootHookEnvironments -notcontains $_ }) {
  $block = Get-EnvironmentBlock -Text $platformioText -Name $environment
  Require-ReproAssertion (-not $block.Contains($hookMarker)) `
    "raw-hook-inheritance: $environment must inherit rather than redeclare the hook"
}

$overrideNames = @(
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
$pathWorkIndex = $packageText.IndexOf('$physicalRepoRoot =')
foreach ($overrideName in $overrideNames) {
  $nameIndex = $packageText.IndexOf('"' + $overrideName + '"')
  Require-ReproAssertion ($nameIndex -ge 0 -and $pathWorkIndex -ge 0 -and $nameIndex -lt $pathWorkIndex) `
    "release-override-preflight-missing: $overrideName must be rejected before path/cache/build/package work"
}
Require-ReproAssertion ($packageText.Contains('Test-Path ("Env:\" + $releaseOverrideName)')) `
  "release-override-preflight-missing: package guard must reject variable presence"
Require-ReproAssertion ($packageText.Contains('$_.Name -like "PLATFORMIO_*"') -and
    $packageText.Contains('$_.Name -like "GIT_*"')) `
  "release-override-preflight-missing: package must reject all ambient PlatformIO and Git overrides"
$packageContractIndex = $packageText.IndexOf(
  '(Join-Path $PSScriptRoot "test_firmware_reproducible_build_contract.ps1")')
$packageResolverIndex = $packageText.IndexOf(
  '. (Join-Path $PSScriptRoot "platformio_resolver.ps1")')
Require-ReproAssertion ($packageContractIndex -ge 0 -and $packageResolverIndex -ge 0 -and
    $packageContractIndex -lt $packageResolverIndex) `
  "package-contract-order: reproducibility contract must run before resolver/cache/build work"
foreach ($marker in @(
  '-SkipBuild is diagnostic-only and requires -AllowDirty',
  '-AllowDirty supports diagnostic -SkipBuild packages only',
  'verified-two-clean-cycles',
  'minimumClockBoundarySeconds = 65',
  "-CycleName 'cycle-a'",
  "-CycleName 'cycle-b'",
  'isolated-empty-per-cycle-environment',
  'distinct-equal-length-short-detached-clean-worktrees-pinned-to-source-commit-with-prefix-mapped-paths',
  'fixed-width-process-id-and-equal-length-distinct-labels',
  "New-ShortReleaseScratchPath -Label 'fw-a'",
  "New-ShortReleaseScratchPath -Label 'fw-b'",
  "'D10'",
  'distinct equal-length fixed-width source roots',
  'STACKCHAN_EXPECTED_BUILD_COMMIT',
  'STACKCHAN_EXPECTED_BUILD_EPOCH',
  'output/private/reproducibility-failures',
  'stackchan.firmware-reproducibility-failure.v2',
  'failed-full-worktree-preserved',
  'full-failed-worktree-retained-attached'
)) {
  Require-ReproAssertion ($packageGovernanceText.Contains($marker)) `
    "package-artifact-proof-missing: $marker"
}
Require-ReproAssertion (-not $packageText.Contains('STACKCHAN_RELEASE_SHORT_PATH_ACTIVE')) `
  "package-short-path-bypass: ambient short-path sentinel must not bypass canonical path handling"
Require-ReproAssertion (-not $packageText.Contains('.firmware-build-cache-*')) `
  "package-failure-evidence: package startup must not wildcard-delete prior failed build caches"
foreach ($operationalTool in @(
  "tools/flash_release_firmware.ps1",
  "tools/prepare_device_arrival.ps1",
  "tools/start_hardware_evidence.ps1",
  "tools/publish_release.ps1"
)) {
  $operationalText = Get-Content -LiteralPath (Join-Path $repoRoot $operationalTool) -Raw
  Require-ReproAssertion ($operationalText.Contains("RequireReleaseEligible")) `
    "diagnostic-operational-containment: $operationalTool must require release eligibility"
}

$m0GovernanceTools = @(
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
  "tools/platformio_resolver.ps1",
  $hookRelative,
  "tools/test_firmware_reproducible_build_contract.ps1"
)
foreach ($path in $m0GovernanceTools) {
  Require-ReproAssertion ($verifyText.Contains('"' + $path + '"')) `
    "package-verifier-missing: $path"
}
Require-ReproAssertion ($packageParseErrors.Count -eq 0) `
  "package-governance-wiring-parse: package script must parse before M0 membership can be audited"
if ($packageParseErrors.Count -eq 0) {
  $releaseToolsAssignments = @($packageAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
      $node.Left.Extent.Text -eq '$releaseTools'
  }, $true))
  $manifestAssignments = @($packageAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
      $node.Left.Extent.Text -eq '$manifest'
  }, $true))
  Require-ReproAssertion ($releaseToolsAssignments.Count -eq 1) `
    "package-release-tools-wiring: releaseTools assignment must be unique"
  Require-ReproAssertion ($manifestAssignments.Count -eq 1) `
    "package-manifest-wiring: release manifest assignment must be unique"
  if ($releaseToolsAssignments.Count -eq 1 -and $manifestAssignments.Count -eq 1) {
    $releaseToolsLiteralArray = Get-StrictLiteralArray -Ast $releaseToolsAssignments[0].Right
    Require-ReproAssertion ([bool]$releaseToolsLiteralArray.valid) `
      "package-release-tools-literals: releaseTools must be one runtime array made only of direct string literals"
    $releaseToolValues = @($releaseToolsLiteralArray.values)
    foreach ($path in $m0GovernanceTools) {
      Require-ReproAssertion (
        @($releaseToolValues | Where-Object { $_ -ceq $path }).Count -eq 1) `
        "package-release-tools-membership: $path must appear exactly once"
    }
    $inventoryPairs = @($manifestAssignments[0].FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.HashtableAst]
    }, $true) | ForEach-Object { $_.KeyValuePairs })
    foreach ($inventorySpec in @(
      [pscustomobject]@{ manifestKey = 'includedTools'; variable = 'includedToolsInventory' },
      [pscustomobject]@{ manifestKey = 'provenanceFiles'; variable = 'provenanceFileInventory' }
    )) {
      $pairs = @($inventoryPairs | Where-Object {
        $_.Item1.Extent.Text -ceq [string]$inventorySpec.manifestKey
      })
      Require-ReproAssertion ($pairs.Count -eq 1 -and
          $pairs[0].Item2.Extent.Text -ceq "@(`$$([string]$inventorySpec.variable))") `
        "package-manifest-canonical-inventory-wiring: $($inventorySpec.manifestKey) must use its runtime canonical inventory"
    }
  }

  foreach ($inventorySpec in @(
    [pscustomobject]@{
      variable = 'includedToolsInventory'
      directory = 'toolsDir'
      prefix = 'tools'
    },
    [pscustomobject]@{
      variable = 'provenanceFileInventory'
      directory = 'provenanceDir'
      prefix = 'provenance'
    }
  )) {
    $assignments = @($packageAst.FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -ceq "`$$([string]$inventorySpec.variable)"
    }, $true))
    $expectedExpression = "@(Get-CanonicalPackageFileInventory -Directory `$$([string]$inventorySpec.directory) -PackagePrefix `"$([string]$inventorySpec.prefix)`")"
    Require-ReproAssertion ($assignments.Count -eq 1 -and
        $assignments[0].Right.Extent.Text -ceq $expectedExpression) `
      "package-canonical-inventory-source: $($inventorySpec.variable) must enumerate the packaged directory exactly once"
  }
  foreach ($canonicalMarker in @(
    'Get-ChildItem -LiteralPath $resolvedDirectory -File -Recurse -Force',
    'ConvertTo-CanonicalPackageInventory -PackagePaths $packagePaths',
    '[System.StringComparer]::OrdinalIgnoreCase',
    '[Array]::Sort($result, [System.StringComparer]::Ordinal)',
    "`$segments[0] -cne `$RequiredPrefix",
    "`$segments | Where-Object { [string]::IsNullOrWhiteSpace(`$_) -or `$_ -in @('.', '..') }"
  )) {
    Require-ReproAssertion ($packageText.Contains($canonicalMarker)) `
      "package-canonical-inventory-policy-missing: $canonicalMarker"
  }
}
Require-ReproAssertion ($verifyParseErrors.Count -eq 0) `
  "package-verifier-wiring-parse: verifier must parse before M0 wiring can be audited"
if ($verifyParseErrors.Count -eq 0) {
  $requiredFilesWiring = @($verifyAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
      $node.Left.Extent.Text -eq '$requiredFiles' -and
      $node.Operator -eq [System.Management.Automation.Language.TokenKind]::PlusEquals -and
      $node.Right.Extent.Text -eq '$m0GovernanceTools'
  }, $true))
  Require-ReproAssertion ($requiredFilesWiring.Count -eq 1) `
    "package-verifier-required-files-wiring: M0 tools must extend requiredFiles exactly once"

  $includedToolsSources = @($verifyAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
      $node.Left.Extent.Text -eq '$includedTools' -and
      $node.Operator -eq [System.Management.Automation.Language.TokenKind]::Equals -and
      $node.Right.Extent.Text -eq '@($manifest.includedTools)'
  }, $true))
  Require-ReproAssertion ($includedToolsSources.Count -eq 1) `
    "package-verifier-included-tools-source: verifier must use manifest includedTools"

  $exactInventoryFunctions = @($verifyAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
      $node.Name -ceq 'Assert-ExactOperationalInventory'
  }, $true))
  Require-ReproAssertion ($exactInventoryFunctions.Count -eq 1) `
    "package-verifier-exact-inventory-function: verifier must define one exact inventory gate"
  if ($exactInventoryFunctions.Count -eq 1) {
    $exactInventoryText = $exactInventoryFunctions[0].Extent.Text
    foreach ($marker in @(
      '[StringComparer]::Ordinal', '[StringComparer]::OrdinalIgnoreCase',
      'unsafe, duplicate, or case-colliding', 'inventory is not ordinally sorted',
      'inventory count does not match packaged files', 'contains an undeclared',
      'declares a missing'
    )) {
      Require-ReproAssertion ($exactInventoryText.Contains($marker)) `
        "package-verifier-exact-inventory-policy: $marker"
    }
  }
  foreach ($exactCall in @(
    "-ManifestEntries @(`$Manifest.includedTools) -PackagePrefix 'tools'",
    "-ManifestEntries @(`$Manifest.provenanceFiles) -PackagePrefix 'provenance'"
  )) {
    Require-ReproAssertion ($verifyText.Contains($exactCall)) `
      "package-verifier-exact-inventory-call: $exactCall"
  }
  foreach ($bindingMarker in @(
    'Get-OperationalTrustedCommitMaps',
    'Get-TrustedReleaseToolPolicy',
    'Get-TrustedProvenancePolicy',
    'Assert-OperationalSourceCheckoutBindings',
    'foreach ($includedTool in $trustedToolPolicy)',
    '-TrustedSourceRelativePath $includedTool -CommitMaps $commitMaps',
    'foreach ($provenanceFile in $trustedProvenancePolicy)',
    '-TrustedSourceRelativePath ([string]$provenancePolicy[$provenanceFile])'
  )) {
    Require-ReproAssertion ($verifyText.Contains($bindingMarker)) `
      "package-verifier-exact-inventory-binding: $bindingMarker"
  }

  $includedToolsLoops = @($verifyAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
      $node.Variable.VariablePath.UserPath -eq 'governanceTool' -and
      $node.Condition.Extent.Text -eq '$m0GovernanceTools'
  }, $true))
  Require-ReproAssertion ($includedToolsLoops.Count -eq 1) `
    "package-verifier-included-tools-loop: verifier must enforce every M0 declaration"
  if ($includedToolsLoops.Count -eq 1) {
    $missingM0Expressions = @($includedToolsLoops[0].FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.BinaryExpressionAst] -and
        $node.Operator -eq [System.Management.Automation.Language.TokenKind]::Inotcontains -and
        $node.Left.Extent.Text -eq '$includedTools' -and
        $node.Right.Extent.Text -eq '$governanceTool'
    }, $true))
    $missingM0Throws = @($includedToolsLoops[0].FindAll({
      param($node)
      $node -is [System.Management.Automation.Language.ThrowStatementAst] -and
        $node.Extent.Text.Contains('Manifest includedTools is missing M0 governance input')
    }, $true))
    Require-ReproAssertion (
      $missingM0Expressions.Count -eq 1 -and $missingM0Throws.Count -eq 1) `
      "package-verifier-included-tools-rejection: missing M0 declarations must fail closed"
  }
}
foreach ($marker in @(
  "firmwareReproducibility",
  "git-commit-epoch-builtins-v1",
  "release-overrides-fail-closed",
  "exactly-one-effective-hook"
)) {
  Require-ReproAssertion ($packageText.Contains($marker)) "package-provenance-missing: $marker"
  Require-ReproAssertion ($verifyGovernanceText.Contains($marker)) "package-verifier-missing: $marker"
}
foreach ($marker in @(
  "verified-two-clean-cycles",
  "not-proven-skip-build",
  "Firmware reproducibility proof must contain 15 artifacts per cycle",
  "Packaged artifact does not match reproducibility cycle B",
  "Firmware reproducibility proof clock boundary is inconsistent",
  "expectedProofKeys",
  "unexpected or duplicate artifact",
  "cycleASourceCommit",
  "identityAttestations",
  "distinct-equal-length-short-detached-clean-worktrees-pinned-to-source-commit-with-prefix-mapped-paths",
  "fixed-width-process-id-and-equal-length-distinct-labels",
  "sourceRootLength",
  "DIAGNOSTIC_PACKAGE_DO_NOT_FLASH.txt",
  "Diagnostic archive integrity verified; release and hardware use forbidden:",
  "RequireReleaseEligible"
)) {
  Require-ReproAssertion ($verifyGovernanceText.Contains($marker)) "package-verifier-missing: $marker"
}
foreach ($marker in @(
  "'sc-vrfy-'",
  "'^sc-vrfy-[0-9]{10}-[0-9a-f]{8}$'",
  "fixed-width equal-length source topology"
)) {
  Require-ReproAssertion ($verifyText.Contains($marker)) "package-verifier-topology-missing: $marker"
}

$workflowStep = "Run firmware reproducibility contract"
Require-ReproAssertion ($workflowText.Contains($workflowStep) -and
    $workflowText.Contains("./tools/test_firmware_reproducible_build_contract.ps1") -and
    $workflowText.Contains("pio run -e stackchan_release_full")) `
  "ci-gate-missing: $workflowStep"

if (Test-Path -LiteralPath $hookPath -PathType Leaf) {
  $pythonHarness = @'
import contextlib
import io
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile

HOOK = Path(sys.argv[1]).resolve()
MANAGED = {
    "STACKCHAN_BUILD_EPOCH",
    "SOURCE_DATE_EPOCH",
    "STACKCHAN_BUILD_STAMP",
    "STACKCHAN_DISABLE_REPRODUCIBLE_BUILD",
    "STACKCHAN_EXPECTED_BUILD_COMMIT",
    "STACKCHAN_EXPECTED_BUILD_EPOCH",
    "TZ",
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_COMMON_DIR",
    "GIT_CEILING_DIRECTORIES",
}

class FakeEnv(dict):
    def AppendUnique(self, **values):
        for key, incoming in values.items():
            current = list(self.get(key, []))
            for value in incoming:
                if value not in current:
                    current.append(value)
            self[key] = current

def invoke(project, supplied=None):
    previous = {key: os.environ.get(key) for key in MANAGED}
    try:
        for key in MANAGED:
            os.environ.pop(key, None)
        for key, value in (supplied or {}).items():
            os.environ[key] = value
        fake = FakeEnv(
            PROJECT_DIR=str(project),
            PROJECT_CORE_DIR=str(root / "pio-core"),
            ENV={},
        )
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            runpy.run_path(
                str(HOOK),
                init_globals={"Import": lambda *_: None, "env": fake},
            )
        return list(fake.get("CCFLAGS", [])), dict(fake["ENV"]), output.getvalue()
    finally:
        for key in MANAGED:
            os.environ.pop(key, None)
        for key, value in previous.items():
            if value is not None:
                os.environ[key] = value

def expect_failure(project, supplied, marker):
    try:
        invoke(project, supplied)
    except Exception as exc:
        if marker not in str(exc):
            raise AssertionError(f"expected {marker!r} in {exc!r}") from exc
        return
    raise AssertionError(f"expected failure containing {marker!r}")

def non_path_flags(flags):
    return [flag for flag in flags if not flag.startswith("-ffile-prefix-map=")]

def prefix_flags(path, canonical):
    lexical = Path(os.path.abspath(str(path)))
    candidates = []
    for candidate in (lexical.as_posix(), lexical.resolve().as_posix()):
        candidate = candidate.rstrip("/")
        if candidate not in candidates:
            candidates.append(candidate)
    return [f"-ffile-prefix-map={candidate}={canonical}" for candidate in candidates]

def expected_path_flags(project):
    return (
        prefix_flags(project, "/stackchan/source")
        + prefix_flags(root / "pio-core", "/stackchan/platformio-core")
    )

root = Path(tempfile.mkdtemp(prefix="stackchan-repro-contract-"))
try:
    repo = root / "repo"
    repo.mkdir()
    subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.name", "Stackchan Contract"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.email", "contract@example.invalid"], cwd=repo, check=True)
    (repo / "tracked.txt").write_text("stable\n", encoding="utf-8")
    subprocess.run(["git", "add", "tracked.txt"], cwd=repo, check=True)
    commit_env = dict(os.environ)
    commit_env["GIT_AUTHOR_DATE"] = "1700000000 +0000"
    commit_env["GIT_COMMITTER_DATE"] = "1700000000 +0000"
    subprocess.run(["git", "commit", "-q", "-m", "fixture"], cwd=repo, env=commit_env, check=True)
    fixture_commit = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=repo, check=True, capture_output=True, text=True
    ).stdout.strip()

    flags_a, child_a, log_a = invoke(repo, {"TZ": "Pacific/Honolulu"})
    flags_b, child_b, log_b = invoke(repo, {"TZ": "Asia/Tokyo"})
    assert flags_a == flags_b
    assert child_a["SOURCE_DATE_EPOCH"] == "1700000000"
    assert child_b["SOURCE_DATE_EPOCH"] == "1700000000"
    assert flags_a.count("-Wno-builtin-macro-redefined") == 1
    assert flags_a.count('-D__DATE__=\\"Nov 14 2023\\"') == 1
    assert flags_a.count('-D__TIME__=\\"22:13:20\\"') == 1
    assert [flag for flag in flags_a if flag.startswith("-ffile-prefix-map=")] == expected_path_flags(repo)
    assert "1700000000" in log_a and "1700000000" in log_b

    locked_flags, locked_child, _ = invoke(
        repo,
        {
            "STACKCHAN_EXPECTED_BUILD_COMMIT": fixture_commit,
            "STACKCHAN_EXPECTED_BUILD_EPOCH": "1700000000",
        },
    )
    assert locked_flags == flags_a
    assert locked_child["SOURCE_DATE_EPOCH"] == "1700000000"
    expect_failure(
        repo,
        {
            "STACKCHAN_EXPECTED_BUILD_COMMIT": "0" * 40,
            "STACKCHAN_EXPECTED_BUILD_EPOCH": "1700000000",
        },
        "identity lock",
    )
    expect_failure(
        repo,
        {
            "STACKCHAN_EXPECTED_BUILD_COMMIT": fixture_commit,
            "STACKCHAN_EXPECTED_BUILD_EPOCH": "1700000001",
        },
        "epoch",
    )
    expect_failure(
        repo,
        {"STACKCHAN_EXPECTED_BUILD_COMMIT": fixture_commit},
        "supplied together",
    )

    no_git = root / "no-git"
    no_git.mkdir()
    expect_failure(no_git, None, "Git")

    override_flags, override_child, _ = invoke(
        no_git, {"STACKCHAN_BUILD_EPOCH": "1700000000"}
    )
    assert non_path_flags(override_flags) == non_path_flags(flags_a)
    assert [flag for flag in override_flags if flag.startswith("-ffile-prefix-map=")] == expected_path_flags(no_git)
    assert override_child["SOURCE_DATE_EPOCH"] == "1700000000"

    nested = repo / "nested"
    nested.mkdir()
    expect_failure(nested, None, "project directory")

    invalid_epochs = [
        "", " 1700000000", "1700000000 ", "+1700000000", "1.0",
        "999999999999999999999999", "1\n2", '1" -D BAD=1', "$(whoami)",
    ]
    for value in invalid_epochs:
        expect_failure(no_git, {"STACKCHAN_BUILD_EPOCH": value}, "STACKCHAN_BUILD_EPOCH")

    for legacy in ("STACKCHAN_BUILD_STAMP", "STACKCHAN_DISABLE_REPRODUCIBLE_BUILD"):
        expect_failure(repo, {legacy: ""}, legacy)
        expect_failure(repo, {legacy: "1"}, legacy)
    expect_failure(repo, {"SOURCE_DATE_EPOCH": "1700000000"}, "SOURCE_DATE_EPOCH")

    alternate = root / "alternate"
    alternate.mkdir()
    subprocess.run(["git", "init", "-q"], cwd=alternate, check=True)
    subprocess.run(["git", "config", "user.name", "Stackchan Contract"], cwd=alternate, check=True)
    subprocess.run(["git", "config", "user.email", "contract@example.invalid"], cwd=alternate, check=True)
    (alternate / "other.txt").write_text("other\n", encoding="utf-8")
    subprocess.run(["git", "add", "other.txt"], cwd=alternate, check=True)
    subprocess.run(["git", "commit", "-q", "-m", "alternate"], cwd=alternate, env=commit_env, check=True)
    expect_failure(
        repo,
        {"GIT_DIR": str(alternate / ".git"), "GIT_WORK_TREE": str(alternate)},
        "GIT_DIR",
    )

    (repo / "tracked.txt").write_text("dirty\n", encoding="utf-8")
    expect_failure(repo, None, "clean")
    dirty_override_flags, _, _ = invoke(
        repo, {"STACKCHAN_BUILD_EPOCH": "1700000000"}
    )
    assert dirty_override_flags == flags_a
    subprocess.run(["git", "checkout", "--", "tracked.txt"], cwd=repo, check=True)
    (repo / "untracked.txt").write_text("untracked\n", encoding="utf-8")
    expect_failure(repo, None, "clean")
    (repo / "untracked.txt").unlink()

    worktree_a = root / "a"
    worktree_b = root / "different-length-b"
    subprocess.run(["git", "worktree", "add", "--detach", str(worktree_a), fixture_commit], cwd=repo, check=True, capture_output=True)
    subprocess.run(["git", "worktree", "add", "--detach", str(worktree_b), fixture_commit], cwd=repo, check=True, capture_output=True)
    worktree_flags_a, _, _ = invoke(worktree_a)
    worktree_flags_b, _, _ = invoke(worktree_b)
    assert non_path_flags(worktree_flags_a) == non_path_flags(worktree_flags_b)
    assert expected_path_flags(worktree_a) != expected_path_flags(worktree_b)
    assert [flag for flag in worktree_flags_a if flag.startswith("-ffile-prefix-map=")] == expected_path_flags(worktree_a)
    assert [flag for flag in worktree_flags_b if flag.startswith("-ffile-prefix-map=")] == expected_path_flags(worktree_b)
finally:
    shutil.rmtree(root, ignore_errors=True)
'@
  $encodedHarness = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pythonHarness))
  $pythonResult = & python -c "import base64;exec(base64.b64decode('$encodedHarness'))" $hookPath 2>&1
  Require-ReproAssertion ($LASTEXITCODE -eq 0) `
    "hook-behavior-failed: $($pythonResult | Out-String)"
}

function Test-PrefixMapCompiler {
  param([Parameter(Mandatory = $true)][string]$Compiler)

  $probeRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "stackchan-prefix-map-contract-" + [guid]::NewGuid().ToString("N"))
  $rootA = Join-Path $probeRoot "a"
  $rootB = Join-Path $probeRoot "different-length-b"
  try {
    New-Item -ItemType Directory -Force -Path $rootA, $rootB | Out-Null
    foreach ($rootPath in @($rootA, $rootB)) {
      [System.IO.File]::WriteAllText(
        (Join-Path $rootPath "probe.cpp"),
        "const char* source_path = __FILE__; int main(){return source_path[0] == 0;}`n",
        (New-Object System.Text.UTF8Encoding($false)))
      Push-Location $rootPath
      try {
        & $Compiler -x c++ -g -S probe.cpp -o raw.s
        if ($LASTEXITCODE -ne 0) { throw "raw compiler probe failed" }
        $forwardRoot = ([System.IO.Path]::GetFullPath($rootPath)).Replace('\', '/').TrimEnd('/')
        & $Compiler -x c++ -g -S "-ffile-prefix-map=$forwardRoot=/stackchan/source" probe.cpp -o mapped.s
        if ($LASTEXITCODE -ne 0) { throw "mapped compiler probe failed" }
      } finally {
        Pop-Location
      }
    }
    $rawA = (Get-FileHash -LiteralPath (Join-Path $rootA 'raw.s') -Algorithm SHA256).Hash
    $rawB = (Get-FileHash -LiteralPath (Join-Path $rootB 'raw.s') -Algorithm SHA256).Hash
    $mappedAPath = Join-Path $rootA 'mapped.s'
    $mappedBPath = Join-Path $rootB 'mapped.s'
    $mappedA = (Get-FileHash -LiteralPath $mappedAPath -Algorithm SHA256).Hash
    $mappedB = (Get-FileHash -LiteralPath $mappedBPath -Algorithm SHA256).Hash
    Require-ReproAssertion ($rawA -cne $rawB) `
      "compiler-prefix-map-probe: raw outputs unexpectedly matched for $Compiler"
    Require-ReproAssertion ($mappedA -ceq $mappedB) `
      "compiler-prefix-map-probe: mapped outputs differ for $Compiler"
    $mappedText = (Get-Content -LiteralPath $mappedAPath -Raw) + (Get-Content -LiteralPath $mappedBPath -Raw)
    Require-ReproAssertion (-not $mappedText.Contains($rootA.Replace('\', '/')) -and
        -not $mappedText.Contains($rootB.Replace('\', '/'))) `
      "compiler-prefix-map-probe: mapped output retains a checkout root for $Compiler"
  } catch {
    $issues.Add("compiler-prefix-map-probe: $Compiler $($_.Exception.Message)")
  } finally {
    if (Test-Path -LiteralPath $probeRoot) {
      [System.IO.Directory]::Delete($probeRoot, $true)
    }
  }
}

$explicitCompilerProbeCore = -not [string]::IsNullOrWhiteSpace($CompilerProbeCoreDir)
$resolvedCompilerProbeCoreDir = if (-not $explicitCompilerProbeCore) {
  Get-StackchanPlatformioCoreDir
} else {
  $resolvedProbeRoot = Resolve-Path -LiteralPath $CompilerProbeCoreDir -ErrorAction Stop
  if (-not (Test-Path -LiteralPath $resolvedProbeRoot.Path -PathType Container)) {
    throw "Compiler probe PlatformIO core is not a directory: $CompilerProbeCoreDir"
  }
  $resolvedProbeRoot.Path
}

$compilerCandidates = @(
  (Join-Path $resolvedCompilerProbeCoreDir 'packages/toolchain-xtensa-esp32s3/bin/xtensa-esp32s3-elf-g++.exe'),
  (Join-Path $resolvedCompilerProbeCoreDir 'packages/toolchain-xtensa-esp-elf/bin/xtensa-esp32s3-elf-g++.exe')
)
if ($explicitCompilerProbeCore -and
    @($compilerCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count -eq 0) {
  throw "No supported compiler found under explicit probe core: $resolvedCompilerProbeCoreDir"
}
if (-not $explicitCompilerProbeCore -and $env:OS -eq 'Windows_NT') {
  $compilerCandidates += Join-Path ([System.IO.Path]::GetPathRoot($env:SystemRoot)) `
    'spio/pioarduino/packages/toolchain-xtensa-esp-elf/bin/xtensa-esp32s3-elf-g++.exe'
}
foreach ($compiler in @($compilerCandidates | Sort-Object -Unique)) {
  if (Test-Path -LiteralPath $compiler -PathType Leaf) {
    Test-PrefixMapCompiler -Compiler $compiler
  }
}

if ($issues.Count -gt 0) {
  throw ("Firmware reproducible-build contract failed:`n- " + ($issues -join "`n- "))
}

Write-Host "Firmware reproducible-build contract verified for all 22 firmware environments."
