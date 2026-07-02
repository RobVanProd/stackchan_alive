param(
  [string]$ActionsStatusPath = "",
  [string]$OutPath = "",
  [string]$Version = "",
  [string]$Commit = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

$externalAccountStatuses = @(
  "external-account-billing-or-spending-limit",
  "external-account-ci-pre-runner-allocation"
)

function Resolve-InputPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) {
    throw "Pass -ActionsStatusPath pointing at the release github_actions_status.json."
  }

  return (Resolve-Path -LiteralPath $Path).Path
}

$resolvedActionsStatusPath = Resolve-InputPath $ActionsStatusPath
$actionsStatus = Get-Content -LiteralPath $resolvedActionsStatusPath -Raw | ConvertFrom-Json

if ([string]$actionsStatus.schema -ne "stackchan.github-actions-status.v1") {
  throw "Actions status schema mismatch: $($actionsStatus.schema)"
}

if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = [string]$actionsStatus.version
}
if ([string]::IsNullOrWhiteSpace($Commit)) {
  $Commit = [string]$actionsStatus.commit
}
if ([string]::IsNullOrWhiteSpace($Version)) {
  throw "Could not infer -Version from $resolvedActionsStatusPath."
}
if ([string]::IsNullOrWhiteSpace($Commit)) {
  throw "Could not infer -Commit from $resolvedActionsStatusPath."
}

if ([string]$actionsStatus.version -ne $Version) {
  throw "Actions status version mismatch: expected $Version, got $($actionsStatus.version)"
}
if ([string]$actionsStatus.commit -ne $Commit) {
  throw "Actions status commit mismatch: expected $Commit, got $($actionsStatus.commit)"
}

$status = [string]$actionsStatus.status
if ($externalAccountStatuses -notcontains $status) {
  throw "Actions status '$status' is not an external account block. Refusing to draft an account-block exception."
}

if ([string]::IsNullOrWhiteSpace($OutPath)) {
  $safeVersion = $Version -replace "[^A-Za-z0-9_.-]", "_"
  $OutPath = Join-Path $repoRoot "output/ci-exceptions/$safeVersion/CI_ACCOUNT_BLOCK_EXCEPTION_DRAFT.json"
}

$reason = [string]$actionsStatus.interpretation
if ([string]::IsNullOrWhiteSpace($reason)) {
  $reason = "GitHub Actions could not start required jobs because of an account billing, spending-limit, or pre-runner allocation outage outside this repository."
}

$draft = [ordered]@{
  schema = "stackchan.ci-account-block-exception.v1"
  version = $Version
  commit = $Commit
  githubActionsStatus = $status
  approvedBy = "TBD - accountable approver required"
  approvedUtc = "TBD - YYYY-MM-DDTHH:MM:SSZ"
  reason = $reason
  riskAccepted = $false
  localReleaseVerificationPassed = $false
  strictHardwareEvidencePassed = $false
  productionVoiceSourceReady = $false
  followUpOwner = "TBD - CI account owner"
  followUpDueUtc = "TBD - YYYY-MM-DDTHH:MM:SSZ"
  sourceActionsStatusPath = $resolvedActionsStatusPath
  generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
}

$outDir = Split-Path -Parent $OutPath
if (-not [string]::IsNullOrWhiteSpace($outDir)) {
  New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}

$draft | ConvertTo-Json -Depth 5 | Set-Content -Path $OutPath -Encoding UTF8

Write-Host "CI account-block exception draft written:"
Write-Host $OutPath
Write-Host ""
Write-Host "This is intentionally not promotion-ready. Complete the approval fields and set each proof boolean only after the named gate is genuinely satisfied."
