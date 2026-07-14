param(
  [ValidateSet("windows", "linux", "macos")]
  [string]$Platform,
  [string]$PackagePath,
  [string]$ExtractionRoot = "",
  [string]$OutPath = "",
  [int]$TimeoutSeconds = 120,
  [switch]$UseExistingPackageExtraction,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$issues = @()

function Add-Issue([string]$Message) { $script:issues += $Message }
function Get-Sha256Text([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }
function Get-HostPlatform {
  if ($IsWindows -or $env:OS -eq "Windows_NT") { return "windows" }
  if ($IsMacOS) { return "macos" }
  if ($IsLinux) { return "linux" }
  return "unknown"
}

function Expand-NativePackage([string]$TargetPlatform, [string]$SourcePackage, [string]$DestinationRoot) {
  New-Item -ItemType Directory -Path $DestinationRoot | Out-Null
  switch ($TargetPlatform) {
    "windows" {
      $msiexec = Get-Command msiexec.exe -ErrorAction Stop
      $logPath = Join-Path $DestinationRoot "msiexec-admin.log"
      $arguments = @('/a', "`"$SourcePackage`"", '/qn', "TARGETDIR=`"$DestinationRoot`"", '/L*v', "`"$logPath`"")
      $process = Start-Process -FilePath $msiexec.Source -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
      if ($process.ExitCode -ne 0) { throw "MSI administrative extraction failed with exit code $($process.ExitCode). See $logPath" }
    }
    "linux" {
      & (Get-Command dpkg-deb -ErrorAction Stop).Source -x $SourcePackage $DestinationRoot
      if ($LASTEXITCODE -ne 0) { throw "DEB extraction failed with exit code $LASTEXITCODE." }
    }
    "macos" {
      $hdiutil = (Get-Command hdiutil -ErrorAction Stop).Source
      $ditto = (Get-Command ditto -ErrorAction Stop).Source
      $mountPoint = "$DestinationRoot-mount"
      New-Item -ItemType Directory -Path $mountPoint | Out-Null
      $attached = $false
      try {
        & $hdiutil attach $SourcePackage -readonly -nobrowse -mountpoint $mountPoint | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "DMG mount failed with exit code $LASTEXITCODE." }
        $attached = $true
        $apps = @(Get-ChildItem -LiteralPath $mountPoint -Directory -Filter "*.app")
        if ($apps.Count -ne 1) { throw "Expected one application bundle in DMG; found $($apps.Count)." }
        & $ditto $apps[0].FullName (Join-Path $DestinationRoot $apps[0].Name)
        if ($LASTEXITCODE -ne 0) { throw "Application bundle copy failed with exit code $LASTEXITCODE." }
      } finally {
        if ($attached) { & $hdiutil detach $mountPoint -force | Out-Null }
      }
    }
  }
}

function Find-PackagedLauncher([string]$TargetPlatform, [string]$Root) {
  $matches = switch ($TargetPlatform) {
    "windows" { @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter "Stackchan Companion.exe" -ErrorAction SilentlyContinue) }
    "linux" { @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter "Stackchan Companion" -ErrorAction SilentlyContinue) }
    "macos" { @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter "Stackchan Companion" -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\.app[\\/]Contents[\\/]MacOS[\\/]' }) }
  }
  return @($matches)
}

$package = $null
$packageSha = ""
$launcherPath = ""
$processExitCode = $null
$probe = $null
$extractionMethod = if ($UseExistingPackageExtraction) { "existing" } else { "native" }
$expectedExtension = @{ windows = ".msi"; linux = ".deb"; macos = ".dmg" }[$Platform]

if ([string]::IsNullOrWhiteSpace($PackagePath) -or -not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
  Add-Issue "Desktop package is missing: $PackagePath"
} else {
  $package = Get-Item -LiteralPath $PackagePath
  $packageSha = Get-Sha256Text $package.FullName
  if ($package.Extension.ToLowerInvariant() -ne $expectedExtension) { Add-Issue "Desktop package for $Platform must use $expectedExtension." }
}

if ([string]::IsNullOrWhiteSpace($ExtractionRoot)) {
  $ExtractionRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-package-launch-{0}-{1}" -f $Platform, [guid]::NewGuid().ToString("N").Substring(0, 12))
}
$ExtractionRoot = [System.IO.Path]::GetFullPath($ExtractionRoot)
if ([string]::IsNullOrWhiteSpace($OutPath)) {
  $OutPath = Join-Path $repoRoot "output/companion/desktop-package-launch/$Platform-package-launch.json"
}
$OutPath = [System.IO.Path]::GetFullPath($OutPath)

