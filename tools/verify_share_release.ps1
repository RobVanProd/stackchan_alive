param(
  [string]$Version = "",
  [string]$ShareRoot = "",
  [string]$Url = "",
  [switch]$RequirePublicUrl,
  [int]$TimeoutSeconds = 20
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

function Assert-File {
  param(
    [string]$Path,
    [int64]$MinBytes = 1
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    throw "Missing share file: $Path"
  }

  $item = Get-Item -LiteralPath $Path
  if ($item.Length -lt $MinBytes) {
    throw "Share file is too small: $Path ($($item.Length) bytes)"
  }
}

function Join-Url {
  param(
    [string]$BaseUrl,
    [string]$Path
  )

  return $BaseUrl.TrimEnd("/") + "/" + $Path.TrimStart("/")
}

function Invoke-UrlProbe {
  param(
    [string]$TargetUrl,
    [int]$TimeoutSeconds
  )

  $curl = Get-Command "curl.exe" -ErrorAction SilentlyContinue
  if ($null -ne $curl) {
    $head = & $curl.Source -L -I --max-time $TimeoutSeconds --silent --show-error $TargetUrl 2>&1
    if ($LASTEXITCODE -eq 0) {
      $lines = @($head -split "`r?`n")
      $statusLine = @($lines | Where-Object { $_ -match "^HTTP/" } | Select-Object -Last 1)
      if ($statusLine.Count -eq 0) {
        throw "No HTTP status line returned for $TargetUrl"
      }

      $contentType = @($lines | Where-Object { $_ -match "^content-type:" } | Select-Object -Last 1)
      $contentLength = @($lines | Where-Object { $_ -match "^content-length:" } | Select-Object -Last 1)

      return [ordered]@{
        Url = $TargetUrl
        StatusLine = [string]$statusLine[0]
        ContentType = if ($contentType.Count -gt 0) { [string]$contentType[0] } else { "" }
        ContentLength = if ($contentLength.Count -gt 0) { [string]$contentLength[0] } else { "" }
      }
    }
  }

  $response = Invoke-WebRequest -Uri $TargetUrl -Method Get -TimeoutSec $TimeoutSeconds -UseBasicParsing
  return [ordered]@{
    Url = $TargetUrl
    StatusLine = "HTTP $([int]$response.StatusCode)"
    ContentType = [string]$response.Headers["Content-Type"]
    ContentLength = [string]$response.Headers["Content-Length"]
  }
}

function Assert-HttpOk {
  param(
    [object]$Probe,
    [string]$ExpectedType,
    [string]$Path
  )

  if ($Probe.StatusLine -notmatch "\s200\s") {
    throw "Share URL did not return HTTP 200 for $Path`: $($Probe.StatusLine)"
  }

  if (-not [string]::IsNullOrWhiteSpace($ExpectedType) -and $Probe.ContentType -notmatch [regex]::Escape($ExpectedType)) {
    throw "Share URL content type mismatch for $Path`: expected $ExpectedType, got $($Probe.ContentType)"
  }
}

if ([string]::IsNullOrWhiteSpace($Version)) {
  $manifestPath = Join-Path $repoRoot "release_manifest.json"
  if (Test-Path -LiteralPath $manifestPath) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $Version = [string]$manifest.version
  } else {
    $Version = (git describe --tags --always --dirty).Trim()
  }
}

if ([string]::IsNullOrWhiteSpace($Version)) {
  throw "Version is required when it cannot be inferred."
}

if ([string]::IsNullOrWhiteSpace($ShareRoot)) {
  $ShareRoot = Join-Path $repoRoot "output/share/$Version"
}

if (-not (Test-Path -LiteralPath $ShareRoot)) {
  throw "Missing share folder: $ShareRoot"
}

$shareRootPath = (Resolve-Path $ShareRoot).Path
$statusPath = Join-Path $shareRootPath "share_status.json"
$publicUrlPath = Join-Path $shareRootPath "PUBLIC_URL.txt"

$status = $null
if (Test-Path -LiteralPath $statusPath) {
  $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
  if ($status.version -ne $Version) {
    throw "share_status.json version mismatch: expected $Version, got $($status.version)"
  }
}

if ([string]::IsNullOrWhiteSpace($Url) -and (Test-Path -LiteralPath $publicUrlPath)) {
  $Url = (Get-Content -LiteralPath $publicUrlPath -Raw).Trim()
}

if ([string]::IsNullOrWhiteSpace($Url) -and $null -ne $status -and -not [string]::IsNullOrWhiteSpace([string]$status.publicUrl)) {
  $Url = [string]$status.publicUrl
}

if ([string]::IsNullOrWhiteSpace($Url) -and $null -ne $status -and -not [string]::IsNullOrWhiteSpace([string]$status.localUrl)) {
  $Url = [string]$status.localUrl
}

if ($RequirePublicUrl -and $Url -notmatch "^https://[-A-Za-z0-9]+\.trycloudflare\.com/?$") {
  throw "Expected a trycloudflare.com public URL, got: $Url"
}

if ([string]::IsNullOrWhiteSpace($Url)) {
  throw "No share URL found. Pass -Url or start share_release first."
}

$expectedFiles = @(
  @{ Path = "index.html"; MinBytes = 500; Type = "text/html" },
  @{ Path = "stackchan_alive_$Version.zip"; MinBytes = 1000000; Type = "application" },
  @{ Path = "stackchan_alive_preview.png"; MinBytes = 1000; Type = "image/png" },
  @{ Path = "stackchan_alive_preview.mp4"; MinBytes = 1000; Type = "video/mp4" },
  @{ Path = "stackchan_alive_preview.gif"; MinBytes = 1000; Type = "image/gif" },
  @{ Path = "QUICKSTART.md"; MinBytes = 100; Type = "" },
  @{ Path = "RELEASE_NOTES.md"; MinBytes = 100; Type = "" },
  @{ Path = "SHA256SUMS.txt"; MinBytes = 100; Type = "" }
)

foreach ($file in $expectedFiles) {
  Assert-File (Join-Path $shareRootPath $file.Path) $file.MinBytes
}

$indexText = Get-Content -LiteralPath (Join-Path $shareRootPath "index.html") -Raw
foreach ($pattern in @($Version, "Hardware validation is still pending", "stackchan_alive_preview.png", "stackchan_alive_preview.mp4", "stackchan_alive_$Version.zip")) {
  if ($indexText -notmatch [regex]::Escape($pattern)) {
    throw "index.html missing expected share guidance: $pattern"
  }
}

$probes = @()
foreach ($file in $expectedFiles | Where-Object { $_.Path -in @("index.html", "stackchan_alive_$Version.zip", "stackchan_alive_preview.png", "stackchan_alive_preview.mp4", "stackchan_alive_preview.gif") }) {
  $path = if ($file.Path -eq "index.html") { "/" } else { $file.Path }
  $probe = Invoke-UrlProbe -TargetUrl (Join-Url $Url $path) -TimeoutSeconds $TimeoutSeconds
  Assert-HttpOk -Probe $probe -ExpectedType $file.Type -Path $path
  $probes += [pscustomobject]$probe
}

Write-Host "Share release verified:"
Write-Host $Url
$probes | ConvertTo-Json -Depth 4
