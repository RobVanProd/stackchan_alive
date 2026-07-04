param(
  [string]$Version = "",
  [string]$Commit = "",
  [string]$Root = "",
  [string]$PackageRoot = "",
  [string]$AndroidArtifactRoot = "",
  [string]$DesktopArtifactRoot = "",
  [string]$OutDir = "",
  [switch]$RequireArtifacts,
  [switch]$Json
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Root)) {
  $Root = Resolve-Path (Join-Path $PSScriptRoot "..")
} else {
  $Root = Resolve-Path $Root
}
Set-Location $Root

if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
  $packageCandidate = Join-Path $Root "release_manifest.json"
  if (Test-Path -LiteralPath $packageCandidate -PathType Leaf) {
    $PackageRoot = [string]$Root
  }
} else {
  $PackageRoot = [string](Resolve-Path $PackageRoot)
}

if ([string]::IsNullOrWhiteSpace($OutDir)) {
  $OutDir = Join-Path $Root "output/companion/release-evidence/latest"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Get-GitText {
  param([string[]]$Arguments)

  try {
    $output = & git @Arguments 2>$null
    if ($LASTEXITCODE -eq 0) {
      return (($output | Out-String).Trim())
    }
  } catch {
    return ""
  }
  return ""
}

function Get-Sha256Text {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return ""
  }
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Convert-ToRelativePath {
  param([string]$Path)

  $full = [System.IO.Path]::GetFullPath($Path)
  $rootFull = [System.IO.Path]::GetFullPath([string]$Root)
  if ($full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $full.Substring($rootFull.Length).TrimStart("\", "/") -replace "\\", "/"
  }
  return $full -replace "\\", "/"
}

function Find-FirstExistingFile {
  param([string[]]$RelativePaths)

  foreach ($relativePath in $RelativePaths) {
    $path = Join-Path $Root $relativePath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      return $path
    }
  }
  return ""
}

function Find-FirstExistingDirectory {
  param([string[]]$Paths)

  foreach ($path in $Paths) {
    if ([string]::IsNullOrWhiteSpace($path)) {
      continue
    }
    $resolved = if ([System.IO.Path]::IsPathRooted($path)) { $path } else { Join-Path $Root $path }
    if (Test-Path -LiteralPath $resolved -PathType Container) {
      return $resolved
    }
  }
  return ""
}

function Read-ToolchainPins {
  $catalogPath = Find-FirstExistingFile @(
    "companion/gradle/libs.versions.toml",
    "provenance/companion/gradle/libs.versions.toml"
  )
  $pins = [ordered]@{}
  if ([string]::IsNullOrWhiteSpace($catalogPath)) {
    return [ordered]@{
      path = ""
      versions = $pins
    }
  }

  $inVersions = $false
  foreach ($line in Get-Content -LiteralPath $catalogPath) {
    $trimmed = $line.Trim()
    if ($trimmed -eq "[versions]") {
      $inVersions = $true
      continue
    }
    if ($trimmed.StartsWith("[") -and $trimmed.EndsWith("]")) {
      $inVersions = $false
    }
    if (-not $inVersions) {
      continue
    }
    if ($trimmed -match '^([A-Za-z0-9_.-]+)\s*=\s*"([^"]+)"') {
      $pins[$matches[1]] = $matches[2]
    }
  }

  return [ordered]@{
    path = Convert-ToRelativePath $catalogPath
    versions = $pins
  }
}

function Get-ArtifactEntries {
  param(
    [string]$Kind,
    [string[]]$Roots,
    [string[]]$Patterns
  )

  $rootPath = Find-FirstExistingDirectory $Roots
  $entries = @()
  if ([string]::IsNullOrWhiteSpace($rootPath)) {
    return [ordered]@{
      kind = $Kind
      root = ""
      status = "pending"
      entries = @()
      detail = "Artifact root not found."
    }
  }

  foreach ($pattern in $Patterns) {
    $entries += @(Get-ChildItem -LiteralPath $rootPath -Recurse -File -Filter $pattern -ErrorAction SilentlyContinue | Sort-Object FullName | ForEach-Object {
      [ordered]@{
        path = Convert-ToRelativePath $_.FullName
        name = $_.Name
        bytes = $_.Length
        sha256 = Get-Sha256Text $_.FullName
      }
    })
  }

  $entries = @($entries | Sort-Object path -Unique)
  if ($entries.Count -eq 0) {
    return [ordered]@{
      kind = $Kind
      root = Convert-ToRelativePath $rootPath
      status = "pending"
      entries = @()
      detail = "No matching artifacts found."
    }
  }

  return [ordered]@{
    kind = $Kind
    root = Convert-ToRelativePath $rootPath
    status = "present"
    entries = @($entries)
    detail = "Artifacts hashed."
  }
}

function Get-PackageEvidence {
  if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
    return [ordered]@{
      status = "not-provided"
      root = ""
      files = @()
    }
  }

  $files = @()
  foreach ($relativePath in @("release_manifest.json", "release_assets.json", "COMPANION_RELEASE_EVIDENCE.json", "docs/COMPANION_CROSS_PLATFORM_PLAN.md")) {
    $path = Join-Path $PackageRoot $relativePath
    if (Test-Path -LiteralPath $path -PathType Leaf) {
      $item = Get-Item -LiteralPath $path
      $files += [ordered]@{
        path = $relativePath
        bytes = $item.Length
        sha256 = Get-Sha256Text $item.FullName
      }
    }
  }

  return [ordered]@{
    status = if ($files.Count -gt 0) { "present" } else { "empty" }
    root = Convert-ToRelativePath $PackageRoot
    files = @($files)
  }
}

