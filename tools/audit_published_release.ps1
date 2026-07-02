param(
  [string]$Version = "",
  [string]$Repo = "RobVanProd/stackchan_alive",
  [string]$PackageRoot = "",
  [string]$ZipPath = "",
  [string]$ZipSidecarPath = "",
  [string]$ExpectedCommit = "",
  [string]$OutDir = "",
  [switch]$AllowNonPrerelease,
  [switch]$UploadToRelease,
  [switch]$StrictPromotion
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

function Read-JsonFile {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
    return $null
  }
  return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Invoke-ToolCapture {
  param([string[]]$Arguments)

  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File @Arguments 2>&1
    return [ordered]@{
      exitCode = $LASTEXITCODE
      text = ($output | Out-String).TrimEnd()
    }
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
}

function Get-Sha256OrEmpty {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
    return ""
  }
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Assert-UploadedAuditAsset {
  param(
    [object[]]$Assets,
    [string]$Name,
    [string]$Path
  )

  $asset = @($Assets | Where-Object { $_.name -eq $Name })
  if ($asset.Count -ne 1) {
    throw "Expected exactly one release audit asset named $Name; found $($asset.Count)"
  }

  $item = Get-Item -LiteralPath $Path
  if ([int64]$asset[0].size -ne [int64]$item.Length) {
    throw "Release audit asset size mismatch for $Name`: expected $($item.Length), got $($asset[0].size)"
  }

  $expectedDigest = "sha256:$(Get-Sha256OrEmpty $Path)"
  if (-not [string]::IsNullOrWhiteSpace([string]$asset[0].digest) -and [string]$asset[0].digest -ne $expectedDigest) {
    throw "Release audit asset digest mismatch for $Name"
  }
}

if ([string]::IsNullOrWhiteSpace($Version)) {
  $manifestProbe = Join-Path $repoRoot "release_manifest.json"
  if (Test-Path -LiteralPath $manifestProbe) {
    $Version = [string](Read-JsonFile $manifestProbe).version
  }
}
if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = (git describe --tags --always --dirty).Trim()
}

if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
  $PackageRoot = Join-Path $repoRoot "output/release/$Version"
  if (-not (Test-Path -LiteralPath $PackageRoot) -and (Test-Path -LiteralPath (Join-Path $repoRoot "release_manifest.json"))) {
    $PackageRoot = $repoRoot
  }
}

if ([string]::IsNullOrWhiteSpace($ZipPath)) {
  $ZipPath = Join-Path $repoRoot "output/release/stackchan_alive_$Version.zip"
}
if ([string]::IsNullOrWhiteSpace($ZipSidecarPath)) {
  $ZipSidecarPath = "$ZipPath.sha256"
}
if ([string]::IsNullOrWhiteSpace($OutDir)) {
  $OutDir = Join-Path $repoRoot "output/release-audit/$Version"
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$outPath = (Resolve-Path $OutDir).Path

$manifest = Read-JsonFile (Join-Path $PackageRoot "release_manifest.json")
if ($null -ne $manifest -and [string]::IsNullOrWhiteSpace($ExpectedCommit)) {
  $ExpectedCommit = [string]$manifest.commit
}
if ([string]::IsNullOrWhiteSpace($ExpectedCommit)) {
  $ExpectedCommit = (git rev-list -n 1 $Version).Trim()
}

$publishedVerifyArgs = @(
  (Join-Path $PSScriptRoot "verify_published_release.ps1"),
  "-Version", $Version,
  "-Repo", $Repo,
  "-PackageRoot", $PackageRoot,
  "-ZipPath", $ZipPath,
  "-ZipSidecarPath", $ZipSidecarPath,
  "-ExpectedCommit", $ExpectedCommit
)
if ($AllowNonPrerelease) {
  $publishedVerifyArgs += "-AllowNonPrerelease"
}
$publishedVerify = Invoke-ToolCapture $publishedVerifyArgs

$actionsDir = Join-Path $outPath "actions"
$actions = $null
$actionsExport = [ordered]@{ exitCode = 1; text = "Skipped because published release verification failed." }
if ($publishedVerify.exitCode -eq 0) {
  $actionsExport = Invoke-ToolCapture @(
    (Join-Path $PSScriptRoot "export_github_actions_status.ps1"),
    "-Repo", $Repo,
    "-Version", $Version,
    "-Commit", $ExpectedCommit,
    "-OutputDir", $actionsDir
  )
  $actions = Read-JsonFile (Join-Path $actionsDir "github_actions_status.json")
}

$rolloutDir = Join-Path $outPath "rollout"
$rollout = $null
$rolloutExport = [ordered]@{ exitCode = 1; text = "Skipped because published release verification failed." }
if ($publishedVerify.exitCode -eq 0) {
  $rolloutExport = Invoke-ToolCapture @(
    (Join-Path $PSScriptRoot "export_rollout_status.ps1"),
    "-Version", $Version,
    "-PackageRoot", $PackageRoot,
    "-ExpectedCommit", $ExpectedCommit,
    "-OutDir", $rolloutDir
  )
  $rollout = Read-JsonFile (Join-Path $rolloutDir "ROLLOUT_STATUS.json")
}

$releaseUrl = "https://github.com/$Repo/releases/tag/$Version"
$releaseAssetCount = 0
if ($publishedVerify.exitCode -eq 0) {
  $releaseJson = gh release view $Version --repo $Repo --json assets,url 2>$null
  if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($releaseJson | Out-String).Trim())) {
    $release = $releaseJson | ConvertFrom-Json
    $releaseUrl = [string]$release.url
    $releaseAssetCount = @($release.assets).Count
  }
}

