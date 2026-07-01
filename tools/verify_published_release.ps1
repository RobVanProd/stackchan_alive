param(
  [string]$Version,
  [string]$Repo = "",
  [string]$PackageRoot = "",
  [string]$ZipPath = "",
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

Assert-File $PackageRoot
Assert-File $ZipPath

$release = gh release view $Version --repo $Repo --json url,isPrerelease,assets,tagName,targetCommitish | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
  throw "Unable to read GitHub release: $Version"
}

if ($release.tagName -ne $Version) {
  throw "Release tag mismatch: expected $Version, got $($release.tagName)"
}

if (-not $release.isPrerelease -and -not $AllowNonPrerelease) {
  throw "Release is not marked prerelease. Pass -AllowNonPrerelease only for hardware-validated releases."
}

$assets = @($release.assets)
$expectedAssets = @{
  "stackchan_alive_$Version.zip" = $ZipPath
  "stackchan_alive_preview.png" = (Join-Path $PackageRoot "media/stackchan_alive_preview.png")
  "stackchan_alive_preview.mp4" = (Join-Path $PackageRoot "media/stackchan_alive_preview.mp4")
  "stackchan_alive_preview.gif" = (Join-Path $PackageRoot "media/stackchan_alive_preview.gif")
  "firmware-display-only.bin" = (Join-Path $PackageRoot "firmware/display_only/firmware.bin")
  "firmware-servo-calibration.bin" = (Join-Path $PackageRoot "firmware/servo_calibration/firmware.bin")
  "bootloader.bin" = (Join-Path $PackageRoot "firmware/display_only/bootloader.bin")
  "partitions.bin" = (Join-Path $PackageRoot "firmware/display_only/partitions.bin")
}

foreach ($assetName in $expectedAssets.Keys) {
  Assert-Asset -Assets $assets -Name $assetName -ExpectedPath $expectedAssets[$assetName]
}

$remoteDir = Join-Path $repoRoot "output/release/remote-$Version"
New-Item -ItemType Directory -Force -Path $remoteDir | Out-Null

gh release download $Version --repo $Repo --pattern "stackchan_alive_$Version.zip" --dir $remoteDir --clobber
if ($LASTEXITCODE -ne 0) {
  throw "Failed to download published ZIP for $Version"
}

$remoteZip = Join-Path $remoteDir "stackchan_alive_$Version.zip"
& (Join-Path $PSScriptRoot "verify_release_package.ps1") -Version $Version -ZipPath $remoteZip -ExpectedCommit $ExpectedCommit

Write-Host "Published release verified:"
Write-Host $release.url
