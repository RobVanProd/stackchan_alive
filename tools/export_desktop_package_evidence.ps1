param(
  [ValidateSet("windows", "linux", "macos")]
  [string]$Platform,
  [string]$PackagePath,
  [string]$RuntimePrepareJsonPath,
  [string]$ProcessedRuntimeRoot,
  [string]$PackageExtractionRoot = "",
  [string]$LaunchEvidencePath = "",
  [string]$Version = "",
  [string]$Commit = "",
  [string]$OutPath = "",
  [switch]$RequireInstallerPayload,
  [switch]$RequireLaunchEvidence,
  [switch]$UseExistingPackageExtraction,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

function Get-Sha256Text {
  param([string]$Path)
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $ioPath = if ($env:OS -eq "Windows_NT" -and -not $fullPath.StartsWith("\\?\")) { "\\?\$fullPath" } else { $fullPath }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $stream = [System.IO.File]::OpenRead($ioPath)
  try {
    return (($sha.ComputeHash($stream) | ForEach-Object { $_.ToString("x2") }) -join "")
  } finally {
    $stream.Dispose()
    $sha.Dispose()
  }
}

function Test-Sha256Text {
  param([string]$Value)
  return $Value -match '^[a-fA-F0-9]{64}$'
}

function Get-NormalizedZipEntryName {
  param($Entry)
  return ([string]$Entry.FullName).Replace("\", "/")
}

function Get-ZipEntriesByName {
  param(
    $Archive,
    [string]$Name
  )
  return @($Archive.Entries | Where-Object { (Get-NormalizedZipEntryName $_) -eq $Name })
}

function Get-HostPlatform {
  if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) { return "windows" }
  if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)) { return "linux" }
  if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) { return "macos" }
  return "unknown"
}

function Expand-DesktopPackage {
  param(
    [string]$TargetPlatform,
    [string]$SourcePackage,
    [string]$DestinationRoot
  )

  New-Item -ItemType Directory -Force -Path $DestinationRoot | Out-Null
  switch ($TargetPlatform) {
    "windows" {
      $msiexec = Get-Command msiexec.exe -ErrorAction SilentlyContinue
      if ($null -eq $msiexec) { throw "msiexec.exe is required to inspect the Windows installer payload." }
      $logPath = Join-Path $DestinationRoot "msiexec-admin.log"
      $arguments = @('/a', "`"$SourcePackage`"", '/qn', "TARGETDIR=`"$DestinationRoot`"", '/L*v', "`"$logPath`"")
      $process = Start-Process -FilePath $msiexec.Source -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
      if ($process.ExitCode -ne 0) { throw "MSI administrative extraction failed with exit code $($process.ExitCode). See $logPath" }
    }
    "linux" {
      $dpkg = Get-Command dpkg-deb -ErrorAction SilentlyContinue
      if ($null -eq $dpkg) { throw "dpkg-deb is required to inspect the Linux installer payload." }
      & $dpkg.Source -x $SourcePackage $DestinationRoot
      if ($LASTEXITCODE -ne 0) { throw "DEB extraction failed with exit code $LASTEXITCODE." }
    }
    "macos" {
      $hdiutil = Get-Command hdiutil -ErrorAction SilentlyContinue
      if ($null -eq $hdiutil) { throw "hdiutil is required to inspect the macOS installer payload." }
      $mountPoint = "$DestinationRoot-mount"
      New-Item -ItemType Directory -Force -Path $mountPoint | Out-Null
      $attached = $false
      try {
        & $hdiutil.Source attach $SourcePackage -readonly -nobrowse -mountpoint $mountPoint | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "DMG mount failed with exit code $LASTEXITCODE." }
        $attached = $true
        $mountedApps = @(Get-ChildItem -LiteralPath $mountPoint -Directory -Filter "*.app" -ErrorAction Stop)
        if ($mountedApps.Count -ne 1) { throw "Expected one application bundle in mounted DMG; found $($mountedApps.Count)." }
        & (Get-Command ditto -ErrorAction Stop).Source $mountedApps[0].FullName (Join-Path $DestinationRoot $mountedApps[0].Name)
        if ($LASTEXITCODE -ne 0) { throw "Application bundle copy failed with exit code $LASTEXITCODE." }
      } finally {
        if ($attached) {
          & $hdiutil.Source detach $mountPoint -force | Out-Null
        }
      }
    }
  }
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
$installerPayload = [ordered]@{
  required = [bool]$RequireInstallerPayload
  status = if ($RequireInstallerPayload) { "not-ready" } else { "not-required" }
  extractionMethod = ""
  extractionRoot = ""
  appJarName = ""
  appJarSha256 = ""
  packageSha256 = ""
  runtimeLocation = ""
  runtimeRootRelative = ""
  runtimePayloadSha256 = ""
  runtimeFileCount = 0
  runtimeBytes = 0
  runtimeManifestSchema = ""
  runtimeManifestPlatform = ""
  runtimeManifestSha256 = ""
  requiredBrainFiles = @()
}
$launchEvidence = [ordered]@{
  required = [bool]$RequireLaunchEvidence
  status = if ($RequireLaunchEvidence) { "not-ready" } else { "not-required" }
  path = $LaunchEvidencePath
  packageSha256 = ""
  extractionMethod = ""
  extractionRoot = ""
  launcherPath = ""
  processExitCode = $null
  pythonVersion = ""
  scope = ""
}

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

