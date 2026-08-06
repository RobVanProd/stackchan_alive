$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$authorityNames = @(
  'ToolchainAllowlistPath', 'GitExecutable', 'PythonExecutable',
  'PlatformioExecutable', 'LegacyCoreDir', 'ReleaseCoreDir')
$authorizingTools = @(
  'package_release', 'verify_release_package', 'run_device_preflight',
  'flash_release_firmware', 'start_hardware_evidence', 'prepare_device_arrival',
  'start_bridge_ai_supervised_qualification', 'verify_consumer_promotion',
  'publish_release', 'audit_published_release', 'verify_published_release',
  'share_release', 'export_rollout_status')
$operatorDocs = @(
  'README.md', 'docs/RELEASE_PROCESS.md', 'docs/RELEASE_QUICKSTART.md',
  'docs/ARRIVAL_DAY_RUNBOOK.md', 'docs/DEVICE_BRINGUP.md',
  'docs/ROLLOUT_CHECKLIST.md', 'docs/BRIDGE_AI_QUALIFICATION.md',
  'docs/COMPANION_APP_GAP_ANALYSIS.md')

function Require-Text {
  param([string]$Text, [string]$Needle, [string]$Message)
  if (-not $Text.Contains($Needle)) { throw $Message }
}

$toolAlternation = ($authorizingTools | ForEach-Object { [regex]::Escape($_) }) -join '|'
$toolInvocationPattern = '(?im)(?:^|[\\/])(?:' + $toolAlternation + ')\.(?:cmd|ps1)'
$cmdInvocationPattern = '(?im)(?:^|[\\/])(?:' + $toolAlternation + ')\.cmd'
foreach ($relative in $operatorDocs) {
  $text = Get-Content -LiteralPath (Join-Path $repoRoot $relative) -Raw
  if ($text -notmatch '(?i)archive\s+does\s+not\s+confer\s+release\s+authority') {
    throw "Operator document does not state the archive authority boundary: $relative"
  }
  if ($text -match ('(?is)(from inside|inside).{0,80}extracted.{0,240}(?:' +
      $toolAlternation + ')\.(?:cmd|ps1)')) {
    throw "Operator document tells users to authorize from an extracted archive: $relative"
  }

  foreach ($match in [regex]::Matches($text, '(?ms)```powershell\s*(.*?)\s*```')) {
    $block = [string]$match.Groups[1].Value
    if ($block -notmatch $toolInvocationPattern) { continue }
    $isNoPackagePreflightSelfTest = $block.Trim() -ceq '.\tools\run_device_preflight.cmd'
    if ($block -match $cmdInvocationPattern -and -not $isNoPackagePreflightSelfTest) {
      throw "Authorizing documentation uses a transparent CMD wrapper instead of the auditable PowerShell splat: $relative"
    }
    $hasSplat = $block.Contains('@releaseToolchain')
    $hasAllLiteralAuthority = @($authorityNames | Where-Object { -not $block.Contains('-' + $_) }).Count -eq 0
    if (-not $isNoPackagePreflightSelfTest -and
        -not $hasSplat -and -not $hasAllLiteralAuthority) {
      throw "Authorizing PowerShell block omits exact-host authority: $relative"
    }
  }
}

$packageText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'package_release.ps1') -Raw
$sourceBindingText = Get-Content -LiteralPath (
  Join-Path $PSScriptRoot 'release_source_binding.ps1') -Raw
Require-Text $sourceBindingText `
  'Return to the exact clean trusted source checkout, define the six-value releaseToolchain splat from docs/RELEASE_PROCESS.md, and pass this ZIP to tools/prepare_device_arrival.ps1. The archive does not confer release authority.' `
  'Trusted source-binding helper is missing the canonical arrival-authority guidance.'
