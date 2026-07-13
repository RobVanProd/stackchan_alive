param(
  [string]$Version,
  [string]$Repo = "",
  [string]$PackageRoot = "",
  [string]$ZipPath = "",
  [string]$ZipSidecarPath = "",
  [string]$ExpectedCommit = "",
  [switch]$AllowNonPrerelease
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot
. (Join-Path $PSScriptRoot "release_asset_contract.ps1")

function Assert-Command {
  param([string]$Name)
  $command = Get-Command $Name -ErrorAction SilentlyContinue
  if ($null -eq $command) {
    throw "Required command is not available on PATH: $Name"
  }
}

function Assert-File {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Missing local file: $Path"
  }
}

function Get-Sha256 {
  param([string]$Path)
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Resolve-RemoteTagCommit {
  param(
    [string]$Repo,
    [string]$TagName
  )

  $refJson = gh api "repos/$Repo/git/ref/tags/$TagName" | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or $null -eq $refJson) {
    throw "Unable to resolve remote tag $TagName in $Repo"
  }

  if ($refJson.object.type -eq "commit") {
    return ([string]$refJson.object.sha).ToLowerInvariant()
  }

  if ($refJson.object.type -ne "tag") {
    throw "Remote tag $TagName points to unsupported object type: $($refJson.object.type)"
  }

  $tagJson = gh api "repos/$Repo/git/tags/$($refJson.object.sha)" | ConvertFrom-Json
  if ($LASTEXITCODE -ne 0 -or $null -eq $tagJson) {
    throw "Unable to peel annotated remote tag $TagName in $Repo"
  }

  if ($tagJson.object.type -ne "commit") {
    throw "Annotated remote tag $TagName points to unsupported object type: $($tagJson.object.type)"
  }

  return ([string]$tagJson.object.sha).ToLowerInvariant()
}

function Assert-Asset {
  param(
    [object[]]$Assets,
    [string]$Name,
    [string]$ExpectedPath
  )

  Assert-File $ExpectedPath
  $asset = @($Assets | Where-Object { $_.name -eq $Name })
  if ($asset.Count -ne 1) {
    throw "Expected exactly one release asset named $Name; found $($asset.Count)"
  }

  $item = Get-Item -LiteralPath $ExpectedPath
  if ([int64]$asset[0].size -ne [int64]$item.Length) {
    throw "Release asset size mismatch for $Name`: expected $($item.Length), got $($asset[0].size)"
  }

  $expectedDigest = "sha256:$(Get-Sha256 $ExpectedPath)"
  if (-not [string]::IsNullOrWhiteSpace([string]$asset[0].digest) -and [string]$asset[0].digest -ne $expectedDigest) {
    throw "Release asset digest mismatch for $Name"
  }
}

function Assert-CompanionEvidenceHash {
  param(
    [object]$Evidence,
    [string]$PublishedPath,
    [string]$Extension,
    [string]$RequiredEvidencePathPattern = ""
  )

  $entries = @($Evidence.artifacts | ForEach-Object { @($_.entries) } | Where-Object {
    ([string]$_.path).EndsWith($Extension, [System.StringComparison]::OrdinalIgnoreCase) -and
    ([string]::IsNullOrWhiteSpace($RequiredEvidencePathPattern) -or ([string]$_.path -match $RequiredEvidencePathPattern))
  })
  if ($entries.Count -ne 1) {
    throw "Expected exactly one companion evidence entry for $Extension / $RequiredEvidencePathPattern; found $($entries.Count)."
  }
  $actualHash = Get-Sha256 $PublishedPath
  if ($actualHash -ne ([string]$entries[0].sha256).ToLowerInvariant()) {
    throw "Published companion artifact hash does not match release evidence: $(Split-Path -Leaf $PublishedPath)"
  }
}

if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = (git describe --tags --always --dirty).Trim()
}

Assert-Command "git"
Assert-Command "gh"

if ([string]::IsNullOrWhiteSpace($Repo)) {
  $Repo = (gh repo view --json nameWithOwner --jq ".nameWithOwner").Trim()
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Repo)) {
    throw "Unable to infer GitHub repo. Pass -Repo owner/name."
  }
}

if ([string]::IsNullOrWhiteSpace($ExpectedCommit)) {
  $tagCommit = git rev-list -n 1 $Version 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($tagCommit | Out-String).Trim())) {
    throw "Unable to resolve tag $Version. Pass -ExpectedCommit explicitly or fetch/create the tag first."
  }
  $ExpectedCommit = ($tagCommit | Out-String).Trim()
}

