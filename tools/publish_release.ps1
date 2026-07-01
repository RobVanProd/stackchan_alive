param(
  [string]$Version,
  [string]$Repo = "",
  [switch]$CreateTag,
  [switch]$PushTag,
  [switch]$AllowExistingRelease,
  [switch]$AllowDirtyPackage,
  [switch]$DryRun
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

function Invoke-Checked {
  param(
    [string]$Description,
    [scriptblock]$Command
  )

  & $Command
  if ($LASTEXITCODE -ne 0) {
    throw "$Description failed with exit code $LASTEXITCODE"
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

$packageRoot = Join-Path $repoRoot "output/release/$Version"
$zipPath = Join-Path $repoRoot "output/release/stackchan_alive_$Version.zip"

if (-not (Test-Path -LiteralPath $packageRoot)) {
  throw "Missing package directory: $packageRoot. Run tools/package_release.ps1 first."
}

if (-not (Test-Path -LiteralPath $zipPath)) {
  throw "Missing release ZIP: $zipPath. Run tools/package_release.ps1 first."
}

$tagCommit = ""
$tagProbe = git rev-parse -q --verify "refs/tags/$Version^{commit}" 2>$null
if ($LASTEXITCODE -eq 0) {
  $tagCommit = ($tagProbe | Out-String).Trim()
} elseif ($CreateTag) {
  if ($DryRun) {
    $tagCommit = (git rev-parse HEAD).Trim()
    Write-Host "Dry run: git tag -a $Version -m $Version"
  } else {
    Invoke-Checked "Create tag $Version" { git tag -a $Version -m $Version }
    $tagCommit = (git rev-list -n 1 $Version).Trim()
  }
} elseif ($DryRun) {
  $tagCommit = (git rev-parse HEAD).Trim()
  Write-Warning "Dry run: using HEAD as expected commit because local tag $Version does not exist."
} else {
  throw "Missing local tag $Version. Create it first or pass -CreateTag."
}

if ($PushTag) {
  if ($DryRun) {
    Write-Host "Dry run: git push origin $Version"
  } else {
    Invoke-Checked "Push tag $Version" { git push origin $Version }
  }
}

$verifyArgs = @{
  Version = $Version
  ZipPath = $zipPath
  ExpectedCommit = $tagCommit
}
if ($AllowDirtyPackage) {
  $verifyArgs.AllowDirtyPackage = $true
}
& (Join-Path $PSScriptRoot "verify_release_package.ps1") @verifyArgs

$releaseExists = $false
if (-not $DryRun) {
  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $null = gh release view $Version --repo $Repo 2>$null
    $releaseViewExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
  if ($releaseViewExitCode -eq 0) {
    $releaseExists = $true
  }
}

if ($releaseExists -and -not $AllowExistingRelease) {
  throw "GitHub release already exists for $Version. Pass -AllowExistingRelease to verify the published ZIP."
}

if (-not $releaseExists) {
  $stageDir = Join-Path $repoRoot "output/release/manual-publish-$Version"
  if (Test-Path -LiteralPath $stageDir) {
    Remove-Item -LiteralPath $stageDir -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $stageDir | Out-Null

  $displayFirmware = Join-Path $packageRoot "firmware/display_only/firmware.bin"
  $servoFirmware = Join-Path $packageRoot "firmware/servo_calibration/firmware.bin"
  $bootloader = Join-Path $packageRoot "firmware/display_only/bootloader.bin"
  $partitions = Join-Path $packageRoot "firmware/display_only/partitions.bin"

  Copy-Item -LiteralPath $displayFirmware -Destination (Join-Path $stageDir "firmware-display-only.bin")
  Copy-Item -LiteralPath $servoFirmware -Destination (Join-Path $stageDir "firmware-servo-calibration.bin")
  Copy-Item -LiteralPath $bootloader -Destination (Join-Path $stageDir "bootloader.bin")
  Copy-Item -LiteralPath $partitions -Destination (Join-Path $stageDir "partitions.bin")

  if ($DryRun) {
    Write-Host "Dry run: gh release create $Version with package, preview media, and firmware assets staged in $stageDir"
  } else {
    Invoke-Checked "Create GitHub release $Version" {
    gh release create $Version `
      $zipPath `
      (Join-Path $packageRoot "media/stackchan_alive_preview.png") `
      (Join-Path $packageRoot "media/stackchan_alive_preview.mp4") `
      (Join-Path $packageRoot "media/stackchan_alive_preview.gif") `
      (Join-Path $stageDir "firmware-display-only.bin") `
      (Join-Path $stageDir "firmware-servo-calibration.bin") `
      (Join-Path $stageDir "bootloader.bin") `
      (Join-Path $stageDir "partitions.bin") `
      --repo $Repo `
      --title "Stackchan Alive $Version" `
      --notes-file (Join-Path $packageRoot "RELEASE_NOTES.md") `
      --prerelease
    }
  }
}

$remoteDir = Join-Path $repoRoot "output/release/remote-$Version"
New-Item -ItemType Directory -Force -Path $remoteDir | Out-Null

if ($DryRun) {
  Write-Host "Dry run: would download and verify stackchan_alive_$Version.zip from https://github.com/$Repo/releases/tag/$Version"
  Write-Host "Release dry run passed:"
  Write-Host "https://github.com/$Repo/releases/tag/$Version"
  exit 0
}

Invoke-Checked "Download GitHub release ZIP $Version" {
  gh release download $Version --repo $Repo --pattern "stackchan_alive_$Version.zip" --dir $remoteDir --clobber
}

$remoteZip = Join-Path $remoteDir "stackchan_alive_$Version.zip"
$remoteVerifyArgs = @{
  Version = $Version
  ZipPath = $remoteZip
  ExpectedCommit = $tagCommit
}
& (Join-Path $PSScriptRoot "verify_release_package.ps1") @remoteVerifyArgs

Write-Host "Release published and verified:"
Write-Host "https://github.com/$Repo/releases/tag/$Version"
