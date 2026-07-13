param(
  [ValidateSet("windows", "linux", "macos")]
  [string]$Platform,
  [string]$PackagePath,
  [string]$RuntimePrepareJsonPath,
  [string]$ProcessedRuntimeRoot,
  [string]$Version = "",
  [string]$Commit = "",
  [string]$OutPath = "",
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

function Get-Sha256Text {
  param([string]$Path)
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Test-Sha256Text {
  param([string]$Value)
  return $Value -match '^[a-fA-F0-9]{64}$'
}

function Get-RuntimePayloadHash {
  param([string]$Root)

  $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd("\", "/")
  $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $utf8 = [System.Text.Encoding]::UTF8
  $files = Get-ChildItem -LiteralPath $Root -File -Recurse -Force |
    Where-Object {
      $_.Name -ne "stackchan-python-runtime.json" -and
      $_.FullName -notmatch "([\\/])__pycache__([\\/])"
    } |
    Sort-Object FullName

  foreach ($file in $files) {
    $full = [System.IO.Path]::GetFullPath($file.FullName)
    if (-not $full.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
      throw "Refusing to hash a processed runtime file outside its root: $full"
    }
    $relative = $full.Substring($prefix.Length).Replace("\", "/")
    $pathBytes = $utf8.GetBytes("$relative`n")
    $null = $sha.TransformBlock($pathBytes, 0, $pathBytes.Length, $pathBytes, 0)
    $fileHash = Get-Sha256Text $full
    $hashBytes = $utf8.GetBytes("$fileHash`n")
    $null = $sha.TransformBlock($hashBytes, 0, $hashBytes.Length, $hashBytes, 0)
  }

  $empty = [byte[]]@()
  $null = $sha.TransformFinalBlock($empty, 0, 0)
  return (($sha.Hash | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Add-Issue {
  param([string]$Message)
  $script:issues += $Message
}

$issues = @()
$expectedExtension = @{ windows = ".msi"; linux = ".deb"; macos = ".dmg" }[$Platform]
$package = $null
$prepare = $null
$manifest = $null
$processedHash = ""
$processedFiles = @()

if ([string]::IsNullOrWhiteSpace($PackagePath) -or -not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
  Add-Issue "Desktop package is missing: $PackagePath"
} else {
  $package = Get-Item -LiteralPath $PackagePath
  if ($package.Extension.ToLowerInvariant() -ne $expectedExtension) {
    Add-Issue "Desktop package for $Platform must use $expectedExtension, got $($package.Extension)."
  }
}

if ([string]::IsNullOrWhiteSpace($RuntimePrepareJsonPath) -or -not (Test-Path -LiteralPath $RuntimePrepareJsonPath -PathType Leaf)) {
  Add-Issue "Managed runtime prepare JSON is missing: $RuntimePrepareJsonPath"
} else {
  try {
    $prepare = Get-Content -LiteralPath $RuntimePrepareJsonPath -Raw | ConvertFrom-Json
  } catch {
    Add-Issue "Managed runtime prepare JSON is invalid: $($_.Exception.Message)"
  }
}

if ($null -ne $prepare) {
  if ([string]$prepare.schema -ne "stackchan.desktop-python-runtime-prepare.v1") { Add-Issue "Unexpected runtime prepare schema: $($prepare.schema)" }
  if ([string]$prepare.status -ne "ready") { Add-Issue "Runtime prepare status must be ready, got $($prepare.status)." }
  if ([string]$prepare.platform -ne $Platform) { Add-Issue "Runtime prepare platform must be $Platform, got $($prepare.platform)." }
  if (-not (Test-Sha256Text ([string]$prepare.payloadSha256))) { Add-Issue "Runtime prepare payloadSha256 is invalid." }
  if ($null -eq $prepare.validation) {
    Add-Issue "Runtime prepare validation report is missing."
  } else {
    if ([string]$prepare.validation.schema -ne "stackchan.desktop-python-runtime-payload.v1") { Add-Issue "Unexpected runtime validation schema: $($prepare.validation.schema)" }
    if ([string]$prepare.validation.status -ne "ready") { Add-Issue "Runtime validation status must be ready, got $($prepare.validation.status)." }
    if ([string]$prepare.validation.platform -ne $Platform) { Add-Issue "Runtime validation platform must be $Platform, got $($prepare.validation.platform)." }
    if ([string]$prepare.validation.runtimeSha256 -ne [string]$prepare.payloadSha256) { Add-Issue "Runtime prepare and validation SHA-256 values disagree." }
    if ([string]::IsNullOrWhiteSpace([string]$prepare.validation.runtimeSource) -or [string]$prepare.validation.runtimeSource -match '<|>|pending|TBD') { Add-Issue "Runtime source is missing or placeholder text." }
    if ([string]::IsNullOrWhiteSpace([string]$prepare.validation.pythonVersion)) { Add-Issue "Runtime pythonVersion is missing." }
    if ([string]::IsNullOrWhiteSpace([string]$prepare.validation.probedPythonVersion)) { Add-Issue "Runtime probedPythonVersion is missing." }
  }
}

if ([string]::IsNullOrWhiteSpace($ProcessedRuntimeRoot) -or -not (Test-Path -LiteralPath $ProcessedRuntimeRoot -PathType Container)) {
  Add-Issue "Processed desktop runtime resource is missing: $ProcessedRuntimeRoot"
} else {
  $manifestPath = Join-Path $ProcessedRuntimeRoot "stackchan-python-runtime.json"
  if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    Add-Issue "Processed desktop runtime manifest is missing."
  } else {
    try {
      $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    } catch {
      Add-Issue "Processed desktop runtime manifest is invalid JSON: $($_.Exception.Message)"
    }
  }
  $processedFiles = @(Get-ChildItem -LiteralPath $ProcessedRuntimeRoot -File -Recurse -Force)
  if ($processedFiles.Count -lt 2) { Add-Issue "Processed desktop runtime contains too few files." }
  try {
    $processedHash = Get-RuntimePayloadHash $ProcessedRuntimeRoot
  } catch {
    Add-Issue $_.Exception.Message
  }
}

if ($null -ne $manifest) {
  if ([string]$manifest.schema -ne "stackchan.desktop-python-runtime.v1") { Add-Issue "Unexpected processed runtime manifest schema: $($manifest.schema)" }
  if ([string]$manifest.platform -ne $Platform) { Add-Issue "Processed runtime platform must be $Platform, got $($manifest.platform)." }
  if ($null -ne $prepare -and [string]$manifest.sha256 -ne [string]$prepare.payloadSha256) { Add-Issue "Processed runtime manifest SHA-256 does not match runtime prepare evidence." }
}
if ($null -ne $prepare -and -not [string]::IsNullOrWhiteSpace($processedHash) -and $processedHash -ne [string]$prepare.payloadSha256) {
  Add-Issue "Processed runtime payload hash does not match runtime prepare evidence."
}

if ([string]::IsNullOrWhiteSpace($Commit)) {
  $Commit = ((& git -C $repoRoot rev-parse HEAD 2>$null) | Out-String).Trim()
}
if ([string]::IsNullOrWhiteSpace($Version)) {
  $Version = ((& git -C $repoRoot describe --tags --always --dirty 2>$null) | Out-String).Trim()
}

$packageEvidence = if ($null -eq $package) {
  [ordered]@{ name = ""; extension = $expectedExtension; bytes = 0; sha256 = "" }
} else {
  [ordered]@{ name = $package.Name; extension = $package.Extension.ToLowerInvariant(); bytes = [int64]$package.Length; sha256 = Get-Sha256Text $package.FullName }
}
$processedBytes = [int64](($processedFiles | Measure-Object -Property Length -Sum).Sum)
$report = [ordered]@{
  schema = "stackchan.desktop-package-evidence.v1"
  status = if ($issues.Count -eq 0) { "ready" } else { "not-ready" }
  platform = $Platform
  version = $Version
  commit = $Commit
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
  package = $packageEvidence
  runtime = [ordered]@{
    payloadSha256 = if ($null -eq $prepare) { "" } else { [string]$prepare.payloadSha256 }
    processedPayloadSha256 = $processedHash
    source = if ($null -eq $prepare -or $null -eq $prepare.validation) { "" } else { [string]$prepare.validation.runtimeSource }
    pythonVersion = if ($null -eq $prepare -or $null -eq $prepare.validation) { "" } else { [string]$prepare.validation.pythonVersion }
    probedPythonVersion = if ($null -eq $prepare -or $null -eq $prepare.validation) { "" } else { [string]$prepare.validation.probedPythonVersion }
    processedFileCount = $processedFiles.Count
    processedBytes = $processedBytes
  }
  issues = @($issues)
}

if ([string]::IsNullOrWhiteSpace($OutPath)) {
  $OutPath = Join-Path $repoRoot "output/companion/desktop-package-evidence/$Platform-package-evidence.json"
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutPath) | Out-Null
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutPath -Encoding UTF8

if ($Json) { $report | ConvertTo-Json -Depth 8 } else { Write-Host "Desktop package evidence: $($report.status) ($Platform)" }
if ($issues.Count -gt 0) { exit 1 }
