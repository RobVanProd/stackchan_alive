function Save-StackchanFirmwareReproducibilityFailureEvidence {
  param(
    [Parameter(Mandatory = $true)][string]$FailureRoot,
    [AllowEmptyString()][string]$BuildCacheRoot,
    [AllowEmptyString()][string]$ActiveSourceRoot,
    [Parameter(Mandatory = $true)][bool]$WorktreeStillAttached,
    [Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$Failure,
    [Parameter(Mandatory = $true)][string]$SourceCommit,
    [Parameter(Mandatory = $true)][string]$SourceEpoch
  )

  if (Test-Path -LiteralPath $FailureRoot) {
    throw "Fresh reproducibility failure root already exists: $FailureRoot"
  }
  New-Item -ItemType Directory -Path $FailureRoot | Out-Null

  if (-not [string]::IsNullOrWhiteSpace($BuildCacheRoot) -and
      (Test-Path -LiteralPath $BuildCacheRoot -PathType Container)) {
    Move-Item -LiteralPath $BuildCacheRoot `
      -Destination (Join-Path $FailureRoot "build-cache-and-snapshots")
  }

  $fullWorktreePreserved = (
    $WorktreeStillAttached -and
    -not [string]::IsNullOrWhiteSpace($ActiveSourceRoot) -and
    (Test-Path -LiteralPath $ActiveSourceRoot -PathType Container))
  if (-not $fullWorktreePreserved) {
    throw "A failed reproducibility build must retain its complete detached worktree."
  }

  $failureEvidence = [pscustomobject][ordered]@{
    schema = "stackchan.firmware-reproducibility-failure.v2"
    status = "failed-full-worktree-preserved"
    failedUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    failureType = $Failure.Exception.GetType().FullName
    sourceCommit = $SourceCommit
    sourceEpoch = $SourceEpoch
    artifactsRoot = Split-Path -Leaf $FailureRoot
    activeSourceWorktree = $ActiveSourceRoot
    preservationPolicy = "full-failed-worktree-retained-attached"
    fullWorktreePreserved = $fullWorktreePreserved
    worktreeStillAttached = $true
  }
  $failureEvidence | ConvertTo-Json -Depth 4 | Set-Content `
    -LiteralPath (Join-Path $FailureRoot "FAILURE_EVIDENCE.json") -Encoding UTF8
  return $failureEvidence
}
