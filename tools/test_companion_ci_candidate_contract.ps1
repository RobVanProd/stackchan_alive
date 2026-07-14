param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$downloader = Join-Path $PSScriptRoot "download_companion_ci_candidate.ps1"
$powerShellCommand = Get-Command pwsh -ErrorAction SilentlyContinue
$powerShellHost = if ($null -ne $powerShellCommand) { $powerShellCommand.Source } else { (Get-Process -Id $PID).Path }
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("stackchan-companion-ci-candidate-" + [guid]::NewGuid().ToString("N"))
$sourceCommit = "1111111111111111111111111111111111111111"
$runId = 424242
$requiredJobs = @(
  "changes",
  "bridge-tests",
  "native-tests",
  "build",
  "companion-tests",
  "companion-platform-builds (android-apk)",
  "companion-platform-builds (desktop-windows)",
  "companion-platform-builds (desktop-macos)",
  "companion-platform-builds (desktop-linux)",
  "companion-android-emulator-smoke",
  "companion-release-evidence"
)
$requiredArtifacts = @(
  "companion-android-apks",
  "companion-android-emulator-smoke",
  "companion-desktop-windows",
  "companion-desktop-macos",
  "companion-desktop-linux",
  "companion-release-evidence"
)
$passCount = 0

function Get-Sha256 {
  param([string]$Path)
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Add-FixtureFile {
  param(
    [string]$Root,
    [string]$RelativePath,
    [string]$Content
  )

  $path = Join-Path $Root $RelativePath
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
  Set-Content -LiteralPath $path -Value $Content -Encoding UTF8
  return $path
}

function New-Fixture {
  param([string]$Name)

  $root = Join-Path $tempRoot $Name
  New-Item -ItemType Directory -Force -Path $root | Out-Null

  $run = [ordered]@{
    databaseId = $runId
    name = "Firmware"
    headSha = $sourceCommit
    headBranch = "codex/fixture"
    status = "completed"
    conclusion = "success"
    url = "https://example.invalid/actions/runs/$runId"
    event = "pull_request"
    createdAt = "2026-07-14T00:00:00Z"
    updatedAt = "2026-07-14T00:10:00Z"
    jobs = @($requiredJobs | ForEach-Object {
      [ordered]@{ name = $_; status = "completed"; conclusion = "success" }
    })
  }
  $run | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root "run.json") -Encoding UTF8

  $artifacts = [ordered]@{
    total_count = $requiredArtifacts.Count
    artifacts = @($requiredArtifacts | ForEach-Object {
      [ordered]@{
        id = 1000 + [array]::IndexOf($requiredArtifacts, $_)
        name = $_
        size_in_bytes = 1024
        expired = $false
      }
    })
  }
  $artifacts | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root "artifacts.json") -Encoding UTF8

  $downloadRoot = Join-Path $root "downloads"
  $androidDebug = Add-FixtureFile $downloadRoot "companion-android-apks/apk/debug/app-android-debug.apk" "fixture debug apk"
  $androidRelease = Add-FixtureFile $downloadRoot "companion-android-apks/apk/release/app-android-release.apk" "fixture release apk"
  $androidBundle = Add-FixtureFile $downloadRoot "companion-android-apks/bundle/release/app-android-release.aab" "fixture release aab"
  $windowsPackage = Add-FixtureFile $downloadRoot "companion-desktop-windows/package/Stackchan Companion-1.0.0.msi" "fixture windows package"
  $macosPackage = Add-FixtureFile $downloadRoot "companion-desktop-macos/package/Stackchan Companion-1.0.0.dmg" "fixture macos package"
  $linuxPackage = Add-FixtureFile $downloadRoot "companion-desktop-linux/package/stackchan-companion_1.0.0_amd64.deb" "fixture linux package"
  Add-FixtureFile $downloadRoot "companion-android-emulator-smoke/android_emulator_launch_smoke.json" '{"schema":"stackchan.android-emulator-launch-smoke.v1","status":"pass"}' | Out-Null

  $evidenceEntries = @(
    [ordered]@{ path = "ci/apk/debug/app-android-debug.apk"; name = "app-android-debug.apk"; bytes = (Get-Item $androidDebug).Length; sha256 = Get-Sha256 $androidDebug },
    [ordered]@{ path = "ci/apk/release/app-android-release.apk"; name = "app-android-release.apk"; bytes = (Get-Item $androidRelease).Length; sha256 = Get-Sha256 $androidRelease },
    [ordered]@{ path = "ci/bundle/release/app-android-release.aab"; name = "app-android-release.aab"; bytes = (Get-Item $androidBundle).Length; sha256 = Get-Sha256 $androidBundle },
    [ordered]@{ path = "ci/windows/Stackchan Companion-1.0.0.msi"; name = "Stackchan Companion-1.0.0.msi"; bytes = (Get-Item $windowsPackage).Length; sha256 = Get-Sha256 $windowsPackage },
    [ordered]@{ path = "ci/macos/Stackchan Companion-1.0.0.dmg"; name = "Stackchan Companion-1.0.0.dmg"; bytes = (Get-Item $macosPackage).Length; sha256 = Get-Sha256 $macosPackage },
    [ordered]@{ path = "ci/linux/stackchan-companion_1.0.0_amd64.deb"; name = "stackchan-companion_1.0.0_amd64.deb"; bytes = (Get-Item $linuxPackage).Length; sha256 = Get-Sha256 $linuxPackage }
  )
  $evidence = [ordered]@{
    schema = "stackchan.companion-release-evidence.v1"
    status = "complete"
    version = $sourceCommit
    commit = $sourceCommit
    pending = @()
    artifacts = @(
      [ordered]@{ kind = "android-apk"; status = "present"; entries = @($evidenceEntries[0..2]) },
      [ordered]@{ kind = "desktop-package"; status = "present"; entries = @($evidenceEntries[3..5]) }
    )
    androidSigning = [ordered]@{ signingProfile = "lab-debug-fallback" }
    androidBundleSigning = [ordered]@{ signingProfile = "lab-debug-fallback" }
    desktopPackageEvidence = [ordered]@{ status = "ready" }
  }
  $evidencePath = Add-FixtureFile $downloadRoot "companion-release-evidence/COMPANION_RELEASE_EVIDENCE.json" "placeholder"
  $evidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $evidencePath -Encoding UTF8
  Add-FixtureFile $downloadRoot "companion-release-evidence/COMPANION_RELEASE_EVIDENCE.md" "# Fixture evidence" | Out-Null

  return $root
}

