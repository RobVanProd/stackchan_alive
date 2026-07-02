param(
  [string]$Version,
  [string]$Repo = "",
  [switch]$CreateTag,
  [switch]$PushTag,
  [switch]$PushCurrentBranch,
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

function Update-ReleaseArchive {
  param(
    [string]$PackageRoot,
    [string]$ZipPath,
    [string]$Version
  )

  $hashLines = Get-ChildItem -LiteralPath $PackageRoot -File -Recurse |
    Where-Object { $_.Name -ne "SHA256SUMS.txt" } |
    Sort-Object FullName |
    ForEach-Object {
      $relative = $_.FullName.Substring($PackageRoot.Length + 1).Replace("\", "/")
      $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName
      "$($hash.Hash.ToLowerInvariant())  $relative"
    }

  $hashLines | Set-Content -Path (Join-Path $PackageRoot "SHA256SUMS.txt") -Encoding ASCII

  if (Test-Path -LiteralPath $ZipPath) {
    Remove-Item -LiteralPath $ZipPath -Force
  }
  Compress-Archive -Path (Join-Path $PackageRoot "*") -DestinationPath $ZipPath

  $zipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ZipPath).Hash.ToLowerInvariant()
  "$zipHash  stackchan_alive_$Version.zip" | Set-Content -Path "$ZipPath.sha256" -Encoding ASCII
}

function Get-CurrentBranchPublishInfo {
  $branch = (git branch --show-current).Trim()
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($branch)) {
    throw "Unable to resolve current branch. Publish from a named branch so the Firmware workflow can be observed."
  }

  $upstream = (git rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>$null | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($upstream)) {
    throw "Current branch '$branch' has no upstream. Set an upstream or push it before publishing."
  }

  $parts = $upstream -split "/", 2
  if ($parts.Count -ne 2 -or [string]::IsNullOrWhiteSpace($parts[0]) -or [string]::IsNullOrWhiteSpace($parts[1])) {
    throw "Unable to parse upstream ref '$upstream' for branch '$branch'."
  }

  return [ordered]@{
    branch = $branch
    upstream = $upstream
    remote = $parts[0]
    remoteBranch = $parts[1]
  }
}

function Assert-CurrentBranchPublishedAtCommit {
  param(
    [string]$Commit,
    [switch]$PushBranch,
    [switch]$DryRun
  )

  $branchInfo = Get-CurrentBranchPublishInfo
  if ($PushBranch) {
    if ($DryRun) {
      Write-Host "Dry run: git push $($branchInfo.remote) $($branchInfo.branch):$($branchInfo.remoteBranch)"
    } else {
      Invoke-Checked "Push current branch $($branchInfo.branch) to $($branchInfo.upstream)" {
        git push $branchInfo.remote "$($branchInfo.branch):$($branchInfo.remoteBranch)"
      }
    }
  }

  if ($DryRun) {
    Write-Host "Dry run: would verify $($branchInfo.upstream) points at $Commit before creating/uploading release assets."
    return
  }

  $remoteRef = "refs/heads/$($branchInfo.remoteBranch)"
  $remoteLine = (git ls-remote $branchInfo.remote $remoteRef | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($remoteLine)) {
    throw "Unable to resolve remote branch $($branchInfo.upstream). Push the branch before publishing."
  }

  $remoteCommit = (($remoteLine -split "\s+")[0]).ToLowerInvariant()
  if ($remoteCommit -ne $Commit.ToLowerInvariant()) {
    throw "Remote branch $($branchInfo.upstream) points at $remoteCommit, not release commit $Commit. Push the branch first or pass -PushCurrentBranch."
  }
}

