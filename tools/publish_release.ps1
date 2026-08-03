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

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$publishRepoRoot = $repoRoot
$publishGitCommand = Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue |
  Select-Object -First 1
if ($null -eq $publishGitCommand) {
  throw 'Release publishing requires a Git application executable; functions, aliases, and scripts are refused.'
}
$publishGitExecutable = (Resolve-Path -LiteralPath ([string]$publishGitCommand.Source)).Path
$publishPowerShellCommand = Get-Command -Name powershell.exe -CommandType Application -ErrorAction SilentlyContinue |
  Select-Object -First 1
if ($null -eq $publishPowerShellCommand) {
  throw 'Release publishing requires a Windows PowerShell application executable; functions, aliases, and scripts are refused.'
}
$publishPowerShellExecutable = (
  Resolve-Path -LiteralPath ([string]$publishPowerShellCommand.Source)).Path
$publishGitDisabledHooksPath = Join-Path $repoRoot (
  "output/private/disabled-publish-git-hooks-$PID-" + [guid]::NewGuid().ToString('N'))
$publishNullAttributesPath = if ($env:OS -eq 'Windows_NT') { 'NUL' } else { '/dev/null' }
if (Test-Path -LiteralPath $publishGitDisabledHooksPath) {
  throw "Publication Git disabled-hooks sentinel unexpectedly exists: $publishGitDisabledHooksPath"
}