$commitText = if ([string]::IsNullOrWhiteSpace($Commit)) { Get-GitText @("rev-parse", "HEAD") } else { $Commit }
$versionText = if ([string]::IsNullOrWhiteSpace($Version)) { Get-GitText @("describe", "--tags", "--always", "--dirty") } else { $Version }
$toolchainPins = Read-ToolchainPins
$planPath = Find-FirstExistingFile @("docs/COMPANION_CROSS_PLATFORM_PLAN.md")
$readinessPath = Find-FirstExistingFile @("tools/check_companion_v1_readiness.ps1")

$androidArtifacts = Get-ArtifactEntries `
  -Kind "android-apk" `
  -Roots @($AndroidArtifactRoot, "companion/app-android/build/outputs/apk/release") `
  -Patterns @("*.apk")

$desktopArtifacts = Get-ArtifactEntries `
  -Kind "desktop-package" `
  -Roots @($DesktopArtifactRoot, "output/conveyor", "output/companion/desktop") `
  -Patterns @("*.msix", "*.appinstaller", "*.deb", "*.dmg", "*.zip")

$pending = @()
if ([string]::IsNullOrWhiteSpace($planPath)) {
  $pending += "companion-cross-platform-plan"
}
if ([string]::IsNullOrWhiteSpace($readinessPath)) {
  $pending += "companion-v1-readiness-check"
}
if ($androidArtifacts.status -ne "present") {
  $pending += "android-apk-artifacts"
}
if ($desktopArtifacts.status -ne "present") {
  $pending += "desktop-distribution-artifacts"
}
if ([string]::IsNullOrWhiteSpace($toolchainPins.path)) {
  $pending += "gradle-toolchain-pins"
}

$status = if ($RequireArtifacts -and $pending.Count -gt 0) { "blocked-missing-artifacts" } elseif ($pending.Count -gt 0) { "evidence-pending-artifacts" } else { "complete" }

$report = [ordered]@{
  schema = "stackchan.companion-release-evidence.v1"
  status = $status
  version = $versionText
  commit = $commitText
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
  source = [ordered]@{
    root = [string]$Root
    packageRoot = $PackageRoot
    crossPlatformPlan = if ([string]::IsNullOrWhiteSpace($planPath)) { "" } else { Convert-ToRelativePath $planPath }
    readinessChecker = if ([string]::IsNullOrWhiteSpace($readinessPath)) { "" } else { Convert-ToRelativePath $readinessPath }
  }
  toolchainPins = $toolchainPins
  artifacts = @($androidArtifacts, $desktopArtifacts)
  packageEvidence = Get-PackageEvidence
  pending = @($pending)
}

$jsonPath = Join-Path $OutDir "COMPANION_RELEASE_EVIDENCE.json"
$mdPath = Join-Path $OutDir "COMPANION_RELEASE_EVIDENCE.md"
$report | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8

$lines = @(
  "# Companion Release Evidence",
  "",
  "- Schema: stackchan.companion-release-evidence.v1",
  "- Status: $status",
  "- Version: $versionText",
  "- Commit: $commitText",
  "- Toolchain pins: $($toolchainPins.path)",
  "",
  "## Artifacts"
)
foreach ($artifactGroup in $report.artifacts) {
  $lines += ""
  $lines += "### $($artifactGroup.kind)"
  $lines += "- Status: $($artifactGroup.status)"
  $lines += "- Root: $($artifactGroup.root)"
  if ($artifactGroup.entries.Count -eq 0) {
    $lines += "- Detail: $($artifactGroup.detail)"
  } else {
    foreach ($entry in $artifactGroup.entries) {
      $lines += "- `$($entry.path)` ($($entry.bytes) bytes, sha256 `$($entry.sha256)`)"
    }
  }
}
$lines += ""
$lines += "## Pending"
if ($pending.Count -eq 0) {
  $lines += "- None"
} else {
  foreach ($item in $pending) {
    $lines += "- $item"
  }
}
$lines | Set-Content -Path $mdPath -Encoding UTF8

if ($Json) {
  $report | ConvertTo-Json -Depth 8
} else {
  Write-Host "Companion release evidence: $status"
  Write-Host "JSON: $jsonPath"
  Write-Host "Markdown: $mdPath"
  if ($pending.Count -gt 0) {
    Write-Host "Pending: $($pending -join ', ')"
  }
}

if ($RequireArtifacts -and $pending.Count -gt 0) {
  exit 2
}
