param(
  [string]$Version = "",
  [string]$Commit = "",
  [string]$Root = "",
  [string]$PackageRoot = "",
  [string]$AndroidArtifactRoot = "",
  [string]$DesktopArtifactRoot = "",
  [string]$DesktopPythonRuntimeRoot = "",
  [string]$DesktopPackageEvidenceRoot = "",
  [string]$AndroidEmulatorEvidencePath = "",
  [string]$ApkSignerPath = "",
  [string]$OutDir = "",
  [switch]$RequireArtifacts,
  [switch]$RequireUploadSigning,
  [switch]$RequireDesktopPythonRuntime,
  [switch]$RequireDesktopPackageEvidence,
  [switch]$RequireDesktopDistributionTrust,
  [switch]$RequireAndroidEmulatorEvidence,
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

function Get-CommandPath {
  param([string]$Name)

  $command = Get-Command $Name -ErrorAction SilentlyContinue
  if ($command) {
    return [string]$command.Source
  }
  return ""
}

function Find-PowerShellRunner {
  foreach ($commandName in @("pwsh", "powershell")) {
    $path = Get-CommandPath $commandName
    if (-not [string]::IsNullOrWhiteSpace($path)) {
      return $path
    }
  }
  return ""
}

function Find-ApkSigner {
  if (-not [string]::IsNullOrWhiteSpace($ApkSignerPath)) {
    if (Test-Path -LiteralPath $ApkSignerPath -PathType Leaf) {
      return [string](Resolve-Path $ApkSignerPath)
    }
    return $ApkSignerPath
  }

  foreach ($commandName in @("apksigner", "apksigner.bat")) {
    $path = Get-CommandPath $commandName
    if (-not [string]::IsNullOrWhiteSpace($path)) {
      return $path
    }
  }

  $localAndroidSdk = if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { "" } else { Join-Path $env:LOCALAPPDATA "Android/Sdk" }
  $sdkRoots = @($env:ANDROID_HOME, $env:ANDROID_SDK_ROOT, $localAndroidSdk) |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Select-Object -Unique
  foreach ($sdkRoot in $sdkRoots) {
    if (-not (Test-Path -LiteralPath $sdkRoot -PathType Container)) {
      continue
    }
    $candidate = Get-ChildItem -LiteralPath $sdkRoot -Recurse -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -in @("apksigner", "apksigner.bat") } |
      Sort-Object FullName -Descending |
      Select-Object -First 1
    if ($candidate) {
      return [string]$candidate.FullName
    }
  }

  return ""
}

function Find-JarSigner {
  foreach ($commandName in @("jarsigner", "jarsigner.exe")) {
    $path = Get-CommandPath $commandName
    if (-not [string]::IsNullOrWhiteSpace($path)) {
      return $path
    }
  }

  $javaHome = $env:JAVA_HOME
  if (-not [string]::IsNullOrWhiteSpace($javaHome)) {
    foreach ($relativePath in @("bin/jarsigner", "bin/jarsigner.exe")) {
      $candidate = Join-Path $javaHome $relativePath
      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return [string](Resolve-Path $candidate)
      }
    }
  }

  return ""
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

  $entries = @(
    $entries |
      Group-Object { [string]$_["path"] } |
      ForEach-Object { $_.Group[0] } |
      Sort-Object { [string]$_["path"] }
  )
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
  -Roots @($AndroidArtifactRoot, "companion/app-android/build/outputs", "companion/app-android/build/outputs/apk/release") `
  -Patterns @("*.apk", "*.aab")

$desktopArtifacts = Get-ArtifactEntries `
  -Kind "desktop-package" `
  -Roots @($DesktopArtifactRoot, "output/conveyor", "output/companion/desktop") `
  -Patterns @("*.msi", "*.msix", "*.appinstaller", "*.deb", "*.dmg", "*.zip")

function Test-ArtifactEntryPattern {
  param(
    [object]$ArtifactGroup,
    [string]$Pattern
  )

  foreach ($entry in @($ArtifactGroup.entries)) {
    $name = [string]$entry["name"]
    $path = [string]$entry["path"]
    if ($name -match $Pattern -or $path -match $Pattern) {
      return $true
    }
  }
  return $false
}

function Get-AndroidApkEntry {
  param(
    [object]$ArtifactGroup,
    [ValidateSet("debug", "release")]
    [string]$Flavor
  )

  foreach ($entry in @($ArtifactGroup.entries)) {
    $name = [string]$entry["name"]
    $path = [string]$entry["path"]
    if ($name -match "$Flavor.*\.apk$" -or $path -match "(^|[\\/])$Flavor[\\/][^\\/]+\.apk$") {
      return $entry
    }
  }
  return $null
}

function Get-AndroidReleaseAabEntry {
  param([object]$ArtifactGroup)

  foreach ($entry in @($ArtifactGroup.entries)) {
    $name = [string]$entry["name"]
    $path = [string]$entry["path"]
    if ($name -match "release.*\.aab$" -or $path -match "(^|[\\/])release[\\/][^\\/]+\.aab$") {
      return $entry
    }
  }
  return $null
}