if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
  $PackageRoot = Join-Path $repoRoot "output/release/$Version"
}

if ([string]::IsNullOrWhiteSpace($ZipPath)) {
  $ZipPath = Join-Path $repoRoot "output/release/stackchan_alive_$Version.zip"
}

if ([string]::IsNullOrWhiteSpace($ZipSidecarPath)) {
  $ZipSidecarPath = "$ZipPath.sha256"
}

Assert-File $PackageRoot
Assert-File $ZipPath
Assert-File $ZipSidecarPath

$release = gh release view $Version --repo $Repo --json url,isPrerelease,assets,tagName,targetCommitish | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
  throw "Unable to read GitHub release: $Version"
}

if ($release.tagName -ne $Version) {
  throw "Release tag mismatch: expected $Version, got $($release.tagName)"
}

$remoteTagCommit = Resolve-RemoteTagCommit -Repo $Repo -TagName $Version
if ($remoteTagCommit -ne $ExpectedCommit.ToLowerInvariant()) {
  throw "Remote tag commit mismatch for $Version`: expected $ExpectedCommit, got $remoteTagCommit"
}

if (-not $release.isPrerelease -and -not $AllowNonPrerelease) {
  throw "Release is not marked prerelease. Pass -AllowNonPrerelease only for hardware-validated releases."
}

$assets = @($release.assets)
$expectedAssetEntries = Get-ReleaseFinalAssetEntries -Version $Version -PackageRoot $PackageRoot -ZipPath $ZipPath -ZipSidecarPath $ZipSidecarPath
$remoteDir = Join-Path $repoRoot "output/release/remote-$Version"
$companionAssetEntries = Get-ReleaseCompanionAssetEntries -Version $Version -CompanionAssetRoot $remoteDir

$releaseAssetManifestPath = Join-Path $PackageRoot "release_assets.json"
Assert-File $releaseAssetManifestPath
$releaseAssetManifest = Get-Content -LiteralPath $releaseAssetManifestPath -Raw | ConvertFrom-Json
if ($releaseAssetManifest.schema -ne "stackchan.release-assets.v1") {
  throw "release_assets.json schema mismatch: $($releaseAssetManifest.schema)"
}
if ($releaseAssetManifest.version -ne $Version) {
  throw "release_assets.json version mismatch: expected $Version, got $($releaseAssetManifest.version)"
}
if ($releaseAssetManifest.contract -ne "tools/release_asset_contract.ps1") {
  throw "release_assets.json contract path mismatch: $($releaseAssetManifest.contract)"
}
if ([int]$releaseAssetManifest.counts.releaseAssets -ne @($expectedAssetEntries).Count) {
  throw "release_assets.json release asset count mismatch: expected $(@($expectedAssetEntries).Count), got $($releaseAssetManifest.counts.releaseAssets)"
}

$manifestAssetNames = @($releaseAssetManifest.releaseAssets | ForEach-Object { [string]$_.name })
foreach ($assetEntry in $expectedAssetEntries) {
  if ($manifestAssetNames -notcontains $assetEntry.Name) {
    throw "release_assets.json missing contract asset: $($assetEntry.Name)"
  }
}
foreach ($assetName in $manifestAssetNames) {
  if (@($expectedAssetEntries | Where-Object { $_.Name -eq $assetName }).Count -ne 1) {
    throw "release_assets.json contains unexpected contract asset: $assetName"
  }
}

foreach ($assetEntry in $expectedAssetEntries) {
  Assert-Asset -Assets $assets -Name $assetEntry.Name -ExpectedPath $assetEntry.Path
}

$auditRoot = Join-Path $repoRoot "output/release-audit/$Version"
$allowedAuditAssetEntries = Get-ReleaseAllowedAuditAssetEntries -AuditRoot $auditRoot
foreach ($assetEntry in $allowedAuditAssetEntries) {
  $assetName = $assetEntry.Name
  $auditAsset = @($assets | Where-Object { $_.name -eq $assetName })
  if ($auditAsset.Count -eq 0) {
    continue
  }
  if ($auditAsset.Count -ne 1) {
    throw "Expected at most one release audit asset named $assetName; found $($auditAsset.Count)"
  }
  if (Test-Path -LiteralPath $assetEntry.Path) {
    Assert-Asset -Assets $assets -Name $assetName -ExpectedPath $assetEntry.Path
  }
}