function Invoke-PublishTrustedGit {
  param([Parameter(Mandatory = $true)][string[]]$Arguments)

  if (Test-Path -LiteralPath $script:publishGitDisabledHooksPath) {
    throw "Publication Git disabled-hooks path must not exist: $script:publishGitDisabledHooksPath"
  }
  $gitTrustArguments = @(
    '-c', "core.hooksPath=$script:publishGitDisabledHooksPath",
    '-c', 'core.fsmonitor=false',
    '-c', 'core.untrackedCache=false',
    '-c', 'core.useBuiltinFSMonitor=false',
    '-c', 'maintenance.auto=false',
    '-c', 'core.autocrlf=true',
    '-c', "core.attributesFile=$script:publishNullAttributesPath",
    '-c', 'filter.lfs.process=',
    '-c', 'filter.lfs.clean=',
    '-c', 'filter.lfs.smudge=',
    '-c', 'filter.lfs.required=false',
    '-C', $script:publishRepoRoot
  )
  $gitTrustArguments += $Arguments

  $previousNoReplaceObjects = $env:GIT_NO_REPLACE_OBJECTS
  $previousNoSystemAttributes = $env:GIT_ATTR_NOSYSTEM
  try {
    [Environment]::SetEnvironmentVariable(
      'GIT_NO_REPLACE_OBJECTS', '1', [EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable(
      'GIT_ATTR_NOSYSTEM', '1', [EnvironmentVariableTarget]::Process)
    & $script:publishGitExecutable @gitTrustArguments
  } finally {
    [Environment]::SetEnvironmentVariable(
      'GIT_NO_REPLACE_OBJECTS', $previousNoReplaceObjects, [EnvironmentVariableTarget]::Process)
    [Environment]::SetEnvironmentVariable(
      'GIT_ATTR_NOSYSTEM', $previousNoSystemAttributes, [EnvironmentVariableTarget]::Process)
  }
}

function Assert-SafeReleaseVersionLeaf {
  param([Parameter(Mandatory = $true)][string]$Value)

  if ($Value.Length -gt 128 -or
      $Value -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or
      $Value -in @('.', '..') -or
      $Value.EndsWith('.', [System.StringComparison]::Ordinal)) {
    throw "Version must be one safe filename component containing only letters, digits, '.', '_', or '-'."
  }
}

function Assert-SafeGitHubRepositoryName {
  param([Parameter(Mandatory = $true)][string]$Value)

  if ($Value.Length -gt 201 -or
      $Value -notmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}/[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$') {
    throw "GitHub repository must be an explicit owner/name value containing only letters, digits, '.', '_', or '-'."
  }
  $components = @($Value -split '/', 2)
  if ($components.Count -ne 2 -or $components[0] -in @('.', '..') -or
      $components[1] -in @('.', '..') -or $components[0].EndsWith('.') -or
      $components[1].EndsWith('.')) {
    throw 'GitHub repository owner/name is not canonical.'
  }
}

function Get-SafeReleaseChildPath {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][string]$RelativePath
  )

  $resolvedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
  $resolvedChild = [System.IO.Path]::GetFullPath((Join-Path $resolvedRoot $RelativePath))
  $expectedPrefix = $resolvedRoot + [System.IO.Path]::DirectorySeparatorChar
  if (-not $resolvedChild.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Release path escapes its trusted root: $resolvedChild"
  }
  return $resolvedChild
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

function Clear-TransientPackageOutput {
  param([string]$PackageRoot)

  $transientOutput = Join-Path $PackageRoot "output"
  if (-not (Test-Path -LiteralPath $transientOutput)) {
    return
  }

  $resolvedPackageRoot = (Resolve-Path $PackageRoot).Path
  $resolvedTransientOutput = (Resolve-Path $transientOutput).Path
  $expectedPrefix = $resolvedPackageRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  if (-not $resolvedTransientOutput.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean transient package output outside package root: $resolvedTransientOutput"
  }

  # open_voice_audition.cmd -All writes output/voice_auditions/VOICE_AUDITION_INDEX.html for local review.
  # Package-local output/ is transient and must not enter the finalized ZIP or SHA256SUMS.txt.
  Remove-Item -LiteralPath $resolvedTransientOutput -Recurse -Force
}

function Update-ReleaseArchive {
  param(
    [string]$PackageRoot,
    [string]$ZipPath,
    [string]$Version
  )

  Clear-TransientPackageOutput -PackageRoot $PackageRoot

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
  $branch = (Invoke-PublishTrustedGit -Arguments @('branch', '--show-current') | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($branch)) {
    throw "Unable to resolve current branch. Publish from a named branch so the Firmware workflow can be observed."
  }

  $upstream = (Invoke-PublishTrustedGit -Arguments @(
      'rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}') 2>$null | Out-String).Trim()
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
        Invoke-PublishTrustedGit -Arguments @(
          'push', $branchInfo.remote, "$($branchInfo.branch):$($branchInfo.remoteBranch)")
      }
    }
  }

  if ($DryRun) {
    Write-Host "Dry run: would verify $($branchInfo.upstream) points at $Commit before creating/uploading release assets."
    return
  }

  $remoteRef = "refs/heads/$($branchInfo.remoteBranch)"
  $remoteLine = (Invoke-PublishTrustedGit -Arguments @(
      'ls-remote', $branchInfo.remote, $remoteRef) | Out-String).Trim()
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
    $output = & $script:publishPowerShellExecutable -NoProfile -ExecutionPolicy Bypass `
      -File $exportScript -Repo $Repo -Version $Version -Commit $Commit -OutputDir $OutputDir 2>&1
    $exitCode = $LASTEXITCODE
    $lastOutput = ($output | Out-String)
    if ($exitCode -eq 0) {
      return
    }
    Start-Sleep -Seconds 5
  } while ((Get-Date) -lt $deadline)

  throw "Unable to export GitHub Actions status for $Commit. Last output:$([Environment]::NewLine)$lastOutput"
}

function Assert-RemoteTagPublishedAtCommit {
  param(
    [Parameter(Mandatory = $true)][string]$Tag,
    [Parameter(Mandatory = $true)][string]$Commit,
    [string]$Remote = 'origin'
  )

  $tagRef = "refs/tags/$Tag"
  $peeledRef = "$tagRef^{}"
  $remoteLines = @(Invoke-PublishTrustedGit -Arguments @(
      'ls-remote', $Remote, $tagRef, $peeledRef))
  if ($LASTEXITCODE -ne 0) {
    throw "Unable to resolve remote tag $Remote/$Tag before release mutation."
  }
  $resolved = New-Object System.Collections.Generic.List[string]
  foreach ($line in $remoteLines) {
    if ([string]$line -match '^([0-9a-fA-F]{40})\s+(.+)$') {
      $resolved.Add("$($Matches[1].ToLowerInvariant())`t$($Matches[2])")
    }
  }
  $peeled = @($resolved | Where-Object { $_.EndsWith("`t$peeledRef", [System.StringComparison]::Ordinal) })
  $direct = @($resolved | Where-Object { $_.EndsWith("`t$tagRef", [System.StringComparison]::Ordinal) })
  $remoteCommit = if ($peeled.Count -eq 1) {
    ($peeled[0] -split "`t", 2)[0]
  } elseif ($peeled.Count -eq 0 -and $direct.Count -eq 1) {
    ($direct[0] -split "`t", 2)[0]
  } else {
    ''
  }
  if ($remoteCommit -cne $Commit.ToLowerInvariant()) {
    throw "Remote tag $Remote/$Tag resolves to '$remoteCommit', not verified release commit $Commit. Push the exact tag before publishing."
  }
}