function Export-ActionsStatusWithRetry {
  param(
    [string]$Repo,
    [string]$Version,
    [string]$Commit,
    [string]$OutputDir
  )

  $exportScript = Join-Path $PSScriptRoot "export_github_actions_status.ps1"
  if (-not (Test-Path -LiteralPath $exportScript)) {
    throw "Missing Actions status exporter: $exportScript"
  }

  $deadline = (Get-Date).AddSeconds(60)
  $lastOutput = ""
  do {
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $exportScript -Repo $Repo -Version $Version -Commit $Commit -OutputDir $OutputDir 2>&1
    $exitCode = $LASTEXITCODE
    $lastOutput = ($output | Out-String)
    if ($exitCode -eq 0) {
      return
    }
    Start-Sleep -Seconds 5
  } while ((Get-Date) -lt $deadline)

  throw "Unable to export GitHub Actions status for $Commit. Last output:$([Environment]::NewLine)$lastOutput"
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
$zipSidecarPath = "$zipPath.sha256"

if (-not (Test-Path -LiteralPath $packageRoot)) {
  throw "Missing package directory: $packageRoot. Run tools/package_release.ps1 first."
}

if (-not (Test-Path -LiteralPath $zipPath)) {
  throw "Missing release ZIP: $zipPath. Run tools/package_release.ps1 first."
}

if (-not (Test-Path -LiteralPath $zipSidecarPath)) {
  $zipHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
  "$zipHash  $(Split-Path -Leaf $zipPath)" | Set-Content -Path $zipSidecarPath -Encoding ASCII
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

if ($PushTag -or $PushCurrentBranch) {
  Assert-CurrentBranchPublishedAtCommit -Commit $tagCommit -PushBranch:$PushCurrentBranch -DryRun:$DryRun
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
    Write-Host "Dry run: gh release create $Version with package, ZIP SHA256 sidecar, preview media, voice samples, and firmware assets staged in $stageDir"
  } else {
    Invoke-Checked "Create GitHub release $Version" {
    gh release create $Version `
      $zipPath `
      $zipSidecarPath `
      (Join-Path $packageRoot "media/stackchan_alive_preview.png") `
      (Join-Path $packageRoot "media/stackchan_alive_expression_sheet.png") `
      (Join-Path $packageRoot "media/stackchan_alive_preview.mp4") `
      (Join-Path $packageRoot "media/stackchan_alive_preview.gif") `
      (Join-Path $packageRoot "media/voice/stackchan_spark_greeting.wav") `
      (Join-Path $packageRoot "media/voice/stackchan_spark_thinking.wav") `
      (Join-Path $packageRoot "media/voice/stackchan_spark_safety.wav") `
      (Join-Path $packageRoot "media/voice/stackchan_spark_audition_warm_slow_greeting.wav") `
      (Join-Path $packageRoot "media/voice/stackchan_spark_audition_bright_robot_greeting.wav") `
      (Join-Path $packageRoot "media/voice/stackchan_spark_audition_bright_robot_greeting.mp3") `
      (Join-Path $packageRoot "media/voice/stackchan_spark_thinking.mp3") `
      (Join-Path $packageRoot "media/voice/rvc/RVC_AUDITION.html") `
      (Join-Path $packageRoot "media/voice/rvc/RVC_AUDITIONS.md") `
      (Join-Path $packageRoot "media/voice/rvc/RVC_AUDITIONS.json") `
      (Join-Path $packageRoot "media/voice/rvc/stackchan_rvc_neutral.wav") `
      (Join-Path $packageRoot "media/voice/rvc/stackchan_rvc_warm_slow.wav") `
      (Join-Path $packageRoot "media/voice/rvc/stackchan_rvc_bright_robot.wav") `
      (Join-Path $packageRoot "media/voice/rvc/stackchan_rvc_bright_robot.mp3") `
      (Join-Path $packageRoot "media/voice/rvc/stackchan_rvc_bright_robot_less_static.wav") `
      (Join-Path $packageRoot "media/voice/rvc/stackchan_rvc_bright_robot_sweet_vocoder.wav") `
      (Join-Path $packageRoot "media/voice/rvc/stackchan_rvc_bright_robot_soft_boops.wav") `
      (Join-Path $packageRoot "media/voice/rvc/stackchan_rvc_spark_boops.wav") `
      (Join-Path $packageRoot "media/voice/rvc/stackchan_rvc_high_character.wav") `
      (Join-Path $packageRoot "media/voice/rvc/stackchan_rvc_thinking_neutral.wav") `
      (Join-Path $packageRoot "media/voice/rvc/stackchan_rvc_thinking_neutral.mp3") `
      (Join-Path $packageRoot "media/voice/rvc/stackchan_rvc_safety_neutral.wav") `
      (Join-Path $packageRoot "media/voice/rvc/stackchan_rvc_safety_neutral.mp3") `
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

if ($DryRun) {
  Write-Host "Dry run: would verify published assets and downloaded ZIP from https://github.com/$Repo/releases/tag/$Version"
  Write-Host "Release dry run passed:"
  Write-Host "https://github.com/$Repo/releases/tag/$Version"
  exit 0
}

Export-ActionsStatusWithRetry -Repo $Repo -Version $Version -Commit $tagCommit -OutputDir $packageRoot
Update-ReleaseArchive -PackageRoot $packageRoot -ZipPath $zipPath -Version $Version

& (Join-Path $PSScriptRoot "verify_release_package.ps1") @verifyArgs

Invoke-Checked "Upload finalized release evidence $Version" {
  gh release upload $Version `
    $zipPath `
    $zipSidecarPath `
    (Join-Path $packageRoot "GITHUB_ACTIONS_STATUS.md") `
    (Join-Path $packageRoot "github_actions_status.json") `
    --repo $Repo `
    --clobber
}

$publishedVerifyArgs = @{
  Version = $Version
  Repo = $Repo
  PackageRoot = $packageRoot
  ZipPath = $zipPath
  ZipSidecarPath = $zipSidecarPath
  ExpectedCommit = $tagCommit
}
& (Join-Path $PSScriptRoot "verify_published_release.ps1") @publishedVerifyArgs

& (Join-Path $PSScriptRoot "audit_published_release.ps1") `
  -Version $Version `
  -Repo $Repo `
  -PackageRoot $packageRoot `
  -ZipPath $zipPath `
  -ZipSidecarPath $zipSidecarPath `
  -ExpectedCommit $tagCommit `
  -UploadToRelease

Write-Host "Release published and verified:"
Write-Host "https://github.com/$Repo/releases/tag/$Version"
