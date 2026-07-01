param(
  [string]$Version,
  [string]$ShareRoot
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

function Get-ReleaseManifest {
  param([string]$RootPath)

  $manifestPath = Join-Path $RootPath "release_manifest.json"
  if (-not (Test-Path -LiteralPath $manifestPath)) {
    return $null
  }

  return Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
}

function Invoke-GitText {
  param([string[]]$Arguments)

  try {
    $output = & git @Arguments 2>$null
  } catch {
    return ""
  }
  if ($LASTEXITCODE -ne 0) {
    return ""
  }
  return ($output | Out-String).Trim()
}

if ([string]::IsNullOrWhiteSpace($ShareRoot)) {
  if ([string]::IsNullOrWhiteSpace($Version)) {
    $rootManifest = Get-ReleaseManifest $repoRoot
    if ($null -ne $rootManifest) {
      $Version = [string]$rootManifest.version
    } else {
      $Version = Invoke-GitText @("describe", "--tags", "--always", "--dirty")
    }
  }

  if ([string]::IsNullOrWhiteSpace($Version)) {
    throw "Version is required when ShareRoot is not provided and it cannot be inferred."
  }

  $ShareRoot = Join-Path $repoRoot "output/share/$Version"
}

if (-not (Test-Path -LiteralPath $ShareRoot)) {
  throw "Missing share folder: $ShareRoot"
}

$shareRootPath = (Resolve-Path $ShareRoot).Path
$pidFiles = @(
  (Join-Path $shareRootPath "server.pid"),
  (Join-Path $shareRootPath "cloudflared.pid")
)

$ids = @()
foreach ($pidFile in $pidFiles) {
  if (-not (Test-Path -LiteralPath $pidFile)) {
    continue
  }

  $text = (Get-Content -LiteralPath $pidFile -Raw).Trim()
  $id = 0
  if ([int]::TryParse($text, [ref]$id)) {
    $ids += $id
  }
}

if ($ids.Count -gt 0) {
  Stop-Process -Id $ids -Force -ErrorAction SilentlyContinue
  Wait-Process -Id $ids -Timeout 5 -ErrorAction SilentlyContinue
}

$statusPath = Join-Path $shareRootPath "share_status.json"
if (Test-Path -LiteralPath $statusPath) {
  $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
} else {
  $status = [pscustomobject]@{}
}

$status | Add-Member -NotePropertyName "stoppedUtc" -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")) -Force
$status | Add-Member -NotePropertyName "stoppedProcessIds" -NotePropertyValue @($ids) -Force
$status | ConvertTo-Json -Depth 5 | Set-Content -Path $statusPath -Encoding UTF8

Write-Host "Stopped share processes:"
if ($ids.Count -gt 0) {
  Write-Host ($ids -join ", ")
} else {
  Write-Host "none"
}
