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
$expectedAssets = @{
  "stackchan_alive_$Version.zip" = $ZipPath
  "stackchan_alive_$Version.zip.sha256" = $ZipSidecarPath
  "stackchan_alive_preview.png" = (Join-Path $PackageRoot "media/stackchan_alive_preview.png")
  "stackchan_alive_expression_sheet.png" = (Join-Path $PackageRoot "media/stackchan_alive_expression_sheet.png")
  "stackchan_alive_preview.mp4" = (Join-Path $PackageRoot "media/stackchan_alive_preview.mp4")
  "stackchan_alive_preview.gif" = (Join-Path $PackageRoot "media/stackchan_alive_preview.gif")
  "stackchan_spark_greeting.wav" = (Join-Path $PackageRoot "media/voice/stackchan_spark_greeting.wav")
  "stackchan_spark_thinking.wav" = (Join-Path $PackageRoot "media/voice/stackchan_spark_thinking.wav")
  "stackchan_spark_safety.wav" = (Join-Path $PackageRoot "media/voice/stackchan_spark_safety.wav")
  "stackchan_spark_audition_warm_slow_greeting.wav" = (Join-Path $PackageRoot "media/voice/stackchan_spark_audition_warm_slow_greeting.wav")
  "stackchan_spark_audition_bright_robot_greeting.wav" = (Join-Path $PackageRoot "media/voice/stackchan_spark_audition_bright_robot_greeting.wav")
  "stackchan_spark_audition_bright_robot_greeting.mp3" = (Join-Path $PackageRoot "media/voice/stackchan_spark_audition_bright_robot_greeting.mp3")
  "stackchan_spark_thinking.mp3" = (Join-Path $PackageRoot "media/voice/stackchan_spark_thinking.mp3")
  "RVC_AUDITION.html" = (Join-Path $PackageRoot "media/voice/rvc/RVC_AUDITION.html")
  "RVC_AUDITIONS.md" = (Join-Path $PackageRoot "media/voice/rvc/RVC_AUDITIONS.md")
  "RVC_AUDITIONS.json" = (Join-Path $PackageRoot "media/voice/rvc/RVC_AUDITIONS.json")
  "stackchan_rvc_neutral.wav" = (Join-Path $PackageRoot "media/voice/rvc/stackchan_rvc_neutral.wav")
  "stackchan_rvc_warm_slow.wav" = (Join-Path $PackageRoot "media/voice/rvc/stackchan_rvc_warm_slow.wav")
  "stackchan_rvc_bright_robot.wav" = (Join-Path $PackageRoot "media/voice/rvc/stackchan_rvc_bright_robot.wav")
  "stackchan_rvc_bright_robot.mp3" = (Join-Path $PackageRoot "media/voice/rvc/stackchan_rvc_bright_robot.mp3")
  "stackchan_rvc_bright_robot_less_static.wav" = (Join-Path $PackageRoot "media/voice/rvc/stackchan_rvc_bright_robot_less_static.wav")
  "stackchan_rvc_bright_robot_sweet_vocoder.wav" = (Join-Path $PackageRoot "media/voice/rvc/stackchan_rvc_bright_robot_sweet_vocoder.wav")
  "stackchan_rvc_bright_robot_soft_boops.wav" = (Join-Path $PackageRoot "media/voice/rvc/stackchan_rvc_bright_robot_soft_boops.wav")
  "stackchan_rvc_spark_boops.wav" = (Join-Path $PackageRoot "media/voice/rvc/stackchan_rvc_spark_boops.wav")
  "stackchan_rvc_high_character.wav" = (Join-Path $PackageRoot "media/voice/rvc/stackchan_rvc_high_character.wav")
  "stackchan_rvc_thinking_neutral.wav" = (Join-Path $PackageRoot "media/voice/rvc/stackchan_rvc_thinking_neutral.wav")
  "stackchan_rvc_thinking_neutral.mp3" = (Join-Path $PackageRoot "media/voice/rvc/stackchan_rvc_thinking_neutral.mp3")
  "stackchan_rvc_safety_neutral.wav" = (Join-Path $PackageRoot "media/voice/rvc/stackchan_rvc_safety_neutral.wav")
  "stackchan_rvc_safety_neutral.mp3" = (Join-Path $PackageRoot "media/voice/rvc/stackchan_rvc_safety_neutral.mp3")
  "GITHUB_ACTIONS_STATUS.md" = (Join-Path $PackageRoot "GITHUB_ACTIONS_STATUS.md")
  "github_actions_status.json" = (Join-Path $PackageRoot "github_actions_status.json")
  "firmware-display-only.bin" = (Join-Path $PackageRoot "firmware/display_only/firmware.bin")
  "firmware-servo-calibration.bin" = (Join-Path $PackageRoot "firmware/servo_calibration/firmware.bin")
  "bootloader.bin" = (Join-Path $PackageRoot "firmware/display_only/bootloader.bin")
  "partitions.bin" = (Join-Path $PackageRoot "firmware/display_only/partitions.bin")
}

foreach ($assetName in $expectedAssets.Keys) {
  Assert-Asset -Assets $assets -Name $assetName -ExpectedPath $expectedAssets[$assetName]
}

$auditRoot = Join-Path $repoRoot "output/release-audit/$Version"
$allowedAuditAssets = @{
  "RELEASE_AUDIT.md" = (Join-Path $auditRoot "RELEASE_AUDIT.md")
  "RELEASE_AUDIT.json" = (Join-Path $auditRoot "RELEASE_AUDIT.json")
}

foreach ($assetName in $allowedAuditAssets.Keys) {
  $auditAsset = @($assets | Where-Object { $_.name -eq $assetName })
  if ($auditAsset.Count -eq 0) {
    continue
  }
  if ($auditAsset.Count -ne 1) {
    throw "Expected at most one release audit asset named $assetName; found $($auditAsset.Count)"
  }
  if (Test-Path -LiteralPath $allowedAuditAssets[$assetName]) {
    Assert-Asset -Assets $assets -Name $assetName -ExpectedPath $allowedAuditAssets[$assetName]
  }
}

$allowedAssetNames = @{}
foreach ($assetName in $expectedAssets.Keys) {
  $allowedAssetNames[$assetName] = $true
}
foreach ($assetName in $allowedAuditAssets.Keys) {
  $allowedAssetNames[$assetName] = $true
}

foreach ($asset in $assets) {
  if (-not $allowedAssetNames.ContainsKey([string]$asset.name)) {
    throw "Unexpected release asset: $($asset.name)"
  }
}

$remoteDir = Join-Path $repoRoot "output/release/remote-$Version"
New-Item -ItemType Directory -Force -Path $remoteDir | Out-Null

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
