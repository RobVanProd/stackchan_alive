param(
  [string]$EvidencePath,
  [ValidateSet("", "windows", "linux", "macos")]
  [string]$ExpectedPlatform = "",
  [string]$ExpectedPackageSha256 = "",
  [string]$ExpectedSourceCommit = "",
  [switch]$RequireOperatorTarget,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$checks = @()

function Add-Check([string]$Id, [string]$Status, [string]$Detail) {
  $script:checks += [ordered]@{ id = $Id; status = $Status; detail = $Detail }
}

function Test-Sha256([string]$Value) { return $Value -match '^[a-fA-F0-9]{64}$' }
function Test-Commit([string]$Value) { return $Value -match '^[a-fA-F0-9]{40}$' }

$evidence = $null
if ([string]::IsNullOrWhiteSpace($EvidencePath) -or -not (Test-Path -LiteralPath $EvidencePath -PathType Leaf)) {
  Add-Check "evidence-json" "fail" "Desktop target-install evidence is missing: $EvidencePath"
} else {
  try {
    $evidence = Get-Content -LiteralPath $EvidencePath -Raw | ConvertFrom-Json
    Add-Check "evidence-json" "pass" "Desktop target-install evidence JSON parses."
  } catch {
    Add-Check "evidence-json" "fail" "Desktop target-install evidence is invalid JSON: $($_.Exception.Message)"
  }
}

if ($null -ne $evidence) {
  if ([string]$evidence.schema -eq "stackchan.desktop-target-install-evidence.v1") { Add-Check "schema" "pass" "Schema matches." } else { Add-Check "schema" "fail" "Unexpected schema: $($evidence.schema)" }
  if ([string]$evidence.status -eq "installed-and-ready") { Add-Check "status" "pass" "Installed package is ready." } else { Add-Check "status" "fail" "Expected installed-and-ready, got $($evidence.status)." }

  $platform = [string]$evidence.platform
  if ($platform -in @("windows", "linux", "macos") -and [string]$evidence.host.platform -eq $platform) { Add-Check "platform" "pass" "Host and evidence platform match $platform." } else { Add-Check "platform" "fail" "Evidence platform and native host platform must match." }
  if ([string]::IsNullOrWhiteSpace($ExpectedPlatform) -or $platform -eq $ExpectedPlatform) { Add-Check "expected-platform" "pass" "Expected platform matches." } else { Add-Check "expected-platform" "fail" "Expected $ExpectedPlatform, got $platform." }

  $sourceCommit = [string]$evidence.sourceCommit
  if (Test-Commit $sourceCommit) { Add-Check "source-commit" "pass" "Full source commit is recorded." } else { Add-Check "source-commit" "fail" "sourceCommit must be a full 40-character SHA." }
  if ([string]::IsNullOrWhiteSpace($ExpectedSourceCommit) -or $sourceCommit -eq $ExpectedSourceCommit) { Add-Check "expected-source-commit" "pass" "Expected source commit matches." } else { Add-Check "expected-source-commit" "fail" "Evidence source commit does not match the release candidate." }

  $packageSha = ([string]$evidence.package.sha256).ToLowerInvariant()
  $expectedExtension = @{ windows = ".msi"; linux = ".deb"; macos = ".dmg" }[$platform]
  if ((Test-Sha256 $packageSha) -and [string]$evidence.package.name -like "*$expectedExtension" -and [int64]$evidence.package.bytes -gt 0) { Add-Check "package" "pass" "Exact native package identity is recorded." } else { Add-Check "package" "fail" "Package name, size, extension, or SHA-256 is invalid." }
  if ([string]::IsNullOrWhiteSpace($ExpectedPackageSha256) -or $packageSha -eq $ExpectedPackageSha256.ToLowerInvariant()) { Add-Check "expected-package-sha256" "pass" "Expected package SHA-256 matches." } else { Add-Check "expected-package-sha256" "fail" "Installed package SHA-256 does not match the release artifact." }

  $expectedMethod = @{ windows = "msiexec-install"; linux = "dpkg-install"; macos = "dmg-application-copy" }[$platform]
  $installExitCode = $evidence.install.exitCode
  if ([string]$evidence.install.method -eq $expectedMethod -and $null -ne $installExitCode -and [int]$installExitCode -in @(0, 1641, 3010)) { Add-Check "native-install" "pass" "Native installation method completed successfully." } else { Add-Check "native-install" "fail" "Native installation method or exit code is invalid." }
  $launchExitCode = $evidence.launch.exitCode
  if (-not [string]::IsNullOrWhiteSpace([string]$evidence.install.installedLauncherPath) -and $null -ne $launchExitCode -and [int]$launchExitCode -eq 0) { Add-Check "installed-launcher" "pass" "Installed launcher exited successfully." } else { Add-Check "installed-launcher" "fail" "Installed launcher path or exit code is invalid." }

  $probe = $evidence.launch.probe
  if ([string]$probe.schema -eq "stackchan.desktop-packaged-runtime-smoke.v1" -and [string]$probe.status -eq "ready" -and [string]$probe.platform -eq $platform -and [string]$probe.launchContext -eq "installed-package" -and [string]$probe.scope -eq "installed-native-package-headless-runtime-probe" -and $probe.runtimePresent -eq $true -and $probe.pythonAvailable -eq $true -and $probe.brainScriptAvailable -eq $true -and @($probe.issues).Count -eq 0 -and $probe.substitutesForTargetInstall -eq $false) {
    Add-Check "installed-runtime-probe" "pass" "Installed managed runtime, Python, and brain entry point are ready."
  } else {
    Add-Check "installed-runtime-probe" "fail" "Installed packaged-runtime probe is incomplete or has invalid scope."
  }

  if ($evidence.targetInstallVerified -eq $true -and [string]$evidence.scope -eq "exact-native-package-install-and-headless-launch" -and @($evidence.issues).Count -eq 0) { Add-Check "target-install-scope" "pass" "Exact native target install is verified." } else { Add-Check "target-install-scope" "fail" "Evidence does not verify an exact native package install." }
  if ($evidence.substitutesForHumanAcceptance -eq $false) { Add-Check "human-acceptance-scope" "pass" "Human acceptance remains a separate gate." } else { Add-Check "human-acceptance-scope" "fail" "Target-install evidence must not claim human acceptance." }

  $environmentKind = [string]$evidence.environmentKind
  if ($environmentKind -in @("operator-target-workstation", "ci-native-runner")) { Add-Check "environment-kind" "pass" "Installation environment is classified." } else { Add-Check "environment-kind" "fail" "Unexpected environmentKind: $environmentKind" }
  if (-not $RequireOperatorTarget -or $environmentKind -eq "operator-target-workstation") { Add-Check "operator-target" "pass" "Operator target requirement is satisfied." } else { Add-Check "operator-target" "fail" "Final desktop acceptance requires operator-target-workstation evidence, not CI evidence." }
}

$failed = @($checks | Where-Object { $_.status -eq "fail" })
$passed = @($checks | Where-Object { $_.status -eq "pass" })
$report = [ordered]@{
  schema = "stackchan.desktop-target-install-evidence-check.v1"
  status = if ($failed.Count -eq 0) { "desktop-target-install-ready" } else { "not-ready" }
  evidencePath = $EvidencePath
  platform = if ($null -eq $evidence) { "" } else { [string]$evidence.platform }
  sourceCommit = if ($null -eq $evidence) { "" } else { [string]$evidence.sourceCommit }
  packageSha256 = if ($null -eq $evidence) { "" } else { ([string]$evidence.package.sha256).ToLowerInvariant() }
  environmentKind = if ($null -eq $evidence) { "" } else { [string]$evidence.environmentKind }
  passed = $passed.Count
  failed = $failed.Count
  checks = @($checks)
}

if ($Json) { $report | ConvertTo-Json -Depth 8 } else { Write-Host "Desktop target install evidence: $($report.status)" }
if ($failed.Count -gt 0) { exit 1 }
exit 0