function Test-AndroidReleaseApkSignature {
  param([object]$ArtifactGroup)

  $releaseEntry = Get-AndroidApkEntry $ArtifactGroup "release"
  if ($null -eq $releaseEntry) {
    return [ordered]@{
      status = "pending"
      apk = ""
      verifier = ""
      scheme = ""
      signer = ""
      detail = "Release APK artifact not found."
    }
  }

  $apkPath = [string]$releaseEntry["path"]
  if (-not [System.IO.Path]::IsPathRooted($apkPath)) {
    $apkPath = Join-Path $Root $apkPath
  }
  if (-not (Test-Path -LiteralPath $apkPath -PathType Leaf)) {
    return [ordered]@{
      status = "pending"
      apk = [string]$releaseEntry["path"]
      verifier = ""
      scheme = ""
      signer = ""
      detail = "Release APK path was recorded but does not exist on disk."
    }
  }

  $resolvedApkSigner = Find-ApkSigner
  if ([string]::IsNullOrWhiteSpace($resolvedApkSigner)) {
    return [ordered]@{
      status = "pending"
      apk = [string]$releaseEntry["path"]
      verifier = ""
      scheme = ""
      signer = ""
      detail = "apksigner was not found; install Android build-tools or pass -ApkSignerPath."
    }
  }

  $output = @()
  try {
    $output = @(& $resolvedApkSigner verify --verbose --print-certs $apkPath 2>&1)
    $exitCode = $LASTEXITCODE
  } catch {
    $output = @($_.Exception.Message)
    $exitCode = 1
  }

  $text = (($output | Out-String).Trim())
  $verified = $exitCode -eq 0 -and $text -match "(?m)^Verifies\s*$"
  $scheme = ""
  if ($text -match "Verified using v2 scheme \(APK Signature Scheme v2\): true") {
    $scheme = "v2"
  } elseif ($text -match "Verified using v3 scheme \(APK Signature Scheme v3\): true") {
    $scheme = "v3"
  } elseif ($text -match "Verified using v1 scheme \(JAR signing\): true") {
    $scheme = "v1"
  }
  $signer = ""
  if ($text -match "Signer #1 certificate DN:\s*(.+)") {
    $signer = $matches[1].Trim()
  }
  $signingProfile = if ($signer -match "CN=Android Debug") { "lab-debug-fallback" } elseif ([string]::IsNullOrWhiteSpace($signer)) { "unknown" } else { "upload-key" }

  return [ordered]@{
    status = if ($verified) { "verified" } else { "failed" }
    apk = [string]$releaseEntry["path"]
    verifier = $resolvedApkSigner
    scheme = $scheme
    signer = $signer
    signingProfile = $signingProfile
    detail = if ($verified) {
      if ($signingProfile -eq "lab-debug-fallback") {
        "Release APK signature verified by apksigner with the Android debug certificate; lab install only, not Play upload signing."
      } else {
        "Release APK signature verified by apksigner."
      }
    } else { "apksigner verification failed: $text" }
  }
}

$androidBundleSigning = [ordered]@{
  status = "pending"
  bundle = ""
  verifier = ""
  signer = ""
  detail = "Release AAB artifact not found."
}

function Test-AndroidReleaseBundleSignature {
  param([object]$ArtifactGroup)

  $releaseEntry = Get-AndroidReleaseAabEntry $ArtifactGroup
  if ($null -eq $releaseEntry) {
    return [ordered]@{
      status = "pending"
      bundle = ""
      verifier = ""
      signer = ""
      detail = "Release AAB artifact not found."
    }
  }

  $bundlePath = [string]$releaseEntry["path"]
  if (-not [System.IO.Path]::IsPathRooted($bundlePath)) {
    $bundlePath = Join-Path $Root $bundlePath
  }
  if (-not (Test-Path -LiteralPath $bundlePath -PathType Leaf)) {
    return [ordered]@{
      status = "pending"
      bundle = [string]$releaseEntry["path"]
      verifier = ""
      signer = ""
      detail = "Release AAB path was recorded but does not exist on disk."
    }
  }

  $resolvedJarSigner = Find-JarSigner
  if ([string]::IsNullOrWhiteSpace($resolvedJarSigner)) {
    return [ordered]@{
      status = "pending"
      bundle = [string]$releaseEntry["path"]
      verifier = ""
      signer = ""
      detail = "jarsigner was not found; install a JDK or set JAVA_HOME."
    }
  }

  $output = @()
  try {
    $output = @(& $resolvedJarSigner -verify -certs -verbose $bundlePath 2>&1)
    $exitCode = $LASTEXITCODE
  } catch {
    $output = @($_.Exception.Message)
    $exitCode = 1
  }

  $text = (($output | Out-String).Trim())
  $verified = $exitCode -eq 0 -and $text -match "jar verified"
  $signer = ""
  if ($text -match "X\.509,\s*([^`r`n]+)") {
    $signer = $matches[1].Trim()
  }
  $signingProfile = if ($text -match "CN=Android Debug") { "lab-debug-fallback" } elseif ([string]::IsNullOrWhiteSpace($signer)) { "unknown" } else { "upload-key" }

  return [ordered]@{
    status = if ($verified) { "verified" } else { "failed" }
    bundle = [string]$releaseEntry["path"]
    verifier = $resolvedJarSigner
    signer = $signer
    signingProfile = $signingProfile
    detail = if ($verified) {
      if ($signingProfile -eq "lab-debug-fallback") {
        "Release AAB signature verified by jarsigner with the Android debug certificate; lab evidence only, not Play upload signing."
      } else {
        "Release AAB signature verified by jarsigner."
      }
    } else { "jarsigner verification failed: $text" }
  }
}