function New-VerifiedReleaseTag {
  param(
    [Parameter(Mandatory = $true)][string]$Tag,
    [Parameter(Mandatory = $true)][string]$Commit
  )

  Invoke-Checked "Create tag $Tag at verified commit $Commit" {
    Invoke-PublishTrustedGit -Arguments @('tag', '-a', $Tag, $Commit, '-m', $Tag)
  }
  $createdTagCommit = (Invoke-PublishTrustedGit -Arguments @(
      'rev-list', '-n', '1', $Tag) | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or $createdTagCommit -cne $Commit) {
    Invoke-PublishTrustedGit -Arguments @('tag', '-d', $Tag) 2>$null | Out-Null
    throw "Created tag $Tag does not resolve to the package-verified commit $Commit; the newly created tag was removed."
  }
}

function Invoke-OperationalPackageVerification {
  param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$ZipPath,
    [Parameter(Mandatory = $true)][string]$ExpectedCommit,
    [switch]$AllowDirtyPackage
  )

  $arguments = @{
    Version = $Version
    ZipPath = $ZipPath
    ExpectedCommit = $ExpectedCommit
    RequireReleaseEligible = $true
  }
  if ($AllowDirtyPackage) {
    $arguments.AllowDirtyPackage = $true
  }
  & (Join-Path $PSScriptRoot "verify_release_package.ps1") @arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Operational release package verification failed with exit code $LASTEXITCODE."
  }
}

function New-VerifiedPublicationSnapshot {
  param(
    [Parameter(Mandatory = $true)][string]$Version,
    [Parameter(Mandatory = $true)][string]$ZipPath,
    [Parameter(Mandatory = $true)][string]$ZipSidecarPath,
    [Parameter(Mandatory = $true)][string]$ExpectedCommit,
    [switch]$AllowDirtyPackage
  )

  $tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
  $snapshotRoot = Join-Path $tempBase ("stackchan-publish-$PID-" + [guid]::NewGuid().ToString('N'))
  $snapshotZip = Join-Path $snapshotRoot "stackchan_alive_$Version.zip"
  $snapshotSidecar = "$snapshotZip.sha256"
  $snapshotPackage = Join-Path $snapshotRoot "package"
  try {
    New-Item -ItemType Directory -Path $snapshotRoot | Out-Null
    Copy-Item -LiteralPath $ZipPath -Destination $snapshotZip
    Copy-Item -LiteralPath $ZipSidecarPath -Destination $snapshotSidecar

    Invoke-OperationalPackageVerification `
      -Version $Version `
      -ZipPath $snapshotZip `
      -ExpectedCommit $ExpectedCommit `
      -AllowDirtyPackage:$AllowDirtyPackage | Out-Host
    Expand-StackchanReleaseZipSafely -ZipPath $snapshotZip -DestinationPath $snapshotPackage

    return [pscustomobject]@{
      Root = $snapshotRoot
      ZipPath = $snapshotZip
      ZipSidecarPath = $snapshotSidecar
      PackageRoot = $snapshotPackage
    }
  } catch {
    if (Test-Path -LiteralPath $snapshotRoot) {
      $resolvedSnapshot = (Resolve-Path -LiteralPath $snapshotRoot).Path
      $tempPrefix = $tempBase + [System.IO.Path]::DirectorySeparatorChar
      if (-not $resolvedSnapshot.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean unexpected publication snapshot: $resolvedSnapshot"
      }
      Remove-Item -LiteralPath $resolvedSnapshot -Recurse -Force
    }
    throw
  }
}