function Invoke-Downloader {
  param(
    [string]$FixtureRoot,
    [string]$Name,
    [string]$Commit = $sourceCommit
  )

  $outDir = Join-Path $tempRoot "out-$Name"
  $oldPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = @(& $powerShellHost -NoProfile -File $downloader `
      -RunId $runId `
      -Repo "fixture/stackchan" `
      -Commit $Commit `
      -OutDir $outDir `
      -FixtureRoot $FixtureRoot `
      -Json 2>&1)
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldPreference
  }
  return [pscustomobject]@{
    exitCode = $exitCode
    output = ($output | Out-String).Trim()
    outDir = $outDir
  }
}

function Assert-Failed {
  param(
    [object]$Result,
    [string]$Pattern,
    [string]$Name
  )

  $matched = [regex]::IsMatch(
    [string]$Result.output,
    $Pattern,
    [System.Text.RegularExpressions.RegexOptions]::Singleline
  )
  if ($Result.exitCode -eq 0 -or -not $matched) {
    throw "$Name was not rejected as expected. Exit=$($Result.exitCode) Output=$($Result.output)"
  }
  $script:passCount++
  Write-Host "[PASS] $Name"
}

try {
  $workflowText = Get-Content -LiteralPath (Join-Path $repoRoot ".github/workflows/firmware.yml") -Raw
  if ($workflowText -notmatch [regex]::Escape('STACKCHAN_CI_SOURCE_SHA: ${{ github.event.pull_request.head.sha || github.sha }}')) {
    throw "Firmware workflow does not derive the exact PR branch-head source SHA."
  }
  $checkoutCount = [regex]::Matches($workflowText, 'uses:\s+actions/checkout@v7').Count
  $pinnedCheckoutCount = [regex]::Matches($workflowText, 'ref:\s+\$\{\{ env\.STACKCHAN_CI_SOURCE_SHA \}\}').Count
  if ($checkoutCount -lt 1 -or $pinnedCheckoutCount -ne $checkoutCount) {
    throw "Every Firmware workflow checkout must use STACKCHAN_CI_SOURCE_SHA: checkout=$checkoutCount pinned=$pinnedCheckoutCount."
  }
  if ([regex]::Matches($workflowText, '\$\{\{ github\.sha \}\}').Count -ne 0) {
    throw "Firmware workflow still records the PR merge SHA directly."
  }
  foreach ($pattern in @(
    '-Version "${{ env.STACKCHAN_CI_SOURCE_SHA }}"',
    '-Commit "${{ env.STACKCHAN_CI_SOURCE_SHA }}"',
    "test_companion_ci_candidate_contract.ps1"
  )) {
    if ($workflowText -notmatch [regex]::Escape($pattern)) {
      throw "Firmware workflow exact-source contract is missing: $pattern"
    }
  }
  $passCount++
  Write-Host "[PASS] Firmware workflow checks out and records the exact PR branch head"

  $readyFixture = New-Fixture "ready"
  $ready = Invoke-Downloader $readyFixture "ready"
  if ($ready.exitCode -ne 0) {
    throw "Complete exact-source candidate fixture failed: $($ready.output)"
  }
  $report = $ready.output | ConvertFrom-Json
  $manifest = Get-Content -LiteralPath (Join-Path $ready.outDir "COMPANION_CI_CANDIDATE.json") -Raw | ConvertFrom-Json
  if ([string]$report.status -ne "companion-ci-candidate-ready" -or
      [string]$manifest.sourceCommit -ne $sourceCommit -or
      @($manifest.jobs).Count -ne $requiredJobs.Count -or
      @($manifest.artifacts).Count -ne $requiredArtifacts.Count -or
      [bool]$manifest.publicReleaseReady -or
      [bool]$manifest.substitutesForTaggedRelease -or
      [bool]$manifest.substitutesForPhysicalEvidence) {
    throw "Ready candidate manifest did not preserve exact-source scope and limitations."
  }
  $passCount++
  Write-Host "[PASS] complete exact-source CI candidate is accepted and inventoried"

  $mergeMismatch = Invoke-Downloader $readyFixture "merge-mismatch" "2222222222222222222222222222222222222222"
  Assert-Failed $mergeMismatch "source mismatch" "PR merge/head source mismatch is rejected"

  $failedJobFixture = New-Fixture "failed-job"
  $failedRunPath = Join-Path $failedJobFixture "run.json"
  $failedRun = Get-Content -LiteralPath $failedRunPath -Raw | ConvertFrom-Json
  $failedRun.jobs[4].conclusion = "failure"
  $failedRun | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $failedRunPath -Encoding UTF8
  Assert-Failed (Invoke-Downloader $failedJobFixture "failed-job") "not successful" "failed companion job is rejected"

  $missingArtifactFixture = New-Fixture "missing-artifact"
  $missingArtifactsPath = Join-Path $missingArtifactFixture "artifacts.json"
  $missingArtifacts = Get-Content -LiteralPath $missingArtifactsPath -Raw | ConvertFrom-Json
  $missingArtifacts.artifacts = @($missingArtifacts.artifacts | Where-Object name -ne "companion-desktop-macos")
  $missingArtifacts | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $missingArtifactsPath -Encoding UTF8
  Assert-Failed (Invoke-Downloader $missingArtifactFixture "missing-artifact") "companion-desktop-macos.*found 0" "missing platform artifact is rejected"

  $expiredArtifactFixture = New-Fixture "expired-artifact"
  $expiredArtifactsPath = Join-Path $expiredArtifactFixture "artifacts.json"
  $expiredArtifacts = Get-Content -LiteralPath $expiredArtifactsPath -Raw | ConvertFrom-Json
  @($expiredArtifacts.artifacts | Where-Object name -eq "companion-android-apks")[0].expired = $true
  $expiredArtifacts | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $expiredArtifactsPath -Encoding UTF8
  Assert-Failed (Invoke-Downloader $expiredArtifactFixture "expired-artifact") "has expired" "expired candidate artifact is rejected"

  $staleEvidenceFixture = New-Fixture "stale-evidence"
  $staleEvidencePath = Join-Path $staleEvidenceFixture "downloads/companion-release-evidence/COMPANION_RELEASE_EVIDENCE.json"
  $staleEvidence = Get-Content -LiteralPath $staleEvidencePath -Raw | ConvertFrom-Json
  $staleEvidence.commit = "3333333333333333333333333333333333333333"
  $staleEvidence | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $staleEvidencePath -Encoding UTF8
  Assert-Failed (Invoke-Downloader $staleEvidenceFixture "stale-evidence") "release evidence source mismatch" "stale embedded release evidence is rejected"

  $tamperedFixture = New-Fixture "tampered-download"
  Set-Content -LiteralPath (Join-Path $tamperedFixture "downloads/companion-android-apks/apk/release/app-android-release.apk") -Value "tampered fixture release apk" -Encoding UTF8
  Assert-Failed (Invoke-Downloader $tamperedFixture "tampered-download") "does not match companion release evidence" "downloaded artifact hash tampering is rejected"
} finally {
  Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Companion CI candidate contract tests passed: $passCount"
exit 0