function Get-AndroidEmulatorReleaseEvidence {
  $releaseEntry = Get-AndroidApkEntry $androidArtifacts "release"
  if ($null -eq $releaseEntry) {
    return [ordered]@{
      status = "pending"
      checker = ""
      evidence = ""
      releaseApk = ""
      releaseApkSha256 = ""
      smoke = $null
      issues = @("Release APK artifact not found for emulator evidence binding.")
    }
  }

  $releaseApkPath = [string]$releaseEntry["path"]
  if (-not [System.IO.Path]::IsPathRooted($releaseApkPath)) {
    $releaseApkPath = Join-Path $Root $releaseApkPath
  }
  if (-not (Test-Path -LiteralPath $releaseApkPath -PathType Leaf)) {
    return [ordered]@{
      status = "pending"
      checker = ""
      evidence = ""
      releaseApk = [string]$releaseEntry["path"]
      releaseApkSha256 = ""
      smoke = $null
      issues = @("Release APK path does not exist for emulator evidence binding.")
    }
  }

  $resolvedEvidencePath = ""
  foreach ($candidatePath in @(
    $AndroidEmulatorEvidencePath,
    "output/android-emulator-smoke/latest/android_emulator_launch_smoke.json",
    "output/companion/ci-artifacts/companion-android-emulator-smoke/android_emulator_launch_smoke.json",
    "output/companion/release-input/android-emulator/android_emulator_launch_smoke.json"
  )) {
    if ([string]::IsNullOrWhiteSpace($candidatePath)) {
      continue
    }
    $candidate = if ([System.IO.Path]::IsPathRooted($candidatePath)) { $candidatePath } else { Join-Path $Root $candidatePath }
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      $resolvedEvidencePath = [string](Resolve-Path -LiteralPath $candidate)
      break
    }
  }
  if ([string]::IsNullOrWhiteSpace($resolvedEvidencePath)) {
    return [ordered]@{
      status = "pending"
      checker = ""
      evidence = $AndroidEmulatorEvidencePath
      releaseApk = [string]$releaseEntry["path"]
      releaseApkSha256 = Get-Sha256Text $releaseApkPath
      smoke = $null
      issues = @("Android emulator launch evidence was not found.")
    }
  }

  $checkerPath = Join-Path $Root "tools/check_android_emulator_release_evidence.ps1"
  if (-not (Test-Path -LiteralPath $checkerPath -PathType Leaf)) {
    return [ordered]@{
      status = "failed"
      checker = ""
      evidence = Convert-ToRelativePath $resolvedEvidencePath
      releaseApk = [string]$releaseEntry["path"]
      releaseApkSha256 = Get-Sha256Text $releaseApkPath
      smoke = $null
      issues = @("Android emulator release evidence checker is missing.")
    }
  }

  $powerShellRunner = Find-PowerShellRunner
  if ([string]::IsNullOrWhiteSpace($powerShellRunner)) {
    return [ordered]@{
      status = "failed"
      checker = Convert-ToRelativePath $checkerPath
      evidence = Convert-ToRelativePath $resolvedEvidencePath
      releaseApk = [string]$releaseEntry["path"]
      releaseApkSha256 = Get-Sha256Text $releaseApkPath
      smoke = $null
      issues = @("Neither pwsh nor powershell was found for the Android emulator evidence checker.")
    }
  }

  $checkerOutput = @()
  $checkerExitCode = -1
  $oldErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $checkerOutput = @(& $powerShellRunner -NoProfile -File $checkerPath -EvidencePath $resolvedEvidencePath -ReleaseApkPath $releaseApkPath -Json 2>&1)
    $checkerExitCode = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $oldErrorActionPreference
  }
  $checkerText = ($checkerOutput | Out-String).Trim()
  try {
    $checkerReport = $checkerText | ConvertFrom-Json
  } catch {
    return [ordered]@{
      status = "failed"
      checker = Convert-ToRelativePath $checkerPath
      evidence = Convert-ToRelativePath $resolvedEvidencePath
      releaseApk = [string]$releaseEntry["path"]
      releaseApkSha256 = Get-Sha256Text $releaseApkPath
      smoke = $null
      issues = @("Android emulator evidence checker did not return valid JSON (exit $checkerExitCode).")
    }
  }

  $checkerStatus = [string]$checkerReport.status
  $checkerIssues = @($checkerReport.issues)
  if (($checkerExitCode -eq 0) -ne ($checkerStatus -eq "ready")) {
    $checkerStatus = "failed"
    $checkerIssues += "Android emulator evidence checker status and exit code were inconsistent (status '$($checkerReport.status)', exit $checkerExitCode)."
  }

  return [ordered]@{
    status = $checkerStatus
    checkerExitCode = $checkerExitCode
    checker = Convert-ToRelativePath $checkerPath
    evidence = Convert-ToRelativePath $resolvedEvidencePath
    releaseApk = [string]$releaseEntry["path"]
    releaseApkSha256 = [string]$checkerReport.releaseApkSha256
    smoke = $checkerReport.evidence
    issues = $checkerIssues
  }
}

