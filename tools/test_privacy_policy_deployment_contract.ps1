param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$checkScript = Join-Path $PSScriptRoot "check_privacy_policy_deployment.ps1"
$temporaryRoots = New-Object System.Collections.Generic.List[string]

function New-TestRoot {
  $root = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-privacy-deployment-contract-" + [guid]::NewGuid().ToString("N"))
  $temporaryRoots.Add($root) | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $root "site/privacy") | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $root "docs/store-assets/play") | Out-Null
  Copy-Item -LiteralPath (Join-Path $repoRoot "site/privacy/index.html") -Destination (Join-Path $root "site/privacy/index.html")
  Copy-Item -LiteralPath (Join-Path $repoRoot "site/privacy/index.html") -Destination (Join-Path $root "fetched.html")
  return $root
}

function Get-Sha256 {
  param([string]$Path)
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function New-Evidence {
  param([string]$Root)

  $sha = Get-Sha256 (Join-Path $Root "site/privacy/index.html")
  return [ordered]@{
    schema = "stackchan.privacy-policy-deployment.v1"
    status = "deployed"
    canonicalUrl = "https://robvanprod.github.io/stackchan_alive/privacy/"
    sourcePath = "site/privacy/index.html"
    sourceCommit = ("a" * 40)
    sourceSha256 = $sha
    sourceGitBlob = ("b" * 40)
    deploymentMethod = "github-pages-branch"
    deploymentBranch = "gh-pages"
    deploymentCommit = ("c" * 40)
    pagesBuildId = 1
    pagesBuildStatus = "built"
    pagesBuiltAtUtc = "2026-07-14T05:05:42Z"
    verifiedAtUtc = "2026-07-14T05:06:53Z"
    httpStatus = 200
    finalUrl = "https://robvanprod.github.io/stackchan_alive/privacy/"
    servedSha256 = $sha
    httpsEnforced = $true
  }
}

function Write-Evidence {
  param([string]$Root, [object]$Evidence)
  $Evidence | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Root "docs/store-assets/play/PRIVACY_POLICY_DEPLOYMENT.json") -Encoding UTF8
}

function Invoke-Check {
  param([string]$Root)

  $powerShellExe = (Get-Process -Id $PID).Path
  $oldPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & $powerShellExe -NoProfile -ExecutionPolicy Bypass -File $checkScript -Root $Root -FetchedContentPath "fetched.html" -Json 2>&1
    $exitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldPreference
  }
  $text = ($output | Out-String).Trim()
  return [pscustomobject]@{ exitCode = $exitCode; text = $text; report = ($text | ConvertFrom-Json) }
}

function Assert-Check {
  param([object]$Report, [string]$Id, [string]$Status)

  $check = @($Report.checks | Where-Object { $_.id -eq $Id })
  if ($check.Count -ne 1 -or $check[0].status -ne $Status) {
    throw "Expected check '$Id' to be '$Status'."
  }
}

try {
  $validRoot = New-TestRoot
  Write-Evidence $validRoot (New-Evidence $validRoot)
  $valid = Invoke-Check $validRoot
  if ($valid.exitCode -ne 0 -or $valid.report.status -ne "privacy-policy-deployment-ready") {
    throw "Expected exact policy deployment evidence to pass. Output:`n$($valid.text)"
  }
  Assert-Check $valid.report "live-content-hash" "pass"
  Write-Host "[ok] exact published privacy policy bytes are accepted"

  $tamperedRoot = New-TestRoot
  Write-Evidence $tamperedRoot (New-Evidence $tamperedRoot)
  Add-Content -LiteralPath (Join-Path $tamperedRoot "fetched.html") -Value "tampered"
  $tampered = Invoke-Check $tamperedRoot
  if ($tampered.exitCode -eq 0) { throw "Expected tampered published content to fail." }
  Assert-Check $tampered.report "live-content-hash" "fail"
  Write-Host "[ok] tampered published privacy policy bytes are rejected"

  $urlRoot = New-TestRoot
  $urlEvidence = New-Evidence $urlRoot
  $urlEvidence.canonicalUrl = "http://robvanprod.github.io/stackchan_alive/privacy/"
  Write-Evidence $urlRoot $urlEvidence
  $urlResult = Invoke-Check $urlRoot
  if ($urlResult.exitCode -eq 0) { throw "Expected noncanonical privacy URL to fail." }
  Assert-Check $urlResult.report "canonical-url" "fail"
  Write-Host "[ok] noncanonical privacy policy URL is rejected"

  $staleRoot = New-TestRoot
  $staleEvidence = New-Evidence $staleRoot
  $staleEvidence.sourceSha256 = ("d" * 64)
  Write-Evidence $staleRoot $staleEvidence
  $stale = Invoke-Check $staleRoot
  if ($stale.exitCode -eq 0) { throw "Expected stale policy source hash to fail." }
  Assert-Check $stale.report "source-hash" "fail"
  Write-Host "[ok] stale privacy policy source hash is rejected"

  $pendingRoot = New-TestRoot
  $pendingEvidence = New-Evidence $pendingRoot
  $pendingEvidence.status = "pending"
  Write-Evidence $pendingRoot $pendingEvidence
  $pending = Invoke-Check $pendingRoot
  if ($pending.exitCode -eq 0) { throw "Expected pending deployment status to fail." }
  Assert-Check $pending.report "deployment-status" "fail"
  Write-Host "[ok] pending privacy policy deployment status is rejected"

  Write-Host "Privacy policy deployment contract tests passed: 5/5."
} finally {
  foreach ($root in $temporaryRoots) {
    if (Test-Path -LiteralPath $root) {
      Remove-Item -LiteralPath $root -Recurse -Force
    }
  }
}