function Remove-VerifiedPublicationSnapshot {
  param([Parameter(Mandatory = $true)][string]$SnapshotRoot)

  if (-not (Test-Path -LiteralPath $SnapshotRoot)) {
    return
  }
  $tempBase = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\', '/')
  $resolvedSnapshot = (Resolve-Path -LiteralPath $SnapshotRoot).Path
  $tempPrefix = $tempBase + [System.IO.Path]::DirectorySeparatorChar
  if (-not $resolvedSnapshot.StartsWith($tempPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
      (Split-Path -Leaf $resolvedSnapshot) -notmatch '^stackchan-publish-[0-9]+-[0-9a-f]{32}$') {
    throw "Refusing to clean unexpected publication snapshot: $resolvedSnapshot"
  }
  Remove-Item -LiteralPath $resolvedSnapshot -Recurse -Force
}

if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = (Invoke-PublishTrustedGit -Arguments @(
      'describe', '--tags', '--always', '--dirty') | Out-String).Trim()
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Version)) {
    throw "Unable to infer a release version from the trusted source checkout."
  }
}
Assert-SafeReleaseVersionLeaf -Value $Version
if (-not [string]::IsNullOrWhiteSpace($Repo)) {
  Assert-SafeGitHubRepositoryName -Value $Repo
}

$releaseOutputRoot = Get-SafeReleaseChildPath -Root $repoRoot -RelativePath "output/release"
$packageRoot = Get-SafeReleaseChildPath -Root $releaseOutputRoot -RelativePath $Version
$zipPath = Get-SafeReleaseChildPath -Root $releaseOutputRoot -RelativePath "stackchan_alive_$Version.zip"
$zipSidecarPath = Get-SafeReleaseChildPath -Root $releaseOutputRoot -RelativePath "stackchan_alive_$Version.zip.sha256"

if (-not (Test-Path -LiteralPath $packageRoot -PathType Container)) {
  throw "Missing package directory: $packageRoot. Run tools/package_release.ps1 first."
}
if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) {
  throw "Missing release ZIP: $zipPath. Run tools/package_release.ps1 first."
}
if (-not (Test-Path -LiteralPath $zipSidecarPath -PathType Leaf)) {
  throw "Missing release ZIP SHA-256 sidecar: $zipSidecarPath. Rebuild the package; publishing will not create evidence for an unverified ZIP."
}

$tagCommit = ""
$tagNeedsCreation = $false
$tagProbe = Invoke-PublishTrustedGit -Arguments @(
  'rev-parse', '-q', '--verify', "refs/tags/$Version^{commit}") 2>$null
if ($LASTEXITCODE -eq 0) {
  $tagCommit = ($tagProbe | Out-String).Trim()
} elseif ($CreateTag) {
  $tagCommit = (Invoke-PublishTrustedGit -Arguments @('rev-parse', 'HEAD') | Out-String).Trim()
  $tagNeedsCreation = $true
} elseif ($DryRun) {
  $tagCommit = (Invoke-PublishTrustedGit -Arguments @('rev-parse', 'HEAD') | Out-String).Trim()
  Write-Warning "Dry run: using HEAD as expected commit because local tag $Version does not exist."
} else {
  throw "Missing local tag $Version. Create it first or pass -CreateTag."
}
if ($LASTEXITCODE -ne 0 -or $tagCommit -notmatch '^[0-9a-fA-F]{40}$') {
  throw "Unable to resolve a full release commit for $Version."
}
$tagCommit = $tagCommit.ToLowerInvariant()

