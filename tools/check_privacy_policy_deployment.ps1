param(
  [string]$Root = "",
  [string]$EvidencePath = "docs/store-assets/play/PRIVACY_POLICY_DEPLOYMENT.json",
  [string]$FetchedContentPath = "",
  [int]$TimeoutSeconds = 30,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$canonicalUrl = "https://robvanprod.github.io/stackchan_alive/privacy/"

if ([string]::IsNullOrWhiteSpace($Root)) {
  $Root = Resolve-Path (Join-Path $PSScriptRoot "..")
} else {
  $Root = Resolve-Path $Root
}
$Root = [System.IO.Path]::GetFullPath([string]$Root)

if (-not [System.IO.Path]::IsPathRooted($EvidencePath)) {
  $EvidencePath = Join-Path $Root $EvidencePath
}

$checks = @()
$evidence = $null
$sourceSha256 = ""
$servedSha256 = ""
$verificationMode = if ([string]::IsNullOrWhiteSpace($FetchedContentPath)) { "live-https" } else { "fixture" }

function Add-Check {
  param(
    [string]$Id,
    [string]$Name,
    [ValidateSet("pass", "fail")]
    [string]$Status,
    [string]$Evidence,
    [string]$Detail
  )

  $script:checks += [ordered]@{
    id = $Id
    name = $Name
    status = $Status
    evidence = $Evidence
    detail = $Detail
  }
}

function Get-BytesSha256 {
  param([byte[]]$Bytes)

  $sha256 = [System.Security.Cryptography.SHA256]::Create()
  try {
    return ([System.BitConverter]::ToString($sha256.ComputeHash($Bytes)) -replace "-", "").ToLowerInvariant()
  } finally {
    $sha256.Dispose()
  }
}

function Test-Commit {
  param([string]$Value)
  return $Value -match "^[a-f0-9]{40}$"
}

function Test-UtcTimestamp {
  param([string]$Value)

  if ($Value -notmatch "^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$") {
    return $false
  }
  $parsed = [DateTimeOffset]::MinValue
  return [DateTimeOffset]::TryParse($Value, [ref]$parsed)
}

function Resolve-RootFile {
  param([string]$RelativePath)

  if ([string]::IsNullOrWhiteSpace($RelativePath) -or [System.IO.Path]::IsPathRooted($RelativePath)) {
    return $null
  }
  $candidate = [System.IO.Path]::GetFullPath((Join-Path $Root $RelativePath))
  $rootPrefix = $Root.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
  if (-not $candidate.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $null
  }
  return $candidate
}

try {
  $rawEvidence = Get-Content -LiteralPath $EvidencePath -Raw
  $evidence = $rawEvidence | ConvertFrom-Json
  Add-Check "evidence-file" "Deployment evidence file" "pass" $EvidencePath "Deployment evidence parsed as JSON."
} catch {
  Add-Check "evidence-file" "Deployment evidence file" "fail" $EvidencePath $_.Exception.Message
}

if ($null -ne $evidence) {
  if ([string]$evidence.schema -eq "stackchan.privacy-policy-deployment.v1") {
    Add-Check "evidence-schema" "Deployment evidence schema" "pass" ([string]$evidence.schema) "Deployment schema is recognized."
  } else {
    Add-Check "evidence-schema" "Deployment evidence schema" "fail" ([string]$evidence.schema) "Expected stackchan.privacy-policy-deployment.v1."
  }

  if ([string]$evidence.status -eq "deployed") {
    Add-Check "deployment-status" "Deployment status" "pass" ([string]$evidence.status) "The policy is recorded as deployed."
  } else {
    Add-Check "deployment-status" "Deployment status" "fail" ([string]$evidence.status) "Status must be deployed."
  }

  if ([string]$evidence.canonicalUrl -ceq $canonicalUrl -and [string]$evidence.finalUrl -ceq $canonicalUrl) {
    Add-Check "canonical-url" "Canonical HTTPS URL" "pass" $canonicalUrl "Evidence uses the app's canonical HTTPS privacy URL."
  } else {
    Add-Check "canonical-url" "Canonical HTTPS URL" "fail" ([string]$evidence.canonicalUrl) "Both canonicalUrl and finalUrl must equal $canonicalUrl"
  }

  $sourcePath = Resolve-RootFile ([string]$evidence.sourcePath)
  if ($null -ne $sourcePath -and (Test-Path -LiteralPath $sourcePath -PathType Leaf) -and [string]$evidence.sourcePath -eq "site/privacy/index.html") {
    Add-Check "source-path" "Policy source path" "pass" ([string]$evidence.sourcePath) "The tracked public policy source exists."
  } else {
    Add-Check "source-path" "Policy source path" "fail" ([string]$evidence.sourcePath) "sourcePath must resolve to site/privacy/index.html inside the repository root."
  }

  if ((Test-Commit ([string]$evidence.sourceCommit)) -and (Test-Commit ([string]$evidence.deploymentCommit))) {
    Add-Check "deployment-commits" "Source and deployment commits" "pass" ([string]$evidence.deploymentCommit) "Both deployment identities are full Git commit hashes."
  } else {
    Add-Check "deployment-commits" "Source and deployment commits" "fail" ([string]$evidence.deploymentCommit) "sourceCommit and deploymentCommit must be full lowercase Git commit hashes."
  }

  if ($null -ne $sourcePath -and (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
    $sourceBytes = [System.IO.File]::ReadAllBytes($sourcePath)
    $sourceSha256 = Get-BytesSha256 $sourceBytes
    if ($sourceSha256 -ceq [string]$evidence.sourceSha256 -and $sourceSha256 -ceq [string]$evidence.servedSha256) {
      Add-Check "source-hash" "Policy source SHA-256" "pass" $sourceSha256 "Source and recorded served hashes match."
    } else {
      Add-Check "source-hash" "Policy source SHA-256" "fail" $sourceSha256 "The tracked source differs from sourceSha256 or servedSha256 in the deployment record."
    }
  } else {
    Add-Check "source-hash" "Policy source SHA-256" "fail" "" "The policy source could not be hashed."
  }

  if ([string]$evidence.deploymentMethod -eq "github-pages-branch" -and [string]$evidence.deploymentBranch -eq "gh-pages" -and [long]$evidence.pagesBuildId -gt 0 -and [string]$evidence.pagesBuildStatus -eq "built" -and [bool]$evidence.httpsEnforced) {
    Add-Check "pages-build" "GitHub Pages build record" "pass" ([string]$evidence.pagesBuildId) "Pages build is recorded as built with HTTPS enforced."
  } else {
    Add-Check "pages-build" "GitHub Pages build record" "fail" ([string]$evidence.pagesBuildId) "Expected a built gh-pages deployment with HTTPS enforced."
  }

  if ((Test-UtcTimestamp ([string]$evidence.pagesBuiltAtUtc)) -and (Test-UtcTimestamp ([string]$evidence.verifiedAtUtc))) {
    Add-Check "verification-timestamps" "Deployment verification timestamps" "pass" ([string]$evidence.verifiedAtUtc) "Build and verification times use strict UTC timestamps."
  } else {
    Add-Check "verification-timestamps" "Deployment verification timestamps" "fail" ([string]$evidence.verifiedAtUtc) "pagesBuiltAtUtc and verifiedAtUtc must use YYYY-MM-DDTHH:MM:SSZ."
  }

  $servedBytes = $null
  $httpStatus = 0
  $finalUrl = ""
  try {
    if ($verificationMode -eq "fixture") {
      $fixturePath = if ([System.IO.Path]::IsPathRooted($FetchedContentPath)) { $FetchedContentPath } else { Join-Path $Root $FetchedContentPath }
      $servedBytes = [System.IO.File]::ReadAllBytes($fixturePath)
      $httpStatus = 200
      $finalUrl = $canonicalUrl
    } else {
      Add-Type -AssemblyName System.Net.Http
      $handler = [System.Net.Http.HttpClientHandler]::new()
      $handler.AllowAutoRedirect = $true
      $client = [System.Net.Http.HttpClient]::new($handler)
      $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
      try {
        $response = $client.GetAsync($canonicalUrl).GetAwaiter().GetResult()
        try {
          $httpStatus = [int]$response.StatusCode
          $finalUrl = $response.RequestMessage.RequestUri.AbsoluteUri
          $servedBytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        } finally {
          $response.Dispose()
        }
      } finally {
        $client.Dispose()
        $handler.Dispose()
      }
    }
    Add-Check "content-fetch" "Published policy content fetch" "pass" $verificationMode "Policy content was fetched for verification."
  } catch {
    Add-Check "content-fetch" "Published policy content fetch" "fail" $verificationMode $_.Exception.Message
  }

  if ($null -ne $servedBytes) {
    if ($httpStatus -eq 200 -and $finalUrl -ceq $canonicalUrl) {
      Add-Check "live-http" "Published policy HTTPS response" "pass" "$httpStatus $finalUrl" "Canonical URL returned HTTP 200 without leaving the canonical HTTPS URL."
    } else {
      Add-Check "live-http" "Published policy HTTPS response" "fail" "$httpStatus $finalUrl" "Expected HTTP 200 at the canonical URL."
    }

    $servedSha256 = Get-BytesSha256 $servedBytes
    if ($servedSha256 -ceq $sourceSha256 -and $servedSha256 -ceq [string]$evidence.servedSha256) {
      Add-Check "live-content-hash" "Published policy byte identity" "pass" $servedSha256 "Published bytes exactly match the tracked source and deployment record."
    } else {
      Add-Check "live-content-hash" "Published policy byte identity" "fail" $servedSha256 "Published bytes do not match the tracked source and deployment record."
    }

    $servedText = [System.Text.Encoding]::UTF8.GetString($servedBytes)
    $requiredMarkers = @(
      "Stackchan Companion Privacy Policy",
      "July 14, 2026",
      "dev.stackchan.companion",
      "local network",
      "configured Android speech-recognition service",
      "Privacy inquiries"
    )
    $missingMarkers = @($requiredMarkers | Where-Object { $servedText.IndexOf($_, [System.StringComparison]::Ordinal) -lt 0 })
    if ($missingMarkers.Count -eq 0) {
      Add-Check "live-content-markers" "Published policy disclosures" "pass" ($requiredMarkers -join ", ") "Required identity and privacy disclosures are present."
    } else {
      Add-Check "live-content-markers" "Published policy disclosures" "fail" ($missingMarkers -join ", ") "Published policy is missing required disclosure text."
    }
  } else {
    Add-Check "live-http" "Published policy HTTPS response" "fail" "" "No fetched response was available."
    Add-Check "live-content-hash" "Published policy byte identity" "fail" "" "No fetched content was available."
    Add-Check "live-content-markers" "Published policy disclosures" "fail" "" "No fetched content was available."
  }
}

$failedChecks = @($checks | Where-Object { $_.status -eq "fail" })
$report = [ordered]@{
  schema = "stackchan.privacy-policy-deployment-check.v1"
  status = if ($failedChecks.Count -eq 0) { "privacy-policy-deployment-ready" } else { "privacy-policy-deployment-not-ready" }
  evidencePath = [string]$EvidencePath
  canonicalUrl = $canonicalUrl
  sourceCommit = if ($null -ne $evidence) { [string]$evidence.sourceCommit } else { "" }
  deploymentCommit = if ($null -ne $evidence) { [string]$evidence.deploymentCommit } else { "" }
  verificationMode = $verificationMode
  liveVerified = ($verificationMode -eq "live-https" -and $failedChecks.Count -eq 0)
  sourceSha256 = $sourceSha256
  servedSha256 = $servedSha256
  checkedAtUtc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
  passed = @($checks | Where-Object { $_.status -eq "pass" }).Count
  failed = $failedChecks.Count
  checks = @($checks)
}

if ($Json) {
  $report | ConvertTo-Json -Depth 8
} else {
  Write-Host "Privacy policy deployment: $($report.status)"
  Write-Host "Passed: $($report.passed)  Failed: $($report.failed)  Mode: $verificationMode"
  foreach ($check in $checks) {
    $prefix = if ($check.status -eq "pass") { "PASS" } else { "FAIL" }
    Write-Host "[$prefix] $($check.name) - $($check.detail)"
  }
}

if ($failedChecks.Count -gt 0) {
  exit 1
}
exit 0