function Get-DesktopPythonRuntimeEvidence {
  $checkerPath = Join-Path $Root "tools/check_desktop_python_runtime_payload.ps1"
  if (-not (Test-Path -LiteralPath $checkerPath -PathType Leaf)) {
    return [ordered]@{
      status = "pending"
      runtimeRoot = ""
      checks = @()
      detail = "Desktop Python runtime payload checker is missing."
    }
  }

  $powerShellRunner = Find-PowerShellRunner
  if ([string]::IsNullOrWhiteSpace($powerShellRunner)) {
    return [ordered]@{
      status = "failed"
      runtimeRoot = $DesktopPythonRuntimeRoot
      checks = @()
      detail = "Neither pwsh nor powershell was found for the desktop Python runtime checker."
    }
  }

  $runtimeRootArg = $DesktopPythonRuntimeRoot
  if ([string]::IsNullOrWhiteSpace($runtimeRootArg)) {
    $runtimeRootArg = $env:STACKCHAN_BRAIN_PYTHON_RUNTIME
  }

  $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $checkerPath, "-Json")
  if (-not [string]::IsNullOrWhiteSpace($runtimeRootArg)) {
    $arguments += @("-RuntimeRoot", $runtimeRootArg)
  }

  $output = @()
  try {
    $output = @(& $powerShellRunner @arguments 2>&1)
    $exitCode = $LASTEXITCODE
  } catch {
    $output = @($_.Exception.Message)
    $exitCode = 1
  }

  $text = (($output | Out-String).Trim())
  try {
    $parsed = $text | ConvertFrom-Json
  } catch {
    return [ordered]@{
      status = "failed"
      runtimeRoot = $runtimeRootArg
      checks = @()
      detail = "Desktop Python runtime checker did not return JSON: $text"
    }
  }

  return [ordered]@{
    status = [string]$parsed.status
    runtimeRoot = [string]$parsed.runtimeRoot
    checks = @($parsed.checks)
    detail = if ($exitCode -eq 0) { "Desktop Python runtime payload checker completed." } else { "Desktop Python runtime payload checker reported a failure." }
  }
}

