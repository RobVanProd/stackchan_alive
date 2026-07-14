param(
  [ValidateSet("windows", "linux", "macos")]
  [string]$Platform,
  [string]$PackagePath,
  [string]$OutputDir = "output/desktop-target-install/latest",
  [string]$SourceCommit = "",
  [ValidateSet("operator-target-workstation", "ci-native-runner")]
  [string]$EnvironmentKind = "operator-target-workstation",
  [string]$InstallRoot = "",
  [int]$TimeoutSeconds = 120,
  [switch]$AllowReplace,
  [switch]$Json
)

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$issues = @()

function Add-Issue([string]$Message) { $script:issues += $Message }
function Get-Sha256Text([string]$Path) { return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }
function Get-HostPlatform {
  if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)) { return "windows" }
  if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Linux)) { return "linux" }
  if ([System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::OSX)) { return "macos" }
  return "unknown"
}
function Get-GitCommit {
  try { return ((& git -C $repoRoot rev-parse HEAD 2>$null) | Out-String).Trim() } catch { return "" }
}
function Find-WindowsLauncher {
  $roots = New-Object System.Collections.Generic.List[string]
  if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) { $roots.Add([System.IO.Path]::GetFullPath($InstallRoot)) }
  foreach ($candidate in @(
    (Join-Path $env:ProgramFiles "Stackchan Companion"),
    $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} "Stackchan Companion" }),
    $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA "Programs\Stackchan Companion" })
  )) {
    if (-not [string]::IsNullOrWhiteSpace($candidate)) { $roots.Add($candidate) }
  }
  $registryRoots = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*"
  )
  foreach ($entry in @(Get-ItemProperty $registryRoots -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -eq "Stackchan Companion" })) {
    if (-not [string]::IsNullOrWhiteSpace([string]$entry.InstallLocation)) { $roots.Add([string]$entry.InstallLocation) }
  }
  $matches = @()
  foreach ($root in @($roots | Select-Object -Unique)) {
    if (Test-Path -LiteralPath $root -PathType Container) {
      $matches += @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter "Stackchan Companion.exe" -ErrorAction SilentlyContinue)
    }
  }
  return @($matches | Sort-Object FullName -Unique)
}

if ([string]::IsNullOrWhiteSpace($OutputDir)) { $OutputDir = "output/desktop-target-install/latest" }
if (-not [System.IO.Path]::IsPathRooted($OutputDir)) { $OutputDir = Join-Path $repoRoot $OutputDir }
$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$recordedCommit = $SourceCommit.Trim()
if ([string]::IsNullOrWhiteSpace($recordedCommit)) { $recordedCommit = Get-GitCommit }
if ($recordedCommit -notmatch '^[a-fA-F0-9]{40}$') { Add-Issue "SourceCommit must be a full 40-character git SHA." }

$hostPlatform = Get-HostPlatform
if ($hostPlatform -ne $Platform) { Add-Issue "Desktop package for $Platform must be installed on a native $Platform host; current host is $hostPlatform." }

$package = $null
$packageSha = ""
$expectedExtension = @{ windows = ".msi"; linux = ".deb"; macos = ".dmg" }[$Platform]
if ([string]::IsNullOrWhiteSpace($PackagePath) -or -not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
  Add-Issue "Desktop package is missing: $PackagePath"
} else {
  $package = Get-Item -LiteralPath $PackagePath
  $packageSha = Get-Sha256Text $package.FullName
  if ($package.Extension.ToLowerInvariant() -ne $expectedExtension) { Add-Issue "Desktop package for $Platform must use $expectedExtension." }
}

$installMethod = @{ windows = "msiexec-install"; linux = "dpkg-install"; macos = "dmg-application-copy" }[$Platform]
$installExitCode = $null
$installLogPath = Join-Path $OutputDir "$Platform-native-install.log"
$installedLauncherPath = ""
$probe = $null
$launchExitCode = $null
$mountPoint = ""

