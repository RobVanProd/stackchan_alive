param(
  [string]$Version,
  [string]$ShareRoot,
  [switch]$All
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

function Test-PathInside {
  param(
    [string]$Path,
    [string]$Parent
  )

  $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
  $resolvedParent = (Resolve-Path -LiteralPath $Parent).Path
  return $resolvedPath.StartsWith($resolvedParent, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-ProcessCommandLine {
  param([int]$ProcessId)

  try {
    $processInfo = Get-CimInstance Win32_Process -Filter "ProcessId=$ProcessId" -ErrorAction Stop
    return [string]$processInfo.CommandLine
  } catch {
    return ""
  }
}

function Test-ShareOwnedProcess {
  param(
    [int]$ProcessId,
    [string]$ShareRootPath
  )

  $process = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
  if ($null -eq $process) {
    return $false
  }

  $commandLine = Get-ProcessCommandLine -ProcessId $ProcessId
  if ($commandLine -match [regex]::Escape($ShareRootPath)) {
    return $true
  }

  if ($process.ProcessName -match "^(?i:cloudflared)$" -and $commandLine -match "(?i)\btunnel\b.*\b--url\b") {
    return $true
  }

  return $false
}

function Get-ShareProcessIds {
  param([string]$ShareRootPath)

  $statusPath = Join-Path $ShareRootPath "share_status.json"
  $status = $null
  if (Test-Path -LiteralPath $statusPath) {
    $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
  } else {
    $status = [pscustomobject]@{}
  }

  $pidFiles = @(
    (Join-Path $ShareRootPath "server.pid"),
    (Join-Path $ShareRootPath "cloudflared.pid")
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

  if ($null -ne $status -and $null -ne $status.processIds) {
    foreach ($rawId in @($status.processIds)) {
      $id = 0
      if ([int]::TryParse([string]$rawId, [ref]$id)) {
        $ids += $id
      }
    }
  }

  return [ordered]@{
    Status = $status
    StatusPath = $statusPath
    Ids = @($ids | Where-Object { $_ -gt 0 } | Select-Object -Unique)
  }
}

function Stop-ShareRoot {
  param([string]$RootPath)

  if (-not (Test-Path -LiteralPath $RootPath)) {
    throw "Missing share folder: $RootPath"
  }

  $shareRootPath = (Resolve-Path -LiteralPath $RootPath).Path
  if (-not (Test-PathInside -Path $shareRootPath -Parent $shareRootParent)) {
    throw "Refusing to stop processes for share folder outside output/share: $shareRootPath"
  }

  $processInfo = Get-ShareProcessIds -ShareRootPath $shareRootPath
  $status = $processInfo.Status
  $ids = @($processInfo.Ids)
  $statusPath = [string]$processInfo.StatusPath

  $stoppedIds = @()
  $stillRunningIds = @()
  $skippedIds = @()

  foreach ($id in $ids) {
    $process = Get-Process -Id $id -ErrorAction SilentlyContinue
    if ($null -eq $process) {
      continue
    }

    if (-not (Test-ShareOwnedProcess -ProcessId $id -ShareRootPath $shareRootPath)) {
      $skippedIds += $id
      continue
    }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
      Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
      Start-Sleep -Milliseconds 500
      if ($null -eq (Get-Process -Id $id -ErrorAction SilentlyContinue)) {
        $stoppedIds += $id
        break
      }
    }

    if ($null -ne (Get-Process -Id $id -ErrorAction SilentlyContinue)) {
      $stillRunningIds += $id
    }
  }

  $status | Add-Member -NotePropertyName "stoppedUtc" -NotePropertyValue ((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")) -Force
  $status | Add-Member -NotePropertyName "stoppedProcessIds" -NotePropertyValue @($stoppedIds) -Force
  $status | Add-Member -NotePropertyName "stillRunningProcessIds" -NotePropertyValue @($stillRunningIds) -Force
  $status | Add-Member -NotePropertyName "skippedProcessIds" -NotePropertyValue @($skippedIds) -Force
  $status | ConvertTo-Json -Depth 5 | Set-Content -Path $statusPath -Encoding UTF8

  return [pscustomobject]@{
    shareRoot = $shareRootPath
    stoppedProcessIds = @($stoppedIds)
    stillRunningProcessIds = @($stillRunningIds)
    skippedProcessIds = @($skippedIds)
  }
}

$shareRootParent = Join-Path $repoRoot "output/share"

if ($All -and -not [string]::IsNullOrWhiteSpace($ShareRoot)) {
  throw "Use either -All or -ShareRoot, not both."
}

if ($All -and -not [string]::IsNullOrWhiteSpace($Version)) {
  throw "Use either -All or -Version, not both."
}

$shareRoots = @()
if ($All) {
  if (Test-Path -LiteralPath $shareRootParent) {
    $shareRoots = @(
      Get-ChildItem -LiteralPath $shareRootParent -Directory |
        Where-Object {
          (Test-Path -LiteralPath (Join-Path $_.FullName "share_status.json")) -or
          (Test-Path -LiteralPath (Join-Path $_.FullName "server.pid")) -or
          (Test-Path -LiteralPath (Join-Path $_.FullName "cloudflared.pid"))
        } |
        Select-Object -ExpandProperty FullName
    )
  }
} else {
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

    $ShareRoot = Join-Path $shareRootParent $Version
  }

  $shareRoots = @($ShareRoot)
}

$results = @()
foreach ($root in $shareRoots) {
  $results += Stop-ShareRoot -RootPath $root
}

$allStopped = @($results | ForEach-Object { $_.stoppedProcessIds })
$allStillRunning = @($results | ForEach-Object { $_.stillRunningProcessIds })
$allSkipped = @($results | ForEach-Object { $_.skippedProcessIds })

Write-Host "Stopped share processes:"
if ($allStopped.Count -gt 0) {
  Write-Host (($allStopped | Select-Object -Unique) -join ", ")
} else {
  Write-Host "none"
}

if ($allSkipped.Count -gt 0) {
  Write-Warning "Skipped process IDs that no longer look share-owned: $((@($allSkipped | Select-Object -Unique)) -join ', ')"
}

if ($All) {
  Write-Host "Share folders checked: $($results.Count)"
}

if ($allStillRunning.Count -gt 0) {
  throw "Unable to stop share processes: $((@($allStillRunning | Select-Object -Unique)) -join ', ')"
}