function Get-DesktopPackageEvidence {
  $evidenceRoot = Find-FirstExistingDirectory @($DesktopPackageEvidenceRoot, $DesktopArtifactRoot)
  if ([string]::IsNullOrWhiteSpace($evidenceRoot)) {
    return [ordered]@{
      status = "pending"
      root = ""
      platforms = @()
      issues = @("Desktop package evidence root was not found.")
    }
  }

  $issues = @()
  $summaries = @()
  $files = @(Get-ChildItem -LiteralPath $evidenceRoot -Recurse -File -Filter "*-package-evidence.json" -ErrorAction SilentlyContinue)
  $parsedReports = @()
  foreach ($file in $files) {
    try {
      $parsedReports += [pscustomobject]@{ path = $file.FullName; report = (Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json) }
    } catch {
      $issues += "Desktop package evidence is invalid JSON: $($file.FullName)"
    }
  }

  $expected = [ordered]@{ windows = ".msi"; linux = ".deb"; macos = ".dmg" }
  $requiredBrainFiles = @(
    "brain/bridge/lan_service.py",
    "brain/bridge/reference_bridge.py",
    "brain/data/voice_source_provenance.yaml",
    "brain/docs/media/voice/stackchan_spark_greeting.wav"
  )
  foreach ($platform in $expected.Keys) {
    $matches = @($parsedReports | Where-Object { [string]$_.report.platform -eq $platform })
    if ($matches.Count -ne 1) {
      $issues += "Expected exactly one desktop package evidence report for $platform; found $($matches.Count)."
      continue
    }
    $path = $matches[0].path
    $item = $matches[0].report
    if ([string]$item.schema -ne "stackchan.desktop-package-evidence.v1") { $issues += "Desktop package evidence for $platform has unexpected schema." }
    if ([string]$item.status -ne "ready") { $issues += "Desktop package evidence for $platform is not ready." }
    if ([string]$item.version -ne $versionText) { $issues += "Desktop package evidence version mismatch for $platform." }
    if ([string]$item.commit -ne $commitText) { $issues += "Desktop package evidence commit mismatch for $platform." }
    if ([string]$item.package.extension -ne [string]$expected[$platform]) { $issues += "Desktop package evidence extension mismatch for $platform." }
    $packageSha = ([string]$item.package.sha256).ToLowerInvariant()
    if ($packageSha -notmatch '^[a-f0-9]{64}$') { $issues += "Desktop package evidence SHA-256 is invalid for $platform." }
    $artifactMatches = @($desktopArtifacts.entries | Where-Object {
      ([string]$_['sha256']).ToLowerInvariant() -eq $packageSha -and
      ([string]$_['path']).EndsWith([string]$expected[$platform], [System.StringComparison]::OrdinalIgnoreCase)
    })
    if ($artifactMatches.Count -ne 1) { $issues += "Desktop package evidence does not match exactly one downloaded $platform artifact." }
    $payloadSha = ([string]$item.runtime.payloadSha256).ToLowerInvariant()
    $processedSha = ([string]$item.runtime.processedPayloadSha256).ToLowerInvariant()
    if ($payloadSha -notmatch '^[a-f0-9]{64}$' -or $processedSha -ne $payloadSha) { $issues += "Processed runtime payload hash mismatch for $platform." }
    if ([int64]$item.runtime.processedFileCount -lt 2 -or [int64]$item.runtime.processedBytes -le 0) { $issues += "Processed runtime payload summary is incomplete for $platform." }
    foreach ($field in @("source", "pythonVersion", "probedPythonVersion")) {
      if ([string]::IsNullOrWhiteSpace([string]$item.runtime.$field)) { $issues += "Desktop runtime $field is missing for $platform." }
    }
    $installer = $item.installerPayload
    $installerAppJarName = ""
    $installerAppJarSha = ""
    $installerPackageSha = ""
    $installerRuntimeSha = ""
    $installerFileCount = 0
    $installerBytes = 0
    $installerBrainFiles = @()
    $installerExtractionMethod = ""
    $installerContentIdentityStatus = ""
    $installerSignatureNormalizedFileCount = 0
    $distributionTrustStatus = ""
    $distributionTrustPolicy = ""
    $distributionTrustSigner = ""
    $distributionTrustTimestamped = $false
    $distributionTrustNotarizationStapled = $false
    $distributionTrustGatekeeperAccepted = $false
    if ($null -eq $installer) {
      $issues += "Installer-derived runtime evidence is missing for $platform."
    } else {
      $installerAppJarName = [string]$installer.appJarName
      $installerAppJarSha = ([string]$installer.appJarSha256).ToLowerInvariant()
      $installerPackageSha = ([string]$installer.packageSha256).ToLowerInvariant()
      $installerRuntimeSha = ([string]$installer.runtimePayloadSha256).ToLowerInvariant()
      $installerFileCount = [int64]$installer.runtimeFileCount
      $installerBytes = [int64]$installer.runtimeBytes
      $installerBrainFiles = @($installer.requiredBrainFiles | ForEach-Object { [string]$_ })
      $installerExtractionMethod = [string]$installer.extractionMethod
      $installerContentIdentityStatus = [string]$installer.contentIdentityStatus
      if ($installer.required -ne $true -or [string]$installer.status -ne "ready") { $issues += "Installer-derived runtime evidence is not required and ready for $platform." }
      if ($installerExtractionMethod -ne "native") { $issues += "Installer payload extraction was not performed natively for $platform." }
      if ([string]$installer.runtimeLocation -ne "native-app-resources" -or [string]::IsNullOrWhiteSpace([string]$installer.runtimeRootRelative)) { $issues += "Installer runtime is not external native app resources for $platform." }
      if ($installerAppJarName -notmatch '^app-desktop-.+\.jar$' -or $installerAppJarSha -notmatch '^[a-f0-9]{64}$') { $issues += "Installer application JAR evidence is invalid for $platform." }
      if ($installerPackageSha -ne $packageSha) { $issues += "Installer payload package hash mismatch for $platform." }
      $exactContentIdentity = $installerContentIdentityStatus -eq "ready-exact" -and
        $installerRuntimeSha -eq $payloadSha -and $installerRuntimeSha -eq $processedSha
      $signatureNormalizedContentIdentity = $false
      if ($platform -eq "macos" -and $installerContentIdentityStatus -eq "ready-signature-normalized") {
        $normalization = $installer.signatureNormalization
        $normalizationFiles = @($normalization.files)
        $installerSignatureNormalizedFileCount = [int]$normalization.changedFileCount
        $normalizationFilesValid = $installerSignatureNormalizedFileCount -gt 0 -and
          $normalizationFiles.Count -eq $installerSignatureNormalizedFileCount
        $normalizationPaths = New-Object System.Collections.Generic.List[string]
        foreach ($proof in $normalizationFiles) {
          $proofPath = [string]$proof.path
          $normalizationPaths.Add($proofPath)
          $architectureProofs = @($proof.architectures)
          $architecturesValid = $architectureProofs.Count -gt 0
          $architectureNames = New-Object System.Collections.Generic.List[string]
          foreach ($architectureProof in $architectureProofs) {
            $architectureNames.Add([string]$architectureProof.architecture)
            if ([string]::IsNullOrWhiteSpace([string]$architectureProof.architecture) -or
                ([string]$architectureProof.codeContentSha256).ToLowerInvariant() -notmatch '^[a-f0-9]{64}$' -or
                [int64]$architectureProof.codeBytes -le 0 -or
                [int64]$architectureProof.processedSignatureBytes -le 0 -or
                [int64]$architectureProof.installerSignatureBytes -le 0 -or
                $architectureProof.installerSignatureVerified -ne $true -or
                [int64]$architectureProof.processedLinkEditFileBytes -le 0 -or
                [int64]$architectureProof.installerLinkEditFileBytes -le 0 -or
                [int64]$architectureProof.processedLinkEditVirtualBytes -le 0 -or
                [int64]$architectureProof.installerLinkEditVirtualBytes -le 0) {
              $architecturesValid = $false
            }
          }
          if (@($architectureNames | Sort-Object -Unique).Count -ne $architectureNames.Count) {
            $architecturesValid = $false
          }
          if ([string]::IsNullOrWhiteSpace($proofPath) -or
              ([string]$proof.processedFileSha256).ToLowerInvariant() -notmatch '^[a-f0-9]{64}$' -or
              ([string]$proof.installerFileSha256).ToLowerInvariant() -notmatch '^[a-f0-9]{64}$' -or
              ([string]$proof.normalizedFileSha256).ToLowerInvariant() -notmatch '^[a-f0-9]{64}$' -or
              ([string]$proof.processedFileSha256).ToLowerInvariant() -eq ([string]$proof.installerFileSha256).ToLowerInvariant() -or
              -not $architecturesValid) {
            $normalizationFilesValid = $false
          }
        }
        if (@($normalizationPaths | Sort-Object -Unique).Count -ne $normalizationPaths.Count) {
          $normalizationFilesValid = $false
        }
        $signatureNormalizedContentIdentity = $normalization.status -eq "ready" -and
          [string]$normalization.tool -eq "codesign" -and
          ([string]$normalization.processedPayloadSha256).ToLowerInvariant() -eq $processedSha -and
          ([string]$normalization.installerPayloadSha256).ToLowerInvariant() -eq $installerRuntimeSha -and
          $installerRuntimeSha -match '^[a-f0-9]{64}$' -and
          $normalizationFilesValid
      }
      if (-not $exactContentIdentity -and -not $signatureNormalizedContentIdentity) {
        $issues += "Installer runtime payload identity is invalid for $platform."
      }
      if ([string]$installer.runtimeManifestSchema -ne "stackchan.desktop-python-runtime.v1" -or
          [string]$installer.runtimeManifestPlatform -ne $platform -or
          ([string]$installer.runtimeManifestSha256).ToLowerInvariant() -ne $payloadSha) {
        $issues += "Installer runtime manifest evidence is invalid for $platform."
      }
      if ($installerFileCount -ne [int64]$item.runtime.processedFileCount -or
          ($exactContentIdentity -and $installerBytes -ne [int64]$item.runtime.processedBytes) -or
          $installerFileCount -lt 2 -or $installerBytes -le 0) {
        $issues += "Installer runtime payload summary does not match processed resources for $platform."
      }
      foreach ($brainPath in $requiredBrainFiles) {
        if ($installerBrainFiles -notcontains $brainPath) { $issues += "Installer brain resource evidence is missing for $platform`: $brainPath" }
      }
    }
    $launch = $item.launchEvidence
    $launchPackageSha = ""
    $launchPythonVersion = ""
    if ($null -eq $launch) {
      $issues += "Exact desktop package launch evidence is missing for $platform."
    } else {
      $launchPackageSha = ([string]$launch.packageSha256).ToLowerInvariant()
      $launchPythonVersion = [string]$launch.pythonVersion
      if ($launch.required -ne $true -or [string]$launch.status -ne "ready") { $issues += "Exact desktop package launch evidence is not required and ready for $platform." }
      if ($launchPackageSha -ne $packageSha) { $issues += "Exact desktop package launch hash mismatch for $platform." }
      if ([string]$launch.extractionMethod -ne "native" -or [int]$launch.processExitCode -ne 0) { $issues += "Exact desktop package was not natively extracted and launched for $platform." }
      if ([string]$launch.scope -ne "exact-native-package-extraction-and-headless-launch" -or [string]::IsNullOrWhiteSpace($launchPythonVersion)) { $issues += "Exact desktop package launch probe is incomplete for $platform." }
    }
    $trust = $item.distributionTrust
    if ($null -eq $trust) {
      if ($RequireDesktopDistributionTrust -and $platform -ne "linux") {
        $issues += "Native desktop distribution trust evidence is missing for $platform."
      }
    } else {
      $distributionTrustStatus = [string]$trust.status
      $distributionTrustPolicy = [string]$trust.policy
      $distributionTrustSigner = [string]$trust.signerSubject
      $distributionTrustTimestamped = -not [string]::IsNullOrWhiteSpace([string]$trust.timestampThumbprint)
      $distributionTrustNotarizationStapled = [bool]$trust.notarizationStapled
      $distributionTrustGatekeeperAccepted = [bool]$trust.gatekeeperAccepted
      if ($RequireDesktopDistributionTrust -and $platform -ne "linux") {
        $expectedTrustPolicy = if ($platform -eq "windows") { "authenticode-sha256-timestamped" } else { "developer-id-notarized-stapled" }
        if ($trust.required -ne $true -or $distributionTrustStatus -ne "ready" -or
            $distributionTrustPolicy -ne $expectedTrustPolicy -or
            ([string]$trust.packageSha256).ToLowerInvariant() -ne $packageSha -or
            [string]::IsNullOrWhiteSpace($distributionTrustSigner) -or
            [string]$trust.signatureStatus -ne "Valid") {
          $issues += "Native desktop distribution trust evidence is incomplete for $platform."
        } elseif ($platform -eq "windows" -and -not $distributionTrustTimestamped) {
          $issues += "Windows desktop distribution trust is missing its timestamp proof."
        } elseif ($platform -eq "macos" -and (-not $distributionTrustNotarizationStapled -or -not $distributionTrustGatekeeperAccepted)) {
          $issues += "macOS desktop distribution trust is missing notarization or Gatekeeper proof."
        }
      }
    }
    $summaries += [ordered]@{
      platform = $platform
      path = Convert-ToRelativePath $path
      packageName = [string]$item.package.name
      packageBytes = [int64]$item.package.bytes
      packageSha256 = $packageSha
      runtimeSha256 = $payloadSha
      runtimeSource = [string]$item.runtime.source
      pythonVersion = [string]$item.runtime.pythonVersion
      probedPythonVersion = [string]$item.runtime.probedPythonVersion
      processedFileCount = [int64]$item.runtime.processedFileCount
      processedBytes = [int64]$item.runtime.processedBytes
      installerExtractionMethod = $installerExtractionMethod
      installerAppJarName = $installerAppJarName
      installerAppJarSha256 = $installerAppJarSha
      installerPackageSha256 = $installerPackageSha
      installerRuntimeSha256 = $installerRuntimeSha
      installerRuntimeFileCount = $installerFileCount
      installerRuntimeBytes = $installerBytes
      installerContentIdentityStatus = $installerContentIdentityStatus
      installerSignatureNormalizedFileCount = $installerSignatureNormalizedFileCount
      installerBrainFiles = @($installerBrainFiles)
      launchPackageSha256 = $launchPackageSha
      launchPythonVersion = $launchPythonVersion
      distributionTrustStatus = $distributionTrustStatus
      distributionTrustPolicy = $distributionTrustPolicy
      distributionTrustSigner = $distributionTrustSigner
      distributionTrustTimestamped = $distributionTrustTimestamped
      distributionTrustNotarizationStapled = $distributionTrustNotarizationStapled
      distributionTrustGatekeeperAccepted = $distributionTrustGatekeeperAccepted
    }
  }

  return [ordered]@{
    status = if ($issues.Count -eq 0 -and $summaries.Count -eq 3) { "ready" } else { "not-ready" }
    root = Convert-ToRelativePath $evidenceRoot
    platforms = @($summaries)
    issues = @($issues)
  }
}

