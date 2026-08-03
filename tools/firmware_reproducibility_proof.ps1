function Assert-StackchanFirmwareReproducibilityProof {
  param(
    [Parameter(Mandatory = $true)][object]$Proof,
    [Parameter(Mandatory = $true)][bool]$DiagnosticPackage,
    [Parameter(Mandatory = $true)][bool]$AllowDirtyPackage,
    [Parameter(Mandatory = $true)][string]$ManifestCommit,
    [Parameter(Mandatory = $true)][AllowEmptyString()][string]$SourceEpoch,
    [Parameter(Mandatory = $true)][string]$ManifestStatus,
    [Parameter(Mandatory = $true)][string]$PackageRoot
  )

  if ($DiagnosticPackage) {
    if (-not $AllowDirtyPackage) {
      throw "Diagnostic release package requires -AllowDirtyPackage"
    }
    if ($Proof.status -ne "not-proven-skip-build" -or
        [int]$Proof.minimumClockBoundarySeconds -ne 65 -or
        [int]$Proof.clockBoundarySeconds -ne 0 -or
        $null -ne $Proof.cycleAStartedUtc -or
        $null -ne $Proof.cycleBStartedUtc -or
        $null -ne $Proof.cycleASourceCommit -or
        $null -ne $Proof.cycleASourceEpoch -or
        $null -ne $Proof.cycleBSourceCommit -or
        $null -ne $Proof.cycleBSourceEpoch -or
        $Proof.buildCachePolicy -ne "not-applicable-skip-build" -or
        $Proof.sourceIsolationPolicy -ne "not-applicable-skip-build" -or
        @($Proof.identityAttestations).Count -ne 0 -or
        @($Proof.cycleAArtifacts).Count -ne 0 -or
        @($Proof.cycleBArtifacts).Count -ne 0 -or
        $ManifestStatus -ne "diagnostic-only; reproducibility not proven; release and hardware validation forbidden") {
      throw "Diagnostic package must state that reproducibility and hardware validation are unproven"
    }
    return
  }

  if ($Proof.status -ne "verified-two-clean-cycles" -or
      [int]$Proof.minimumClockBoundarySeconds -ne 65 -or
      [int]$Proof.clockBoundarySeconds -lt 65) {
    throw "Release package lacks the required two-cycle firmware reproducibility proof"
  }
  if ($Proof.cycleASourceCommit -cne $ManifestCommit -or
      $Proof.cycleBSourceCommit -cne $ManifestCommit -or
      [string]$Proof.cycleASourceEpoch -cne $SourceEpoch -or
      [string]$Proof.cycleBSourceEpoch -cne $SourceEpoch -or
      $Proof.buildCachePolicy -cne "isolated-empty-per-cycle-environment") {
    throw "Firmware reproducibility proof is not bound to one manifest Git identity and isolated build-cache policy"
  }
  if ($Proof.sourceIsolationPolicy -cne "distinct-short-detached-clean-worktrees-pinned-to-source-commit-with-prefix-mapped-paths") {
    throw "Firmware reproducibility proof does not use the required distinct detached source policy"
  }

  $identityAttestations = @($Proof.identityAttestations)
  if ($identityAttestations.Count -ne 6) {
    throw "Firmware reproducibility proof must contain six cycle/environment identity attestations"
  }
  $expectedIdentityKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($cycleName in @("cycle-a", "cycle-b")) {
    foreach ($environmentName in @("stackchan", "stackchan_servo_calibration", "stackchan_release_full")) {
      [void]$expectedIdentityKeys.Add("$cycleName/$environmentName")
    }
  }
  $seenIdentityKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($attestation in $identityAttestations) {
    $identityKey = "$($attestation.cycle)/$($attestation.environment)"
    if (-not $expectedIdentityKeys.Contains($identityKey) -or
        -not $seenIdentityKeys.Add($identityKey) -or
        $attestation.sourceCommit -cne $ManifestCommit -or
        [string]$attestation.sourceEpoch -cne $SourceEpoch -or
        $attestation.preBuildChecked -ne $true -or
        $attestation.postSnapshotChecked -ne $true) {
      throw "Firmware reproducibility proof has an invalid identity attestation: $identityKey"
    }
  }
  if ($seenIdentityKeys.Count -ne $expectedIdentityKeys.Count) {
    throw "Firmware reproducibility proof is missing a required identity attestation"
  }

  try {
    $cycleAStarted = [DateTimeOffset]::ParseExact(
      [string]$Proof.cycleAStartedUtc,
      "yyyy-MM-ddTHH:mm:ssZ",
      [Globalization.CultureInfo]::InvariantCulture,
      [Globalization.DateTimeStyles]::AssumeUniversal)
    $cycleBStarted = [DateTimeOffset]::ParseExact(
      [string]$Proof.cycleBStartedUtc,
      "yyyy-MM-ddTHH:mm:ssZ",
      [Globalization.CultureInfo]::InvariantCulture,
      [Globalization.DateTimeStyles]::AssumeUniversal)
  } catch {
    throw "Firmware reproducibility proof has invalid cycle timestamps"
  }
  $measuredClockBoundary = [int][Math]::Floor(($cycleBStarted - $cycleAStarted).TotalSeconds)
  if ($measuredClockBoundary -lt 65 -or
      $measuredClockBoundary -ne [int]$Proof.clockBoundarySeconds) {
    throw "Firmware reproducibility proof clock boundary is inconsistent"
  }

  $cycleAArtifacts = @($Proof.cycleAArtifacts)
  $cycleBArtifacts = @($Proof.cycleBArtifacts)
  if ($cycleAArtifacts.Count -ne 12 -or $cycleBArtifacts.Count -ne 12) {
    throw "Firmware reproducibility proof must contain 12 artifacts per cycle"
  }
  $packageFirmwareRoots = @{
    stackchan = "firmware/display_only"
    stackchan_servo_calibration = "firmware/servo_calibration"
    stackchan_release_full = "firmware/full_online"
  }
  $packageRootPath = [System.IO.Path]::GetFullPath($PackageRoot).TrimEnd('\', '/')
  $packageRootPrefix = $packageRootPath + [System.IO.Path]::DirectorySeparatorChar
  $expectedProofKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($expectedEnvironment in @($packageFirmwareRoots.Keys)) {
    foreach ($expectedArtifact in @("firmware.bin", "firmware.elf", "bootloader.bin", "partitions.bin")) {
      [void]$expectedProofKeys.Add("$expectedEnvironment/$expectedArtifact")
    }
  }
  $seenProofKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  for ($artifactIndex = 0; $artifactIndex -lt 12; $artifactIndex++) {
    $left = $cycleAArtifacts[$artifactIndex]
    $right = $cycleBArtifacts[$artifactIndex]
    if ($left.environment -cne $right.environment -or
        $left.artifact -cne $right.artifact -or
        [long]$left.bytes -ne [long]$right.bytes -or
        $left.sha256 -cne $right.sha256) {
      throw "Firmware reproducibility proof mismatch at artifact index $artifactIndex"
    }
    $firmwareRoot = $packageFirmwareRoots[[string]$right.environment]
    if ([string]::IsNullOrWhiteSpace($firmwareRoot)) {
      throw "Firmware reproducibility proof contains unknown environment: $($right.environment)"
    }
    $proofKey = "$($right.environment)/$($right.artifact)"
    if (-not $expectedProofKeys.Contains($proofKey) -or -not $seenProofKeys.Add($proofKey)) {
      throw "Firmware reproducibility proof contains an unexpected or duplicate artifact: $proofKey"
    }
    $packagedArtifact = [System.IO.Path]::GetFullPath((Join-Path $packageRootPath (
      "$firmwareRoot/$($right.artifact)" -replace '/', '\')))
    if (-not $packagedArtifact.StartsWith($packageRootPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Test-Path -LiteralPath $packagedArtifact -PathType Leaf)) {
      throw "Missing packaged artifact for reproducibility proof: $proofKey"
    }
    $packagedItem = Get-Item -LiteralPath $packagedArtifact
    $packagedHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $packagedArtifact).Hash.ToUpperInvariant()
    if ([long]$packagedItem.Length -ne [long]$right.bytes -or $packagedHash -cne $right.sha256) {
      throw "Packaged artifact does not match reproducibility cycle B: $proofKey"
    }
  }
  if ($seenProofKeys.Count -ne $expectedProofKeys.Count) {
    throw "Firmware reproducibility proof is missing one or more required artifacts"
  }
}