if ($DryRun) {
  Write-Host "Dry run: verified parameters and local Git authority only; no package verifier, network command, filesystem mutation, tag, push, snapshot, extraction, staging, or publication was performed."
  Write-Host "Dry run: version=$Version commit=$tagCommit repository=$repoRoot"
  if ($tagNeedsCreation) {
    Write-Host "Dry run: would create annotated tag $Version explicitly at $tagCommit."
  }
  if ($PushCurrentBranch) {
    Write-Host "Dry run: would validate and push the current branch only after exact package verification."
  }
  if ($PushTag) {
    Write-Host "Dry run: would push tag $Version only after exact package verification."
  }
  $repoDescription = if ([string]::IsNullOrWhiteSpace($Repo)) { '<resolve with GitHub CLI during real publication>' } else { $Repo }
  Write-Host "Dry run: would publish the reverified final asset set to $repoDescription."
  return
}

if ([string]::IsNullOrWhiteSpace($Repo)) {
  throw 'Real publication requires explicit -Repo owner/name; ambient GitHub CLI repository inference is refused.'
}

# Nothing derived from Version is created, tagged, pushed, queried remotely, or exposed until
# the source-side verifier has accepted the exact candidate ZIP as release eligible.
Invoke-OperationalPackageVerification `
  -Version $Version `
  -ZipPath $zipPath `
  -ExpectedCommit $tagCommit `
  -AllowDirtyPackage:$AllowDirtyPackage
. (Join-Path $PSScriptRoot "release_asset_contract.ps1")
. (Join-Path $PSScriptRoot "release_zip_safety.ps1")

$publishGitHubCommand = Get-Command -Name gh -CommandType Application -ErrorAction SilentlyContinue |
  Select-Object -First 1
if ($null -eq $publishGitHubCommand) {
  throw 'Release publishing requires a GitHub CLI application executable; functions, aliases, and scripts are refused.'
}
$publishGitHubExecutable = (Resolve-Path -LiteralPath ([string]$publishGitHubCommand.Source)).Path

# GitHub Actions status is release content. Mutating it invalidates the first verification,
# so the archive and sidecar are rebuilt and verified again before anything is staged.
if (-not $DryRun) {
  Export-ActionsStatusWithRetry -Repo $Repo -Version $Version -Commit $tagCommit -OutputDir $packageRoot
  Update-ReleaseArchive -PackageRoot $packageRoot -ZipPath $zipPath -Version $Version
  Invoke-OperationalPackageVerification `
    -Version $Version `
    -ZipPath $zipPath `
    -ExpectedCommit $tagCommit `
    -AllowDirtyPackage:$AllowDirtyPackage
}