if ($null -ne $package -and $hostPlatform -eq $Platform -and $issues.Count -eq 0) {
  try {
    switch ($Platform) {
      "windows" {
        $arguments = @('/i', "`"$($package.FullName)`"", '/qn', '/norestart')
        if (-not [string]::IsNullOrWhiteSpace($InstallRoot)) {
          $InstallRoot = [System.IO.Path]::GetFullPath($InstallRoot)
          $arguments += "INSTALLDIR=`"$InstallRoot`""
        }
        $arguments += @('/L*v', "`"$installLogPath`"")
        $process = Start-Process -FilePath (Get-Command msiexec.exe -ErrorAction Stop).Source -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
        $installExitCode = $process.ExitCode
        if ($installExitCode -notin @(0, 1641, 3010)) { Add-Issue "MSI installation failed with exit code $installExitCode. Run this helper from an elevated PowerShell session and inspect $installLogPath." }
        if ($issues.Count -eq 0) {
          $launchers = @(Find-WindowsLauncher)
          if ($launchers.Count -ne 1) { Add-Issue "Expected exactly one installed Windows launcher; found $($launchers.Count)." } else { $installedLauncherPath = $launchers[0].FullName }
        }
      }
      "linux" {
        $dpkgDeb = (Get-Command dpkg-deb -ErrorAction Stop).Source
        $packageName = ((& $dpkgDeb -f $package.FullName Package 2>&1) | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($packageName)) { throw "Could not read the DEB package name." }
        $isRoot = ((& id -u) | Out-String).Trim() -eq "0"
        $command = if ($isRoot) { (Get-Command dpkg -ErrorAction Stop).Source } else { (Get-Command sudo -ErrorAction Stop).Source }
        $arguments = if ($isRoot) { @('-i', $package.FullName) } else { @('-n', 'dpkg', '-i', $package.FullName) }
        $installOutput = @(& $command @arguments 2>&1)
        $installExitCode = $LASTEXITCODE
        $installOutput | Set-Content -LiteralPath $installLogPath -Encoding UTF8
        if ($installExitCode -ne 0) { Add-Issue "DEB installation failed with exit code $installExitCode. Inspect $installLogPath." }
        if ($issues.Count -eq 0) {
          $installedFiles = @(& (Get-Command dpkg -ErrorAction Stop).Source -L $packageName 2>&1)
          if ($LASTEXITCODE -ne 0) { Add-Issue "Could not enumerate files installed by $packageName." }
          $launchers = @($installedFiles | Where-Object { (Split-Path -Leaf ([string]$_)) -eq "Stackchan Companion" -and (Test-Path -LiteralPath ([string]$_) -PathType Leaf) })
          if ($launchers.Count -ne 1) { Add-Issue "Expected exactly one installed Linux launcher; found $($launchers.Count)." } else { $installedLauncherPath = [string]$launchers[0] }
        }
      }
      "macos" {
        if ([string]::IsNullOrWhiteSpace($InstallRoot)) { $InstallRoot = Join-Path $HOME "Applications" }
        $InstallRoot = [System.IO.Path]::GetFullPath($InstallRoot)
        New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
        $mountPoint = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-dmg-install-" + [guid]::NewGuid().ToString("N").Substring(0, 12))
        New-Item -ItemType Directory -Path $mountPoint | Out-Null
        $hdiutil = (Get-Command hdiutil -ErrorAction Stop).Source
        $attachOutput = @(& $hdiutil attach $package.FullName -readonly -nobrowse -mountpoint $mountPoint 2>&1)
        if ($LASTEXITCODE -ne 0) { throw "DMG mount failed." }
        try {
          $apps = @(Get-ChildItem -LiteralPath $mountPoint -Directory -Filter "*.app")
          if ($apps.Count -ne 1) { throw "Expected one application bundle in the DMG; found $($apps.Count)." }
          $installRootPrefix = $InstallRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
          $installedApp = [System.IO.Path]::GetFullPath((Join-Path $InstallRoot $apps[0].Name))
          if (-not $installedApp.StartsWith($installRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Resolved application path is outside the requested installation root: $installedApp"
          }
          if (Test-Path -LiteralPath $installedApp) {
            if (-not $AllowReplace) { throw "Installed application already exists: $installedApp. Re-run with -AllowReplace after preserving any required evidence." }
            Remove-Item -LiteralPath $installedApp -Recurse -Force
          }
          $copyOutput = @(& (Get-Command ditto -ErrorAction Stop).Source $apps[0].FullName $installedApp 2>&1)
          $installExitCode = $LASTEXITCODE
          @($attachOutput; $copyOutput) | Set-Content -LiteralPath $installLogPath -Encoding UTF8
          if ($installExitCode -ne 0) { Add-Issue "Application bundle copy failed with exit code $installExitCode." }
          $launchers = @(Get-ChildItem -LiteralPath $installedApp -Recurse -File -Filter "Stackchan Companion" | Where-Object { $_.FullName -match '\.app[\\/]Contents[\\/]MacOS[\\/]' })
          if ($launchers.Count -ne 1) { Add-Issue "Expected exactly one installed macOS launcher; found $($launchers.Count)." } else { $installedLauncherPath = $launchers[0].FullName }
        } finally {
          & $hdiutil detach $mountPoint -force | Out-Null
        }
      }
    }
  } catch {
    Add-Issue "Native package installation failed: $($_.Exception.Message)"
  }
}

if (-not [string]::IsNullOrWhiteSpace($installedLauncherPath) -and $issues.Count -eq 0) {
  $probePath = Join-Path $OutputDir "$Platform-installed-runtime-smoke.json"
  try {
    $arguments = @(
      "--package-smoke-output=`"$probePath`"",
      "--package-smoke-context=installed-package"
    )
    $process = Start-Process -FilePath $installedLauncherPath -ArgumentList $arguments -PassThru
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
      $process.Kill()
      Add-Issue "Installed launcher smoke timed out after $TimeoutSeconds seconds."
    } else {
      $launchExitCode = $process.ExitCode
      if ($launchExitCode -ne 0) { Add-Issue "Installed launcher smoke exited with code $launchExitCode." }
    }
  } catch {
    Add-Issue "Installed launcher smoke could not start: $($_.Exception.Message)"
  }
  if (-not (Test-Path -LiteralPath $probePath -PathType Leaf)) {
    Add-Issue "Installed launcher did not write its runtime smoke report."
  } else {
    try { $probe = Get-Content -LiteralPath $probePath -Raw | ConvertFrom-Json } catch { Add-Issue "Installed runtime smoke report is invalid JSON: $($_.Exception.Message)" }
  }
}

if ($null -ne $probe) {
  if ([string]$probe.schema -ne "stackchan.desktop-packaged-runtime-smoke.v1" -or [string]$probe.status -ne "ready") { Add-Issue "Installed runtime smoke is not ready." }
  if ([string]$probe.platform -ne $Platform -or [string]$probe.launchContext -ne "installed-package" -or [string]$probe.scope -ne "installed-native-package-headless-runtime-probe") { Add-Issue "Installed runtime smoke platform or scope is invalid." }
  if ($probe.runtimePresent -ne $true -or $probe.pythonAvailable -ne $true -or $probe.brainScriptAvailable -ne $true -or @($probe.issues).Count -ne 0) { Add-Issue "Installed runtime smoke did not prove runtime, Python, and brain readiness." }
}

$report = [ordered]@{
  schema = "stackchan.desktop-target-install-evidence.v1"
  status = if ($issues.Count -eq 0) { "installed-and-ready" } else { "not-ready" }
  capturedUtc = (Get-Date).ToUniversalTime().ToString("o")
  sourceCommit = $recordedCommit
  platform = $Platform
  environmentKind = $EnvironmentKind
  host = [ordered]@{
    platform = $hostPlatform
    osDescription = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
    architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString().ToLowerInvariant()
  }
  package = if ($null -eq $package) { [ordered]@{ name = ""; bytes = 0; sha256 = "" } } else { [ordered]@{ name = $package.Name; bytes = [int64]$package.Length; sha256 = $packageSha } }
  install = [ordered]@{
    method = $installMethod
    exitCode = $installExitCode
    installRoot = $InstallRoot
    installedLauncherPath = $installedLauncherPath
    logPath = $installLogPath
  }
  launch = [ordered]@{
    exitCode = $launchExitCode
    probe = $probe
  }
  scope = "exact-native-package-install-and-headless-launch"
  targetInstallVerified = ($issues.Count -eq 0)
  substitutesForHumanAcceptance = $false
  issues = @($issues)
}

$jsonPath = Join-Path $OutputDir "$Platform-target-install.json"
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
if ($Json) { $report | ConvertTo-Json -Depth 10 } else { Write-Host "Desktop target install evidence: $($report.status) ($Platform)"; Write-Host $jsonPath }
if ($issues.Count -gt 0) { exit 1 }