$pending = @()
if ([string]::IsNullOrWhiteSpace($planPath)) {
  $pending += "companion-cross-platform-plan"
}
if ([string]::IsNullOrWhiteSpace($readinessPath)) {
  $pending += "companion-v1-readiness-check"
}
if ($androidArtifacts.status -ne "present") {
  $pending += "android-apk-artifacts"
} else {
  if ($null -eq (Get-AndroidApkEntry $androidArtifacts "debug")) {
    $pending += "android-debug-apk-artifact"
  }
  if ($null -eq (Get-AndroidApkEntry $androidArtifacts "release")) {
    $pending += "android-release-apk-artifact"
  }
  if ($null -eq (Get-AndroidReleaseAabEntry $androidArtifacts)) {
    $pending += "android-release-aab-artifact"
  }
}
if ($desktopArtifacts.status -ne "present") {
  $pending += "desktop-distribution-artifacts"
} else {
  if (-not (Test-ArtifactEntryPattern $desktopArtifacts '\.deb$')) {
    $pending += "desktop-linux-deb-artifact"
  }
  if (-not (Test-ArtifactEntryPattern $desktopArtifacts '\.dmg$')) {
    $pending += "desktop-macos-dmg-artifact"
  }
  if (-not (Test-ArtifactEntryPattern $desktopArtifacts '\.msi$')) {
    $pending += "desktop-windows-msi-artifact"
  }
}
if ([string]::IsNullOrWhiteSpace($toolchainPins.path)) {
  $pending += "gradle-toolchain-pins"
}