if ($RequireInstallerPayload) {
  $installerIssueStart = $issues.Count
  if ($null -eq $package) {
    Add-Issue "Installer payload cannot be inspected because the desktop package is missing."
  } else {
    if ([string]::IsNullOrWhiteSpace($PackageExtractionRoot)) {
      $extractionId = [guid]::NewGuid().ToString("N").Substring(0, 12)
      $PackageExtractionRoot = Join-Path ([System.IO.Path]::GetTempPath()) "stackchan-package-extraction-$Platform-$extractionId"
    }
    $PackageExtractionRoot = [System.IO.Path]::GetFullPath($PackageExtractionRoot)
    $installerPayload.extractionRoot = $PackageExtractionRoot
    if ($UseExistingPackageExtraction) {
      if (-not (Test-Path -LiteralPath $PackageExtractionRoot -PathType Container)) {
        Add-Issue "Existing package extraction root was not found: $PackageExtractionRoot"
      } else {
        $installerPayload.extractionMethod = "existing"
      }
    } else {
      if ((Get-HostPlatform) -ne $Platform) {
        Add-Issue "Installer payload extraction for $Platform must run on a native $Platform host."
      } elseif (Test-Path -LiteralPath $PackageExtractionRoot) {
        Add-Issue "Package extraction root already exists; refusing to overwrite it: $PackageExtractionRoot"
      } else {
        try {
          Expand-DesktopPackage -TargetPlatform $Platform -SourcePackage $package.FullName -DestinationRoot $PackageExtractionRoot
          $installerPayload.extractionMethod = "native"
        } catch {
          Add-Issue $_.Exception.Message
        }
      }
    }

    if (Test-Path -LiteralPath $PackageExtractionRoot -PathType Container) {
      $appJars = @(Get-ChildItem -LiteralPath $PackageExtractionRoot -Recurse -File -Filter "app-desktop-*.jar" -ErrorAction SilentlyContinue)
      if ($appJars.Count -ne 1) {
        Add-Issue "Expected exactly one packaged application JAR; found $($appJars.Count)."
      } else {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $appJar = $appJars[0]
        $installerPayload.appJarName = $appJar.Name
        $installerPayload.appJarSha256 = Get-Sha256Text $appJar.FullName
        $installerPayload.packageSha256 = Get-Sha256Text $package.FullName
        $archive = [System.IO.Compression.ZipFile]::OpenRead($appJar.FullName)
        try {
          $jarRuntimeEntries = @($archive.Entries | Where-Object { (Get-NormalizedZipEntryName $_).StartsWith("python-runtime/") })
          if ($jarRuntimeEntries.Count -ne 0) { Add-Issue "Packaged application JAR must not contain the executable managed runtime." }

          $requiredBrainFiles = @(
            "brain/bridge/lan_service.py",
            "brain/bridge/reference_bridge.py",
            "brain/data/voice_source_provenance.yaml",
            "brain/docs/media/voice/stackchan_spark_greeting.wav"
          )
          $presentBrainFiles = @()
          foreach ($brainPath in $requiredBrainFiles) {
            if (@(Get-ZipEntriesByName $archive $brainPath).Count -eq 1) {
              $presentBrainFiles += $brainPath
            } else {
              Add-Issue "Packaged application JAR is missing required brain resource: $brainPath"
            }
          }
          $installerPayload.requiredBrainFiles = @($presentBrainFiles)
        } finally {
          $archive.Dispose()
        }
      }

      $runtimeRoots = @(Get-ChildItem -LiteralPath $PackageExtractionRoot -Recurse -Directory -Filter "python-runtime" -ErrorAction SilentlyContinue | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName "stackchan-python-runtime.json") -PathType Leaf
      })
      if ($runtimeRoots.Count -ne 1) {
        Add-Issue "Expected exactly one external managed runtime in native app resources; found $($runtimeRoots.Count)."
      } else {
        $runtimeRoot = $runtimeRoots[0].FullName
        $installerPayload.runtimeLocation = "native-app-resources"
        $extractionPrefix = $PackageExtractionRoot.TrimEnd("\", "/") + [System.IO.Path]::DirectorySeparatorChar
        $installerPayload.runtimeRootRelative = $runtimeRoot.Substring($extractionPrefix.Length).Replace("\", "/")
        $runtimeFiles = @(Get-ChildItem -LiteralPath $runtimeRoot -File -Recurse -Force)
        $installerPayload.runtimePayloadSha256 = Get-RuntimePayloadHash $runtimeRoot
        $installerPayload.runtimeFileCount = $runtimeFiles.Count
        $installerPayload.runtimeBytes = [int64](($runtimeFiles | Measure-Object -Property Length -Sum).Sum)
        $installerManifestPath = Join-Path $runtimeRoot "stackchan-python-runtime.json"
        try {
          $installerManifest = Get-Content -LiteralPath $installerManifestPath -Raw | ConvertFrom-Json
          $installerPayload.runtimeManifestSchema = [string]$installerManifest.schema
          $installerPayload.runtimeManifestPlatform = [string]$installerManifest.platform
          $installerPayload.runtimeManifestSha256 = [string]$installerManifest.sha256
          if ([string]$installerManifest.schema -ne "stackchan.desktop-python-runtime.v1") { Add-Issue "Packaged runtime manifest schema is invalid." }
          if ([string]$installerManifest.platform -ne $Platform) { Add-Issue "Packaged runtime manifest platform must be $Platform." }
          if ($null -ne $prepare -and [string]$installerManifest.sha256 -ne [string]$prepare.payloadSha256) { Add-Issue "Packaged runtime manifest SHA-256 does not match runtime prepare evidence." }
        } catch {
          Add-Issue "Packaged runtime manifest is invalid JSON: $($_.Exception.Message)"
        }
        $runtimeExecutables = switch ($Platform) {
          "windows" { @("python.exe", "python/python.exe") }
          default { @("bin/python3", "bin/python", "python3", "python") }
        }
        if (@($runtimeExecutables | Where-Object { Test-Path -LiteralPath (Join-Path $runtimeRoot $_) -PathType Leaf }).Count -lt 1) {
          Add-Issue "External managed runtime does not contain the expected $Platform Python executable."
        }
      }
    }
  }

  if ($null -ne $prepare -and -not [string]::IsNullOrWhiteSpace([string]$installerPayload.runtimePayloadSha256) -and
      [string]$installerPayload.runtimePayloadSha256 -ne [string]$prepare.payloadSha256) {
    Add-Issue "Installer runtime payload hash does not match runtime prepare evidence."
  }
  if (-not [string]::IsNullOrWhiteSpace($processedHash) -and -not [string]::IsNullOrWhiteSpace([string]$installerPayload.runtimePayloadSha256) -and
      [string]$installerPayload.runtimePayloadSha256 -ne $processedHash) {
    Add-Issue "Installer runtime payload hash does not match processed Gradle resources."
  }
  if ($processedFiles.Count -gt 0 -and [int]$installerPayload.runtimeFileCount -ne $processedFiles.Count) {
    Add-Issue "Installer runtime file count does not match processed Gradle resources."
  }
  $processedRuntimeBytes = [int64](($processedFiles | Measure-Object -Property Length -Sum).Sum)
  if ($processedRuntimeBytes -gt 0 -and [int64]$installerPayload.runtimeBytes -ne $processedRuntimeBytes) {
    Add-Issue "Installer runtime byte count does not match processed Gradle resources."
  }
  if ($issues.Count -eq $installerIssueStart) { $installerPayload.status = "ready" }
}

