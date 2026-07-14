param(
  [string]$Root = "",
  [switch]$Json
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Root)) {
  $Root = Resolve-Path (Join-Path $PSScriptRoot "..")
} else {
  $Root = Resolve-Path $Root
}

$checks = @()
$blockedTrackedFiles = @()
$privateKeyMarkerFiles = @()

function Add-Check {
  param(
    [string]$Id,
    [ValidateSet("pass", "fail")]
    [string]$Status,
    [string]$Detail
  )

  $script:checks += [ordered]@{
    id = $Id
    status = $Status
    detail = $Detail
  }
}

function Invoke-Git {
  param(
    [string[]]$Arguments,
    [int[]]$AllowedExitCodes = @(0)
  )

  $output = @()
  $exitCode = -1
  $oldPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = @(& git -C $Root @Arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } catch {
    $output = @($_.Exception.Message)
  } finally {
    $ErrorActionPreference = $oldPreference
  }

  if ($AllowedExitCodes -notcontains $exitCode) {
    throw "git -C $Root $($Arguments -join ' ') failed with exit code $exitCode.`n$($output | Out-String)"
  }
  return [pscustomobject]@{
    exitCode = $exitCode
    output = @($output)
  }
}

try {
  $inside = Invoke-Git -Arguments @("rev-parse", "--is-inside-work-tree")
  $isWorkTree = (($inside.output | Out-String).Trim() -eq "true")
  Add-Check "git-worktree" $(if ($isWorkTree) { "pass" } else { "fail" }) "root=$Root"
} catch {
  Add-Check "git-worktree" "fail" "A Git source checkout is required: $($_.Exception.Message)"
}

$requiredIgnoreProbes = [ordered]@{
  "ignore-pattern-jks" = "credential-hygiene-probe/upload.jks"
  "ignore-pattern-keystore" = "credential-hygiene-probe/upload.keystore"
  "ignore-pattern-p12" = "credential-hygiene-probe/developer-id.p12"
  "ignore-pattern-pfx" = "credential-hygiene-probe/authenticode.pfx"
  "ignore-pattern-pkcs12" = "credential-hygiene-probe/signing.pkcs12"
  "ignore-pattern-key" = "credential-hygiene-probe/private.key"
  "ignore-pattern-p8" = "credential-hygiene-probe/apple-api-key.p8"
  "ignore-pattern-snk" = "credential-hygiene-probe/strong-name.snk"
}

foreach ($entry in $requiredIgnoreProbes.GetEnumerator()) {
  try {
    $ignored = Invoke-Git `
      -Arguments @("check-ignore", "--quiet", "--no-index", "--", [string]$entry.Value) `
      -AllowedExitCodes @(0, 1)
    $isIgnored = ($ignored.exitCode -eq 0)
    Add-Check ([string]$entry.Key) $(if ($isIgnored) { "pass" } else { "fail" }) $(
      if ($isIgnored) {
        "$($entry.Value) is excluded from Git."
      } else {
        "$($entry.Value) is not excluded; add its private-key extension to .gitignore."
      }
    )
  } catch {
    Add-Check ([string]$entry.Key) "fail" $_.Exception.Message
  }
}

try {
  $tracked = Invoke-Git -Arguments @("ls-files")
  $blockedPattern = '(?i)\.(jks|keystore|p12|pfx|pkcs12|key|p8|snk)$'
  $blockedTrackedFiles = @(
    $tracked.output |
      ForEach-Object { ([string]$_).Trim() } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -match $blockedPattern } |
      Sort-Object -Unique
  )
  Add-Check "tracked-private-key-bundles" $(if ($blockedTrackedFiles.Count -eq 0) { "pass" } else { "fail" }) $(
    if ($blockedTrackedFiles.Count -eq 0) {
      "No private signing credential bundle extension is tracked."
    } else {
      "Tracked private signing credential paths: $($blockedTrackedFiles -join ', ')"
    }
  )
} catch {
  Add-Check "tracked-private-key-bundles" "fail" $_.Exception.Message
}

try {
  $markerPattern = 'BEGIN (RSA |EC |OPENSSH |DSA |ENCRYPTED )?' + 'PRIVATE KEY'
  $markerSearch = Invoke-Git `
    -Arguments @("grep", "-I", "-l", "-E", $markerPattern, "--", ".") `
    -AllowedExitCodes @(0, 1)
  if ($markerSearch.exitCode -eq 0) {
    $privateKeyMarkerFiles = @(
      $markerSearch.output |
        ForEach-Object { ([string]$_).Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
    )
  }
  Add-Check "tracked-private-key-markers" $(if ($privateKeyMarkerFiles.Count -eq 0) { "pass" } else { "fail" }) $(
    if ($privateKeyMarkerFiles.Count -eq 0) {
      "No tracked text file contains a PEM or OpenSSH private-key marker."
    } else {
      "Tracked files containing private-key markers: $($privateKeyMarkerFiles -join ', ')"
    }
  )
} catch {
  Add-Check "tracked-private-key-markers" "fail" $_.Exception.Message
}

$failed = @($checks | Where-Object { $_.status -eq "fail" })
$status = if ($failed.Count -eq 0) {
  "release-credential-hygiene-ready"
} else {
  "blocked-release-credential-hygiene"
}
$report = [ordered]@{
  schema = "stackchan.release-credential-hygiene.v1"
  status = $status
  root = [string]$Root
  passed = @($checks | Where-Object { $_.status -eq "pass" }).Count
  failed = $failed.Count
  blockedTrackedFiles = @($blockedTrackedFiles)
  privateKeyMarkerFiles = @($privateKeyMarkerFiles)
  checks = @($checks)
}

if ($Json) {
  $report | ConvertTo-Json -Depth 6
} else {
  Write-Host "Release credential hygiene: $status"
  Write-Host "Pass: $($report.passed)  Fail: $($report.failed)"
  foreach ($check in $checks) {
    Write-Host "[$($check.status)] $($check.id): $($check.detail)"
  }
}

if ($failed.Count -gt 0) {
  exit 1
}