$consumerReady = ($null -ne $rollout -and [bool]$rollout.consumerReady)
$auditStatus = if ($publishedVerify.exitCode -ne 0) {
  "release-verification-failed"
} elseif ($consumerReady) {
  "published-release-consumer-ready"
} else {
  "published-release-blocked-or-pending"
}

$audit = [ordered]@{
  schema = "stackchan.release-audit.v1"
  version = $Version
  commit = $ExpectedCommit
  repo = $Repo
  generatedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  status = $auditStatus
  releaseUrl = $releaseUrl
  packageRoot = (Resolve-Path $PackageRoot).Path
  zipPath = $ZipPath
  zipSha256 = Get-Sha256OrEmpty $ZipPath
  releaseAssetCount = $releaseAssetCount
  publishedReleaseVerification = [ordered]@{
    status = if ($publishedVerify.exitCode -eq 0) { "pass" } else { "fail" }
    exitCode = $publishedVerify.exitCode
  }
  githubActions = if ($null -ne $actions) {
    [ordered]@{
      status = [string]$actions.status
      missingRequiredWorkflows = @($actions.missingRequiredWorkflows)
      report = Join-Path $actionsDir "GITHUB_ACTIONS_STATUS.md"
    }
  } else {
    [ordered]@{
      status = "missing"
      missingRequiredWorkflows = @()
      report = ""
    }
  }
  rollout = if ($null -ne $rollout) {
    [ordered]@{
      status = [string]$rollout.status
      consumerReady = [bool]$rollout.consumerReady
      blockers = @($rollout.blockers)
      report = Join-Path $rolloutDir "ROLLOUT_STATUS.md"
    }
  } else {
    [ordered]@{
      status = "missing"
      consumerReady = $false
      blockers = @()
      report = ""
    }
  }
  commandResults = [ordered]@{
    publishedVerifyExitCode = $publishedVerify.exitCode
    actionsExportExitCode = $actionsExport.exitCode
    rolloutExportExitCode = $rolloutExport.exitCode
  }
}

$auditJsonPath = Join-Path $outPath "RELEASE_AUDIT.json"
$auditMdPath = Join-Path $outPath "RELEASE_AUDIT.md"
$audit | ConvertTo-Json -Depth 8 | Set-Content -Path $auditJsonPath -Encoding UTF8

$blockerLines = @()
foreach ($blocker in @($audit.rollout.blockers)) {
  $blockerLines += "- $blocker"
}
if ($blockerLines.Count -eq 0) {
  $blockerLines += "- None"
}

@"
# Stackchan Published Release Audit

- Version: $Version
- Commit: $ExpectedCommit
- Repository: $Repo
- Release: $releaseUrl
- Status: $auditStatus
- Generated UTC: $($audit.generatedUtc)

## Verification

- Published release assets: $($audit.publishedReleaseVerification.status)
- Release asset count: $releaseAssetCount
- ZIP SHA256: $($audit.zipSha256)
- GitHub Actions: $($audit.githubActions.status)
- Rollout status: $($audit.rollout.status)
- Consumer ready: $($audit.rollout.consumerReady)

## Blockers

$($blockerLines -join [Environment]::NewLine)

## Reports

- Actions report: $($audit.githubActions.report)
- Rollout report: $($audit.rollout.report)
- Machine-readable audit: RELEASE_AUDIT.json
"@ | Set-Content -Path $auditMdPath -Encoding UTF8

if ($UploadToRelease -and $publishedVerify.exitCode -eq 0) {
  & gh release upload $Version `
    $auditMdPath `
    $auditJsonPath `
    --repo $Repo `
    --clobber
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to upload release audit assets to $Version"
  }

  $uploadedReleaseJson = gh release view $Version --repo $Repo --json assets 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($uploadedReleaseJson | Out-String).Trim())) {
    throw "Unable to verify uploaded release audit assets for $Version"
  }
  $uploadedRelease = $uploadedReleaseJson | ConvertFrom-Json
  $uploadedAssets = @($uploadedRelease.assets)
  Assert-UploadedAuditAsset -Assets $uploadedAssets -Name "RELEASE_AUDIT.md" -Path $auditMdPath
  Assert-UploadedAuditAsset -Assets $uploadedAssets -Name "RELEASE_AUDIT.json" -Path $auditJsonPath
}

Write-Host "Published release audit exported:"
Write-Host $auditMdPath
Write-Host $auditJsonPath
if ($UploadToRelease -and $publishedVerify.exitCode -eq 0) {
  Write-Host "Published release audit assets uploaded and verified."
}
Write-Host "Status: $auditStatus"

if ($publishedVerify.exitCode -ne 0) {
  Write-Error $publishedVerify.text
  exit 1
}
if ($StrictPromotion -and -not $consumerReady) {
  exit 2
}