if ($RequireLaunchEvidence -or -not [string]::IsNullOrWhiteSpace($LaunchEvidencePath)) {
  $launchIssueStart = $issues.Count
  if ([string]::IsNullOrWhiteSpace($LaunchEvidencePath) -or -not (Test-Path -LiteralPath $LaunchEvidencePath -PathType Leaf)) {
    Add-Issue "Exact desktop package launch evidence is missing: $LaunchEvidencePath"
  } else {
    try {
      $launch = Get-Content -LiteralPath $LaunchEvidencePath -Raw | ConvertFrom-Json
      $launchEvidence.path = [System.IO.Path]::GetFullPath($LaunchEvidencePath)
      $launchEvidence.packageSha256 = ([string]$launch.package.sha256).ToLowerInvariant()
      $launchEvidence.extractionMethod = [string]$launch.extractionMethod
      $launchEvidence.extractionRoot = [string]$launch.extractionRoot
      $launchEvidence.launcherPath = [string]$launch.launcherPath
      $launchEvidence.processExitCode = $launch.processExitCode
      $launchEvidence.pythonVersion = [string]$launch.probe.pythonVersion
      $launchEvidence.scope = [string]$launch.scope
      if ([string]$launch.schema -ne "stackchan.desktop-package-launch-evidence.v1" -or [string]$launch.status -ne "ready") { Add-Issue "Exact desktop package launch evidence is not ready." }
      if ([string]$launch.platform -ne $Platform) { Add-Issue "Exact desktop package launch platform mismatch." }
      if ($null -eq $package -or $launchEvidence.packageSha256 -ne (Get-Sha256Text $package.FullName)) { Add-Issue "Exact desktop package launch hash does not match the package." }
      if ($launch.extractionMethod -ne "native" -or [int]$launch.processExitCode -ne 0) { Add-Issue "Exact desktop package was not natively extracted and launched successfully." }
      if ($UseExistingPackageExtraction) {
        $launchExtractionRoot = [System.IO.Path]::GetFullPath([string]$launch.extractionRoot).TrimEnd("\", "/")
        if ($launchExtractionRoot -ne $PackageExtractionRoot.TrimEnd("\", "/")) {
          Add-Issue "Exact desktop package launch used a different extraction root."
        } else {
          $installerPayload.extractionMethod = "native"
        }
      }
      if ([string]$launch.probe.schema -ne "stackchan.desktop-packaged-runtime-smoke.v1" -or [string]$launch.probe.status -ne "ready") { Add-Issue "Packaged runtime smoke probe is not ready." }
      if ($launch.probe.runtimePresent -ne $true -or $launch.probe.pythonAvailable -ne $true -or $launch.probe.brainScriptAvailable -ne $true) { Add-Issue "Packaged runtime smoke did not prove all runtime components." }
      if ([string]$launch.probe.launchContext -ne "package-extraction" -or [string]$launch.probe.scope -ne "extracted-native-package-headless-runtime-probe" -or $launch.probe.substitutesForTargetInstall -ne $false) { Add-Issue "Packaged runtime smoke probe context is invalid." }
      if (@($launch.probe.issues).Count -ne 0 -or $launch.substitutesForTargetInstall -ne $false) { Add-Issue "Exact desktop package launch evidence has invalid scope or issues." }
      if ([string]$launch.scope -ne "exact-native-package-extraction-and-headless-launch") { Add-Issue "Exact desktop package launch scope is invalid." }
    } catch {
      Add-Issue "Exact desktop package launch evidence is invalid JSON: $($_.Exception.Message)"
    }
  }
  if ($issues.Count -eq $launchIssueStart) { $launchEvidence.status = "ready" }
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
  installerPayload = $installerPayload
  launchEvidence = $launchEvidence
  issues = @($issues)
}

if ([string]::IsNullOrWhiteSpace($OutPath)) {
  $OutPath = Join-Path $repoRoot "output/companion/desktop-package-evidence/$Platform-package-evidence.json"
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutPath) | Out-Null
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutPath -Encoding UTF8

if ($Json) { $report | ConvertTo-Json -Depth 8 } else { Write-Host "Desktop package evidence: $($report.status) ($Platform)" }
if ($issues.Count -gt 0) { exit 1 }