$androidSigning = Test-AndroidReleaseApkSignature $androidArtifacts
if ($androidSigning.status -ne "verified") {
  $pending += "android-release-apk-signature"
}
if ($RequireUploadSigning -and $androidSigning.signingProfile -ne "upload-key") {
  $pending += "android-release-apk-upload-signing"
}
$androidBundleSigning = Test-AndroidReleaseBundleSignature $androidArtifacts
if ($androidBundleSigning.status -ne "verified") {
  $pending += "android-release-aab-signature"
}
if ($RequireUploadSigning -and $androidBundleSigning.signingProfile -ne "upload-key") {
  $pending += "android-release-aab-upload-signing"
}
$androidEmulatorEvidence = Get-AndroidEmulatorReleaseEvidence
if ($androidEmulatorEvidence.status -ne "ready" -and ($RequireAndroidEmulatorEvidence -or -not [string]::IsNullOrWhiteSpace($AndroidEmulatorEvidencePath))) {
  $pending += "android-emulator-release-apk-evidence"
}
$desktopPythonRuntime = Get-DesktopPythonRuntimeEvidence
if ($desktopPythonRuntime.status -ne "ready" -and ($RequireDesktopPythonRuntime -or -not [string]::IsNullOrWhiteSpace($desktopPythonRuntime.runtimeRoot))) {
  $pending += "desktop-managed-python-runtime-payload"
}
$desktopPackageEvidence = Get-DesktopPackageEvidence
if (($RequireDesktopPackageEvidence -or $RequireDesktopDistributionTrust) -and $desktopPackageEvidence.status -ne "ready") {
  $pending += "desktop-native-package-runtime-evidence"
}
if ($RequireDesktopDistributionTrust -and $desktopPackageEvidence.status -ne "ready") {
  $pending += "desktop-native-distribution-trust"
}