$snapshot = New-VerifiedPublicationSnapshot `
  -Version $Version `
  -ZipPath $zipPath `
  -ZipSidecarPath $zipSidecarPath `
  -ExpectedCommit $tagCommit `
  -AllowDirtyPackage:$AllowDirtyPackage
try {
  $publishedPackageRoot = $snapshot.PackageRoot
  $publishedZipPath = $snapshot.ZipPath
  $publishedZipSidecarPath = $snapshot.ZipSidecarPath
  $stageDir = Join-Path $snapshot.Root "firmware-assets"
  New-Item -ItemType Directory -Path $stageDir | Out-Null

  Copy-Item -LiteralPath (Join-Path $publishedPackageRoot "firmware/display_only/firmware.bin") -Destination (Join-Path $stageDir "firmware-display-only.bin")
  Copy-Item -LiteralPath (Join-Path $publishedPackageRoot "firmware/servo_calibration/firmware.bin") -Destination (Join-Path $stageDir "firmware-servo-calibration.bin")
  Copy-Item -LiteralPath (Join-Path $publishedPackageRoot "firmware/display_only/bootloader.bin") -Destination (Join-Path $stageDir "bootloader.bin")
  Copy-Item -LiteralPath (Join-Path $publishedPackageRoot "firmware/display_only/partitions.bin") -Destination (Join-Path $stageDir "partitions.bin")

  Write-Host "Verify finalized release asset contract against the safe extraction of the exact verified ZIP."
  & (Join-Path $PSScriptRoot "verify_release_asset_contract.ps1") `
    -Version $Version `
    -PackageRoot $publishedPackageRoot `
    -ZipPath $publishedZipPath `
    -ZipSidecarPath $publishedZipSidecarPath `
    -FirmwareAssetRoot $stageDir `
    -FirmwareAssetPathMode Stage

  $finalReleaseAssetEntries = Get-ReleaseFinalAssetEntries -Version $Version -PackageRoot $publishedPackageRoot -ZipPath $publishedZipPath -ZipSidecarPath $publishedZipSidecarPath -FirmwareAssetRoot $stageDir -FirmwareAssetPathMode Stage
  $finalReleaseAssets = @($finalReleaseAssetEntries | ForEach-Object { $_.Path })

  $releaseExists = $false
  if (-not $DryRun) {
    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
      $null = & $script:publishGitHubExecutable release view $Version --repo $Repo 2>$null
      $releaseViewExitCode = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $oldErrorActionPreference
    }
    if ($releaseViewExitCode -eq 0) {
      $releaseExists = $true
    }
  }
  if ($releaseExists -and -not $AllowExistingRelease) {
    throw "GitHub release already exists for $Version. Pass -AllowExistingRelease to replace only the verified final asset set."
  }

  if ($tagNeedsCreation) {
    New-VerifiedReleaseTag -Tag $Version -Commit $tagCommit
  }

  if ($PushTag -or $PushCurrentBranch) {
    Assert-CurrentBranchPublishedAtCommit -Commit $tagCommit -PushBranch:$PushCurrentBranch -DryRun:$DryRun
  }
  if ($PushTag) {
    Invoke-Checked "Push tag $Version" {
      Invoke-PublishTrustedGit -Arguments @(
        'push', 'origin', "refs/tags/$Version:refs/tags/$Version")
    }
  }

  if ($DryRun) {
    Write-Host "Dry run: would publish only assets staged from $publishedPackageRoot and the exact reverified ZIP $publishedZipPath."
    Write-Host "Dry run: would verify published assets from https://github.com/$Repo/releases/tag/$Version"
  } else {
    Assert-RemoteTagPublishedAtCommit `
      -Tag $Version `
      -Commit $tagCommit `
      -Remote "https://github.com/$Repo.git"
  }
  if ($DryRun) {
    # The dry-run message above is the terminal publication action.
  } elseif (-not $releaseExists) {
    Invoke-Checked "Create GitHub release $Version" {
      & $script:publishGitHubExecutable release create $Version `
        @finalReleaseAssets `
        --repo $Repo `
        --target $tagCommit `
        --title "Stackchan: Alive $Version" `
        --notes-file (Join-Path $publishedPackageRoot "RELEASE_NOTES.md") `
        --prerelease
    }
  } else {
    Invoke-Checked "Upload finalized release evidence $Version" {
      & $script:publishGitHubExecutable release upload $Version `
        @finalReleaseAssets `
        --repo $Repo `
        --clobber
    }
  }

  if (-not $DryRun) {
    $publishedVerifyArgs = @{
      Version = $Version
      Repo = $Repo
      PackageRoot = $publishedPackageRoot
      ZipPath = $publishedZipPath
      ZipSidecarPath = $publishedZipSidecarPath
      ExpectedCommit = $tagCommit
    }
    & (Join-Path $PSScriptRoot "verify_published_release.ps1") @publishedVerifyArgs

    & (Join-Path $PSScriptRoot "audit_published_release.ps1") `
      -Version $Version `
      -Repo $Repo `
      -PackageRoot $publishedPackageRoot `
      -ZipPath $publishedZipPath `
      -ZipSidecarPath $publishedZipSidecarPath `
      -ExpectedCommit $tagCommit `
      -UploadToRelease

    Write-Host "Release published and verified:"
    Write-Host "https://github.com/$Repo/releases/tag/$Version"
  } else {
    Write-Host "Release dry run passed without creating, pushing, or uploading anything."
  }
} finally {
  Remove-VerifiedPublicationSnapshot -SnapshotRoot $snapshot.Root
}