if ($null -ne $package -and $issues.Count -eq 0) {
  if ((Get-HostPlatform) -ne $Platform) {
    Add-Issue "Exact package launch for $Platform must run on a native $Platform host."
  } elseif ($UseExistingPackageExtraction) {
    if (-not (Test-Path -LiteralPath $ExtractionRoot -PathType Container)) { Add-Issue "Existing package extraction root was not found: $ExtractionRoot" }
  } elseif (Test-Path -LiteralPath $ExtractionRoot) {
    Add-Issue "Package extraction root already exists; refusing to overwrite it: $ExtractionRoot"
  } else {
    try { Expand-NativePackage $Platform $package.FullName $ExtractionRoot } catch { Add-Issue $_.Exception.Message }
  }
}

if (Test-Path -LiteralPath $ExtractionRoot -PathType Container) {
  $launchers = @(Find-PackagedLauncher $Platform $ExtractionRoot)
  if ($launchers.Count -ne 1) {
    Add-Issue "Expected exactly one packaged launcher for $Platform; found $($launchers.Count)."
  } else {
    $launcherPath = $launchers[0].FullName
    $probePath = Join-Path (Split-Path -Parent $OutPath) "$Platform-packaged-runtime-smoke.json"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $probePath) | Out-Null
    try {
      $argument = "--package-smoke-output=`"$probePath`""
      $process = Start-Process -FilePath $launcherPath -ArgumentList $argument -PassThru
      if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill()
        Add-Issue "Packaged launcher smoke timed out after $TimeoutSeconds seconds."
      } else {
        $processExitCode = $process.ExitCode
        if ($processExitCode -ne 0) { Add-Issue "Packaged launcher smoke exited with code $processExitCode." }
      }
    } catch {
      Add-Issue "Packaged launcher smoke could not start: $($_.Exception.Message)"
    }
    if (-not (Test-Path -LiteralPath $probePath -PathType Leaf)) {
      Add-Issue "Packaged launcher did not write its runtime smoke report."
    } else {
      try { $probe = Get-Content -LiteralPath $probePath -Raw | ConvertFrom-Json } catch { Add-Issue "Packaged runtime smoke report is invalid JSON: $($_.Exception.Message)" }
    }
  }
}

if ($null -ne $probe) {
  if ([string]$probe.schema -ne "stackchan.desktop-packaged-runtime-smoke.v1") { Add-Issue "Packaged runtime smoke schema is invalid." }
  if ([string]$probe.status -ne "ready") { Add-Issue "Packaged runtime smoke status is not ready." }
  if ([string]$probe.platform -ne $Platform) { Add-Issue "Packaged runtime smoke platform mismatch." }
  if ([string]$probe.appVersion -ne "1.0.0" -or [string]$probe.protocol -ne "stackchan.bridge.v1") { Add-Issue "Packaged runtime identity is invalid." }
  if ($probe.runtimePresent -ne $true -or $probe.pythonAvailable -ne $true -or $probe.brainScriptAvailable -ne $true) { Add-Issue "Packaged runtime smoke did not prove runtime, Python, and brain readiness." }
  if (@($probe.issues).Count -ne 0) { Add-Issue "Packaged runtime smoke reported issues." }
  if ([string]$probe.scope -ne "extracted-native-package-headless-runtime-probe" -or $probe.substitutesForTargetInstall -ne $false) { Add-Issue "Packaged runtime smoke scope is invalid." }
  foreach ($pathField in @("runtimeRoot", "runtimeManifest", "runtimeExecutable", "brainScript")) {
    $value = [string]$probe.$pathField
    if ([string]::IsNullOrWhiteSpace($value) -or -not (Test-Path -LiteralPath $value)) { Add-Issue "Packaged runtime smoke path is missing: $pathField" }
  }
}

$report = [ordered]@{
  schema = "stackchan.desktop-package-launch-evidence.v1"
  status = if ($issues.Count -eq 0) { "ready" } else { "not-ready" }
  platform = $Platform
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
  package = if ($null -eq $package) { [ordered]@{ name = ""; bytes = 0; sha256 = "" } } else { [ordered]@{ name = $package.Name; bytes = [int64]$package.Length; sha256 = $packageSha } }
  extractionMethod = $extractionMethod
  extractionRoot = $ExtractionRoot
  launcherPath = $launcherPath
  processExitCode = $processExitCode
  probe = $probe
  scope = "exact-native-package-extraction-and-headless-launch"
  substitutesForTargetInstall = $false
  issues = @($issues)
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutPath) | Out-Null
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutPath -Encoding UTF8
if ($Json) { $report | ConvertTo-Json -Depth 10 } else { Write-Host "Desktop package launch evidence: $($report.status) ($Platform)" }
if ($issues.Count -gt 0) { exit 1 }