$allowedAssetNames = @{}
foreach ($assetName in $manifestAssetNames) {
  $allowedAssetNames[$assetName] = $true
}

$manifestAuditAssetNames = @($releaseAssetManifest.allowedAuditAssets | ForEach-Object { [string]$_.name })
foreach ($assetEntry in $allowedAuditAssetEntries) {
  if ($manifestAuditAssetNames -notcontains $assetEntry.Name) {
    throw "release_assets.json missing allowed audit asset: $($assetEntry.Name)"
  }
}
foreach ($assetName in $manifestAuditAssetNames) {
  if (@($allowedAuditAssetEntries | Where-Object { $_.Name -eq $assetName }).Count -ne 1) {
    throw "release_assets.json contains unexpected allowed audit asset: $assetName"
  }
  $allowedAssetNames[$assetName] = $true
}

foreach ($assetEntry in $companionAssetEntries) {
  $matchingAssets = @($assets | Where-Object { $_.name -eq $assetEntry.Name })
  if ($matchingAssets.Count -ne 1) {
    throw "Expected exactly one companion release asset named $($assetEntry.Name); found $($matchingAssets.Count)"
  }
  $allowedAssetNames[$assetEntry.Name] = $true
}

foreach ($asset in $assets) {
  if (-not $allowedAssetNames.ContainsKey([string]$asset.name)) {
    throw "Unexpected release asset: $($asset.name)"
  }
}

New-Item -ItemType Directory -Force -Path $remoteDir | Out-Null

foreach ($assetEntry in $companionAssetEntries) {
  gh release download $Version --repo $Repo --pattern $assetEntry.Name --dir $remoteDir --clobber
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to download published companion asset $($assetEntry.Name) for $Version"
  }
  Assert-Asset -Assets $assets -Name $assetEntry.Name -ExpectedPath $assetEntry.Path
}

$companionEvidencePath = Join-Path $remoteDir "COMPANION_RELEASE_EVIDENCE.json"
$companionEvidence = Get-Content -LiteralPath $companionEvidencePath -Raw | ConvertFrom-Json
if ($companionEvidence.schema -ne "stackchan.companion-release-evidence.v1") {
  throw "Companion release evidence schema mismatch: $($companionEvidence.schema)"
}
if ($companionEvidence.status -ne "complete") {
  throw "Companion release evidence is not complete: $($companionEvidence.status)"
}
if ($companionEvidence.version -ne $Version) {
  throw "Companion release evidence version mismatch: expected $Version, got $($companionEvidence.version)"
}
if ([string]$companionEvidence.commit -ne $ExpectedCommit) {
  throw "Companion release evidence commit mismatch: expected $ExpectedCommit, got $($companionEvidence.commit)"
}
if ($companionEvidence.uploadSigningRequired -ne $true -or
    $companionEvidence.androidSigning.signingProfile -ne "upload-key" -or
    $companionEvidence.androidBundleSigning.signingProfile -ne "upload-key") {
  throw "Companion Android release evidence is not pinned to APK and AAB upload-key signing."
}
if ($companionEvidence.packageEvidence.status -ne "present") {
  throw "Companion release evidence does not include the release package provenance."
}