$strictEvidenceRequired = $RequireArtifacts -or $RequireUploadSigning -or $RequireDesktopPythonRuntime -or $RequireDesktopPackageEvidence -or $RequireDesktopDistributionTrust -or $RequireAndroidEmulatorEvidence
$status = if ($strictEvidenceRequired -and $pending.Count -gt 0) { "blocked-release-evidence" } elseif ($pending.Count -gt 0) { "evidence-pending-artifacts" } else { "complete" }

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
  androidSigning = $androidSigning
  androidBundleSigning = $androidBundleSigning
  uploadSigningRequired = [bool]$RequireUploadSigning
  androidEmulatorEvidenceRequired = [bool]$RequireAndroidEmulatorEvidence
  androidEmulatorEvidence = $androidEmulatorEvidence
  desktopPythonRuntime = $desktopPythonRuntime
  desktopPackageEvidenceRequired = [bool]$RequireDesktopPackageEvidence
  desktopDistributionTrustRequired = [bool]$RequireDesktopDistributionTrust
  desktopPackageEvidence = $desktopPackageEvidence
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
      $entryPath = [string]$entry["path"]
      $entryBytes = [string]$entry["bytes"]
      $entrySha256 = [string]$entry["sha256"]
      $lines += "- `$entryPath` ($entryBytes bytes, sha256 `$entrySha256`)"
    }
  }
}
$lines += ""
$lines += "## Android Signing"
$lines += "- Upload signing required: $([bool]$RequireUploadSigning)"
$lines += "- Status: $($androidSigning.status)"
$lines += "- APK: $($androidSigning.apk)"
$lines += "- Scheme: $($androidSigning.scheme)"
$lines += "- Signer: $($androidSigning.signer)"
$lines += "- Signing profile: $($androidSigning.signingProfile)"
$lines += "- Verifier: $($androidSigning.verifier)"
$lines += "- Detail: $($androidSigning.detail)"
$lines += ""
$lines += "## Android Bundle Signing"
$lines += "- Status: $($androidBundleSigning.status)"
$lines += "- Bundle: $($androidBundleSigning.bundle)"
$lines += "- Signer: $($androidBundleSigning.signer)"
$lines += "- Signing profile: $($androidBundleSigning.signingProfile)"
$lines += "- Verifier: $($androidBundleSigning.verifier)"
$lines += "- Detail: $($androidBundleSigning.detail)"
$lines += ""
$lines += "## Android Emulator Release APK Evidence"
$lines += "- Required: $([bool]$RequireAndroidEmulatorEvidence)"
$lines += "- Status: $($androidEmulatorEvidence.status)"
$lines += "- Evidence: $($androidEmulatorEvidence.evidence)"
$lines += "- Release APK: $($androidEmulatorEvidence.releaseApk)"
$lines += "- Release APK SHA-256: $($androidEmulatorEvidence.releaseApkSha256)"
if ($null -ne $androidEmulatorEvidence.smoke) {
  $lines += "- Emulator: $($androidEmulatorEvidence.smoke.model) / API $($androidEmulatorEvidence.smoke.apiLevel)"
  $lines += "- Package: $($androidEmulatorEvidence.smoke.packageName) $($androidEmulatorEvidence.smoke.versionName) ($($androidEmulatorEvidence.smoke.versionCode))"
  $lines += "- MainActivity resumed: $($androidEmulatorEvidence.smoke.mainActivityResumed)"
  $lines += "- CompanionBridgeService present: $($androidEmulatorEvidence.smoke.bridgeServicePresent)"
  $lines += "- Fatal process matches: $($androidEmulatorEvidence.smoke.fatalProcessMatches)"
  $lines += "- Substitutes for physical evidence: $($androidEmulatorEvidence.smoke.substitutesForPhysicalEvidence)"
}
foreach ($issue in @($androidEmulatorEvidence.issues)) { $lines += "- Issue: $issue" }
$lines += ""
$lines += "## Desktop Managed Python Runtime"
$lines += "- Status: $($desktopPythonRuntime.status)"
$lines += "- Runtime root: $($desktopPythonRuntime.runtimeRoot)"
$lines += "- Detail: $($desktopPythonRuntime.detail)"
foreach ($check in @($desktopPythonRuntime.checks)) {
  $lines += "- [$($check.status)] $($check.id): $($check.detail)"
}
$lines += ""
$lines += "## Native Desktop Package Runtime Evidence"
$lines += "- Required: $([bool]$RequireDesktopPackageEvidence)"
$lines += "- Native distribution trust required: $([bool]$RequireDesktopDistributionTrust)"
$lines += "- Status: $($desktopPackageEvidence.status)"
$lines += "- Root: $($desktopPackageEvidence.root)"
foreach ($platform in @($desktopPackageEvidence.platforms)) {
  $lines += "- $($platform.platform): package=$($platform.packageName) package_sha256=$($platform.packageSha256) runtime_sha256=$($platform.runtimeSha256) installer_runtime_sha256=$($platform.installerRuntimeSha256) app_jar_sha256=$($platform.installerAppJarSha256) python=$($platform.probedPythonVersion)"
  $lines += "  - Distribution trust: $($platform.distributionTrustStatus) / $($platform.distributionTrustPolicy) / $($platform.distributionTrustSigner)"
}
foreach ($issue in @($desktopPackageEvidence.issues)) { $lines += "- Issue: $issue" }
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

if ($strictEvidenceRequired -and $pending.Count -gt 0) {
  exit 2
}