foreach ($needle in @(
    'nextOperatorCommand = $null', 'nextOperatorGuidance',
    '$arrivalAuthorityGuidance = Get-StackchanArrivalAuthorityGuidance',
    '$arrivalAuthorityGuidance',
    'completed governed release package')) {
  Require-Text $packageText $needle "Package handoff is missing non-authorizing guidance: $needle"
}
if ($packageText.Contains('.\tools\prepare_device_arrival.cmd -Port COM3')) {
  throw 'Package readiness output still emits an extracted-package arrival command.'
}

$shareText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'share_release.ps1') -Raw
foreach ($needle in @(
    'nextCommand = $null', 'No command is emitted by the shared archive',
    'shared archive does not confer release authority',
    'source-side <code>tools/prepare_device_arrival.ps1</code>')) {
  Require-Text $shareText $needle "Share handoff is missing the trusted-source boundary: $needle"
}
if ($shareText.Contains('run this from inside the extracted folder') -or
    $shareText.Contains('.\tools\prepare_device_arrival.cmd -Port COM3')) {
  throw 'Share page still emits an extracted-package arrival command.'
}

$rolloutText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'export_rollout_status.ps1') -Raw
foreach ($needle in @(
    'New-RolloutTrustedSourceCommand', 'package_release.ps1',
    'start_hardware_evidence.ps1', 'verify_consumer_promotion.ps1')) {
  Require-Text $rolloutText $needle "Rollout report lacks a trusted-source command path: $needle"
}

$hardwareEvidenceText = Get-Content -LiteralPath (
  Join-Path $PSScriptRoot 'start_hardware_evidence.ps1') -Raw
foreach ($checklistAuthorityItem in @(
    '`tools/verify_release_package.ps1 -RequireReleaseEligible ... @releaseToolchain` passes for the release ZIP.',
    '`tools/flash_release_firmware.ps1 -PackageZip <zip> -Firmware display_only -DryRun -Monitor @releaseToolchain` passes for the release ZIP.',
    'Hardware evidence packet created with `tools/start_hardware_evidence.ps1 ... @releaseToolchain`.')) {
  Require-Text $hardwareEvidenceText $checklistAuthorityItem `
    "Hardware evidence checklist marking is stale: $checklistAuthorityItem"
}
$preflightText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'run_device_preflight.ps1') -Raw
Require-Text $preflightText `
  '- [x] `tools/verify_release_package.ps1 -RequireReleaseEligible ... @releaseToolchain` passes for the release ZIP.' `
  'Preflight scaffold assertion does not match the authority-bound rollout checklist.'
foreach ($authorityName in $authorityNames) {
  Require-Text $rolloutText ("-$authorityName ") `
    "Rollout report does not serialize $authorityName into generated commands."
}
foreach ($retired in @(
    '.\tools\package_release.cmd -Version',
    '.\tools\start_hardware_evidence.cmd -ReleaseTag',
    '.\tools\verify_consumer_promotion.cmd -Version')) {
  if ($rolloutText.Contains($retired)) {
    throw "Rollout report retains an authority-less generated command: $retired"
  }
}

$actionsText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'export_github_actions_status.ps1') -Raw
if ($actionsText.Contains('.\tools\audit_published_release.cmd -Version')) {
  throw 'GitHub status output still emits an authority-less release audit command.'
}
$companionText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'check_companion_v1_readiness.ps1') -Raw
foreach ($needle in @('verify_published_release.ps1 -Version <tag> @releaseToolchain',
    'downloaded archive does not confer release authority')) {
  Require-Text $companionText $needle "Companion handoff is missing trusted-source guidance: $needle"
}
$syntheticText = Get-Content -LiteralPath (
  Join-Path $PSScriptRoot 'generate_synthetic_hardware_evidence.ps1') -Raw
foreach ($needle in @('Diagnostic-only synthetic packet',
    'six exact-host toolchain authorities', 'archive does not confer release authority')) {
  Require-Text $syntheticText $needle "Synthetic fixture does not refuse operational rollout: $needle"
}
if ($syntheticText -match '\$rolloutStatusCommand\s*=.*export_rollout_status\.ps1') {
  throw 'Synthetic evidence still generates an authority-less operational rollout command.'
}

Write-Output 'Release toolchain documentation contract passed.'