if ($companionEvidence.desktopPackageEvidenceRequired -ne $true -or
    $companionEvidence.desktopPackageEvidence.status -ne "ready") {
  throw "Companion release evidence does not require ready native desktop package/runtime evidence."
}
$desktopEvidencePlatforms = @($companionEvidence.desktopPackageEvidence.platforms)
if ($desktopEvidencePlatforms.Count -ne 3 -or @($desktopEvidencePlatforms.platform | Select-Object -Unique).Count -ne 3) {
  throw "Companion release evidence must contain one native package/runtime summary for Windows, Linux, and macOS."
}
$publishedDesktopPaths = [ordered]@{
  windows = Join-Path $remoteDir "stackchan-companion-windows-$Version.msi"
  linux = Join-Path $remoteDir "stackchan-companion-linux-$Version.deb"
  macos = Join-Path $remoteDir "stackchan-companion-macos-$Version.dmg"
}
$requiredInstallerBrainFiles = @(
  "brain/bridge/lan_service.py",
  "brain/bridge/reference_bridge.py",
  "brain/data/voice_source_provenance.yaml",
  "brain/docs/media/voice/stackchan_spark_greeting.wav"
)
foreach ($platform in $publishedDesktopPaths.Keys) {
  $summary = @($desktopEvidencePlatforms | Where-Object { [string]$_.platform -eq $platform })
  if ($summary.Count -ne 1) { throw "Missing unique native desktop package/runtime evidence for $platform." }
  if ((Get-Sha256 $publishedDesktopPaths[$platform]) -ne ([string]$summary[0].packageSha256).ToLowerInvariant()) {
    throw "Published $platform desktop package does not match its native package evidence."
  }
  if ([string]$summary[0].runtimeSha256 -notmatch '^[a-fA-F0-9]{64}$' -or
      [int64]$summary[0].processedFileCount -lt 2 -or
      [int64]$summary[0].processedBytes -le 0) {
    throw "Native desktop runtime evidence is incomplete for $platform."
  }
  if ([string]$summary[0].installerExtractionMethod -ne "native" -or
      [string]$summary[0].installerAppJarName -notmatch '^app-desktop-.+\.jar$' -or
      [string]$summary[0].installerAppJarSha256 -notmatch '^[a-fA-F0-9]{64}$' -or
      ([string]$summary[0].installerPackageSha256).ToLowerInvariant() -ne ([string]$summary[0].packageSha256).ToLowerInvariant() -or
      ([string]$summary[0].installerRuntimeSha256).ToLowerInvariant() -ne ([string]$summary[0].runtimeSha256).ToLowerInvariant() -or
      [int64]$summary[0].installerRuntimeFileCount -ne [int64]$summary[0].processedFileCount -or
      [int64]$summary[0].installerRuntimeBytes -ne [int64]$summary[0].processedBytes) {
    throw "Installer-derived desktop runtime evidence is incomplete or inconsistent for $platform."
  }
  $installerBrainFiles = @($summary[0].installerBrainFiles | ForEach-Object { [string]$_ })
  foreach ($brainPath in $requiredInstallerBrainFiles) {
    if ($installerBrainFiles -notcontains $brainPath) { throw "Installer-derived desktop evidence is missing $brainPath for $platform." }
  }
}

Assert-CompanionEvidenceHash $companionEvidence (Join-Path $remoteDir "stackchan-companion-android-$Version.apk") ".apk" '(^|[\\/])release[\\/]'
Assert-CompanionEvidenceHash $companionEvidence (Join-Path $remoteDir "stackchan-companion-android-$Version.aab") ".aab"
Assert-CompanionEvidenceHash $companionEvidence (Join-Path $remoteDir "stackchan-companion-windows-$Version.msi") ".msi"
Assert-CompanionEvidenceHash $companionEvidence (Join-Path $remoteDir "stackchan-companion-linux-$Version.deb") ".deb"
Assert-CompanionEvidenceHash $companionEvidence (Join-Path $remoteDir "stackchan-companion-macos-$Version.dmg") ".dmg"

gh release download $Version --repo $Repo --pattern "stackchan_alive_$Version.zip" --dir $remoteDir --clobber
if ($LASTEXITCODE -ne 0) {
  throw "Failed to download published ZIP for $Version"
}

gh release download $Version --repo $Repo --pattern "stackchan_alive_$Version.zip.sha256" --dir $remoteDir --clobber
if ($LASTEXITCODE -ne 0) {
  throw "Failed to download published ZIP SHA256 sidecar for $Version"
}

$remoteZip = Join-Path $remoteDir "stackchan_alive_$Version.zip"
$remoteZipSidecar = Join-Path $remoteDir "stackchan_alive_$Version.zip.sha256"
$remoteZipHashText = (Get-Content -LiteralPath $remoteZipSidecar -Raw).Trim()
if ($remoteZipHashText -notmatch "^([a-f0-9]{64})  stackchan_alive_$([regex]::Escape($Version))\.zip$") {
  throw "Invalid published ZIP SHA256 sidecar format: $remoteZipHashText"
}

$remoteZipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $remoteZip).Hash.ToLowerInvariant()
if ($remoteZipHash -ne $Matches[1]) {
  throw "Published ZIP SHA256 sidecar does not match downloaded ZIP"
}

& (Join-Path $PSScriptRoot "verify_release_package.ps1") -Version $Version -ZipPath $remoteZip -ExpectedCommit $ExpectedCommit

Write-Host "Published release verified:"
Write-Host $release.url
