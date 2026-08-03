$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
. (Join-Path $PSScriptRoot "firmware_reproducibility_proof.ps1")

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
  "stackchan-repro-proof-contract-" + [guid]::NewGuid().ToString("N"))
$commit = "1" * 40
$epoch = "1700000000"
$status = "test-ready prerelease; hardware validation pending"

function Copy-Proof {
  param([object]$Value)
  return ($Value | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
}

function Invoke-ExpectedProofFailure {
  param(
    [Parameter(Mandatory = $true)][scriptblock]$Mutation,
    [Parameter(Mandatory = $true)][string]$Marker
  )

  $candidate = Copy-Proof $script:validProof
  & $Mutation $candidate
  try {
    Assert-StackchanFirmwareReproducibilityProof `
      -Proof $candidate `
      -DiagnosticPackage $false `
      -AllowDirtyPackage $false `
      -ManifestCommit $script:commit `
      -SourceEpoch $script:epoch `
      -ManifestStatus $script:status `
      -PackageRoot $script:fixtureRoot
  } catch {
    if ($_.Exception.Message -notmatch [regex]::Escape($Marker)) {
      throw "Expected proof failure containing '$Marker', got: $($_.Exception.Message)"
    }
    return
  }
  throw "Expected proof failure containing '$Marker'"
}

try {
  $records = @()
  $attestations = @()
  $roots = [ordered]@{
    stackchan = "firmware/display_only"
    stackchan_servo_calibration = "firmware/servo_calibration"
    stackchan_release_full = "firmware/full_online"
  }
  # Preserve the required deterministic attestation order: all A, then all B.
  foreach ($cycle in @("cycle-a", "cycle-b")) {
    foreach ($environment in @($roots.Keys)) {
      $attestations += [ordered]@{
        cycle = $cycle
        environment = $environment
        sourceCommit = $commit
        sourceEpoch = $epoch
        preBuildChecked = $true
        postSnapshotChecked = $true
      }
    }
  }
  foreach ($environment in @($roots.Keys)) {
    $destination = Join-Path $fixtureRoot $roots[$environment]
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    foreach ($artifact in @("firmware.bin", "firmware.elf", "bootloader.bin", "partitions.bin", "boot_app0.bin")) {
      $path = Join-Path $destination $artifact
      [System.IO.File]::WriteAllText(
        $path,
        "$environment/$artifact`n",
        (New-Object System.Text.UTF8Encoding($false)))
      $item = Get-Item -LiteralPath $path
      $records += [ordered]@{
        environment = $environment
        artifact = $artifact
        bytes = [long]$item.Length
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToUpperInvariant()
      }
    }
  }

  $script:validProof = [ordered]@{
    status = "verified-two-clean-cycles"
    minimumClockBoundarySeconds = 65
    clockBoundarySeconds = 65
    cycleAStartedUtc = "2026-01-01T00:00:00Z"
    cycleBStartedUtc = "2026-01-01T00:01:05Z"
    cycleASourceCommit = $commit
    cycleASourceEpoch = $epoch
    cycleBSourceCommit = $commit
    cycleBSourceEpoch = $epoch
    buildCachePolicy = "isolated-empty-per-cycle-environment"
    sourceIsolationPolicy = "distinct-short-detached-clean-worktrees-pinned-to-source-commit-with-prefix-mapped-paths"
    identityAttestations = @($attestations)
    cycleAArtifacts = @(Copy-Proof $records)
    cycleBArtifacts = @(Copy-Proof $records)
  }
  $script:commit = $commit
  $script:epoch = $epoch
  $script:status = $status
  $script:fixtureRoot = $fixtureRoot

  Assert-StackchanFirmwareReproducibilityProof `
    -Proof $validProof -DiagnosticPackage $false -AllowDirtyPackage $false `
    -ManifestCommit $commit -SourceEpoch $epoch -ManifestStatus $status -PackageRoot $fixtureRoot

  Invoke-ExpectedProofFailure { param($p) $p.status = 'claimed' } "two-cycle firmware reproducibility proof"
  Invoke-ExpectedProofFailure { param($p) $p.minimumClockBoundarySeconds = 64 } "two-cycle firmware reproducibility proof"
  Invoke-ExpectedProofFailure { param($p) $p.cycleAArtifacts = @($p.cycleAArtifacts | Select-Object -First 14) } "15 artifacts"
  Invoke-ExpectedProofFailure { param($p) $p.cycleBArtifacts += (Copy-Proof $p.cycleBArtifacts[0]) } "15 artifacts"
  Invoke-ExpectedProofFailure { param($p) $p.cycleBArtifacts[1] = Copy-Proof $p.cycleBArtifacts[0] } "mismatch at artifact index"
  Invoke-ExpectedProofFailure { param($p) $p.cycleBArtifacts[0].bytes = [long]$p.cycleBArtifacts[0].bytes + 1 } "mismatch at artifact index"
  Invoke-ExpectedProofFailure { param($p) $p.cycleBArtifacts[0].sha256 = "0" * 64 } "mismatch at artifact index"
  Invoke-ExpectedProofFailure { param($p) $p.cycleAStartedUtc = "invalid" } "invalid cycle timestamps"
  Invoke-ExpectedProofFailure { param($p) $p.cycleBStartedUtc = "2025-12-31T23:59:59Z" } "clock boundary is inconsistent"
  Invoke-ExpectedProofFailure { param($p) $p.cycleBStartedUtc = "2026-01-01T00:01:04Z"; $p.clockBoundarySeconds = 64 } "two-cycle firmware reproducibility proof"
  Invoke-ExpectedProofFailure { param($p) $p.clockBoundarySeconds = 66 } "clock boundary is inconsistent"
  Invoke-ExpectedProofFailure { param($p) $p.identityAttestations = @($p.identityAttestations | Select-Object -First 5) } "six cycle/environment"
  Invoke-ExpectedProofFailure { param($p) $p.identityAttestations[1] = Copy-Proof $p.identityAttestations[0] } "invalid identity attestation"
  Invoke-ExpectedProofFailure { param($p) $p.identityAttestations[0].sourceCommit = "2" * 40 } "invalid identity attestation"
  Invoke-ExpectedProofFailure { param($p) $p.identityAttestations[0].sourceEpoch = "1700000001" } "invalid identity attestation"
  Invoke-ExpectedProofFailure { param($p) $p.identityAttestations[0].preBuildChecked = $false } "invalid identity attestation"
  Invoke-ExpectedProofFailure { param($p) $p.identityAttestations[0].postSnapshotChecked = $false } "invalid identity attestation"
  Invoke-ExpectedProofFailure { param($p) $p.cycleASourceCommit = "2" * 40 } "one manifest Git identity"
  Invoke-ExpectedProofFailure { param($p) $p.cycleBSourceCommit = "2" * 40 } "one manifest Git identity"
  Invoke-ExpectedProofFailure { param($p) $p.cycleASourceEpoch = "1700000001" } "one manifest Git identity"
  Invoke-ExpectedProofFailure { param($p) $p.cycleBSourceEpoch = "1700000001" } "one manifest Git identity"
  Invoke-ExpectedProofFailure { param($p) $p.buildCachePolicy = "shared-cache" } "isolated build-cache policy"
  Invoke-ExpectedProofFailure { param($p) $p.sourceIsolationPolicy = "same-worktree" } "distinct detached source policy"

  $packagedArtifact = Join-Path $fixtureRoot "firmware/display_only/firmware.bin"
  [System.IO.File]::AppendAllText($packagedArtifact, "changed")
  Invoke-ExpectedProofFailure { param($p) } "Packaged artifact does not match reproducibility cycle B"

  $diagnosticProof = [ordered]@{
    status = "not-proven-skip-build"
    minimumClockBoundarySeconds = 65
    clockBoundarySeconds = 0
    cycleAStartedUtc = $null
    cycleBStartedUtc = $null
    cycleASourceCommit = $null
    cycleASourceEpoch = $null
    cycleBSourceCommit = $null
    cycleBSourceEpoch = $null
    buildCachePolicy = "not-applicable-skip-build"
    sourceIsolationPolicy = "not-applicable-skip-build"
    identityAttestations = @()
    cycleAArtifacts = @()
    cycleBArtifacts = @()
  }
  try {
    Assert-StackchanFirmwareReproducibilityProof `
      -Proof $diagnosticProof -DiagnosticPackage $true -AllowDirtyPackage $false `
      -ManifestCommit $commit -SourceEpoch "" `
      -ManifestStatus "diagnostic-only; reproducibility not proven; release and hardware validation forbidden" `
      -PackageRoot $fixtureRoot
    throw "Diagnostic proof unexpectedly passed without -AllowDirtyPackage"
  } catch {
    if ($_.Exception.Message -notmatch "requires -AllowDirtyPackage") { throw }
  }
  Assert-StackchanFirmwareReproducibilityProof `
    -Proof $diagnosticProof -DiagnosticPackage $true -AllowDirtyPackage $true `
    -ManifestCommit $commit -SourceEpoch "" `
    -ManifestStatus "diagnostic-only; reproducibility not proven; release and hardware validation forbidden" `
    -PackageRoot $fixtureRoot
  foreach ($mutation in @(
    { param($p) $p.status = 'verified-two-clean-cycles' },
    { param($p) $p.clockBoundarySeconds = 65 },
    { param($p) $p.cycleASourceCommit = $script:commit },
    { param($p) $p.cycleAArtifacts = @([pscustomobject]@{ artifact = 'firmware.bin' }) }
  )) {
    $candidate = Copy-Proof $diagnosticProof
    & $mutation $candidate
    try {
      Assert-StackchanFirmwareReproducibilityProof `
        -Proof $candidate -DiagnosticPackage $true -AllowDirtyPackage $true `
        -ManifestCommit $commit -SourceEpoch '' `
        -ManifestStatus "diagnostic-only; reproducibility not proven; release and hardware validation forbidden" `
        -PackageRoot $fixtureRoot
      throw 'Mutated diagnostic reproducibility proof unexpectedly passed'
    } catch {
      if ($_.Exception.Message -eq 'Mutated diagnostic reproducibility proof unexpectedly passed') { throw }
      if ($_.Exception.Message -notmatch 'reproducibility and hardware validation are unproven') { throw }
    }
  }
} finally {
  if (Test-Path -LiteralPath $fixtureRoot) {
    [System.IO.Directory]::Delete($fixtureRoot, $true)
  }
}

Write-Host "Firmware reproducibility proof mutation contract passed."
