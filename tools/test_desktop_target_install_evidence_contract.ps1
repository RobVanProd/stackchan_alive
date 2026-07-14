param()

$ErrorActionPreference = "Stop"
$checker = Join-Path $PSScriptRoot "check_desktop_target_install_evidence.ps1"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-desktop-target-install-contract-" + [guid]::NewGuid().ToString("N"))
$sourceCommit = "a" * 40
$packageHashes = [ordered]@{ windows = ("b" * 64); linux = ("c" * 64); macos = ("d" * 64) }

function New-TargetInstallFixture {
  param(
    [ValidateSet("windows", "linux", "macos")]
    [string]$Platform,
    [string]$EnvironmentKind = "operator-target-workstation"
  )
  $extension = @{ windows = ".msi"; linux = ".deb"; macos = ".dmg" }[$Platform]
  $method = @{ windows = "msiexec-install"; linux = "dpkg-install"; macos = "dmg-application-copy" }[$Platform]
  return [ordered]@{
    schema = "stackchan.desktop-target-install-evidence.v1"
    status = "installed-and-ready"
    capturedUtc = "2026-07-13T00:00:00Z"
    sourceCommit = $sourceCommit
    platform = $Platform
    environmentKind = $EnvironmentKind
    host = [ordered]@{ platform = $Platform; osDescription = "contract fixture"; architecture = "x64"; elevatedAdministrator = ($Platform -eq "windows") }
    package = [ordered]@{ name = "stackchan-companion$extension"; bytes = 12345; sha256 = $packageHashes[$Platform] }
    install = [ordered]@{
      method = $method
      exitCode = 0
      installRoot = "/fixture"
      installedLauncherPath = "/fixture/Stackchan Companion"
      logPath = "fixture.log"
      windows = if ($Platform -eq "windows") {
        [ordered]@{
          preExistingRegistrations = @()
          replacementRequested = $false
          replacementPerformed = $false
          uninstallAttempts = @()
          postInstallRegistrations = @([ordered]@{
            productCode = "{11111111-2222-3333-4444-555555555555}"
            displayName = "Stackchan Companion"
            displayVersion = "1.0.0"
            publisher = "fixture"
            installLocation = "/fixture"
            registryPath = "fixture-registry"
          })
        }
      } else { $null }
    }
    launch = [ordered]@{
      exitCode = 0
      probe = [ordered]@{
        schema = "stackchan.desktop-packaged-runtime-smoke.v1"
        status = "ready"
        platform = $Platform
        appVersion = "1.0.0"
        protocol = "stackchan.bridge.v1"
        runtimePresent = $true
        pythonAvailable = $true
        pythonVersion = "Python 3.12.4"
        brainScriptAvailable = $true
        launchContext = "installed-package"
        scope = "installed-native-package-headless-runtime-probe"
        substitutesForTargetInstall = $false
        issues = @()
      }
    }
    scope = "exact-native-package-install-and-headless-launch"
    targetInstallVerified = $true
    substitutesForHumanAcceptance = $false
    issues = @()
  }
}

function Write-Fixture([string]$Name, [object]$Value) {
  $path = Join-Path $tempRoot "$Name.json"
  $Value | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $path -Encoding UTF8
  return $path
}

function Invoke-Check {
  param(
    [string]$Path,
    [string]$Platform,
    [string]$PackageSha256,
    [switch]$RequireOperatorTarget
  )
  $arguments = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $checker,
    '-EvidencePath', $Path,
    '-ExpectedPlatform', $Platform,
    '-ExpectedPackageSha256', $PackageSha256,
    '-ExpectedSourceCommit', $sourceCommit,
    '-Json'
  )
  if ($RequireOperatorTarget) { $arguments += '-RequireOperatorTarget' }
  $output = & (Get-Process -Id $PID).Path @arguments 2>&1 | Out-String
  return [ordered]@{ exitCode = $LASTEXITCODE; output = $output; report = ($output | ConvertFrom-Json) }
}

try {
  New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
  foreach ($platform in @("windows", "linux", "macos")) {
    $path = Write-Fixture "$platform-ready" (New-TargetInstallFixture $platform)
    $result = Invoke-Check $path $platform $packageHashes[$platform] -RequireOperatorTarget
    if ($result.exitCode -ne 0 -or $result.report.status -ne "desktop-target-install-ready") { throw "Ready $platform target-install evidence was rejected: $($result.output)" }
  }
  Write-Host "[ok] operator target-install evidence is accepted for Windows, Linux, and macOS"

  $windowsReplacement = New-TargetInstallFixture "windows"
  $windowsReplacement.install.windows.preExistingRegistrations = @([ordered]@{
    productCode = "{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}"
    displayName = "Stackchan Companion"
    displayVersion = "1.0.0"
    publisher = "fixture"
    installLocation = "/fixture-old"
    registryPath = "fixture-registry-old"
  })
  $windowsReplacement.install.windows.replacementRequested = $true
  $windowsReplacement.install.windows.replacementPerformed = $true
  $windowsReplacement.install.windows.uninstallAttempts = @([ordered]@{
    productCode = "{AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE}"
    exitCode = 0
    logPath = "fixture-uninstall.log"
  })
  $windowsReplacementPath = Write-Fixture "windows-replacement" $windowsReplacement
  $windowsReplacementResult = Invoke-Check $windowsReplacementPath "windows" $packageHashes.windows -RequireOperatorTarget
  if ($windowsReplacementResult.exitCode -ne 0 -or $windowsReplacementResult.report.status -ne "desktop-target-install-ready") { throw "Safe Windows replacement evidence was rejected: $($windowsReplacementResult.output)" }
  Write-Host "[ok] explicit Windows replacement evidence is accepted"

  $unsafeWindowsReplacement = New-TargetInstallFixture "windows"
  $unsafeWindowsReplacement.install.windows.preExistingRegistrations = $windowsReplacement.install.windows.preExistingRegistrations
  $unsafeWindowsReplacementPath = Write-Fixture "unsafe-windows-replacement" $unsafeWindowsReplacement
  $unsafeWindowsReplacementResult = Invoke-Check $unsafeWindowsReplacementPath "windows" $packageHashes.windows -RequireOperatorTarget
  if ($unsafeWindowsReplacementResult.exitCode -eq 0 -or @($unsafeWindowsReplacementResult.report.checks | Where-Object { $_.id -eq "windows-exact-package-replacement" -and $_.status -eq "fail" }).Count -ne 1) { throw "Unsafe Windows replacement evidence was accepted." }
  Write-Host "[ok] implicit Windows maintenance-mode replacement is rejected"

  $nonElevatedWindows = New-TargetInstallFixture "windows"
  $nonElevatedWindows.host.elevatedAdministrator = $false
  $nonElevatedWindowsPath = Write-Fixture "non-elevated-windows" $nonElevatedWindows
  $nonElevatedWindowsResult = Invoke-Check $nonElevatedWindowsPath "windows" $packageHashes.windows -RequireOperatorTarget
  if ($nonElevatedWindowsResult.exitCode -eq 0 -or @($nonElevatedWindowsResult.report.checks | Where-Object { $_.id -eq "windows-elevation" -and $_.status -eq "fail" }).Count -ne 1) { throw "Non-elevated Windows install evidence was accepted." }
  Write-Host "[ok] non-elevated Windows install evidence is rejected"

  $wrongHashPath = Write-Fixture "wrong-hash" (New-TargetInstallFixture "windows")
  $wrongHash = Invoke-Check $wrongHashPath "windows" ("0" * 64) -RequireOperatorTarget
  if ($wrongHash.exitCode -eq 0 -or @($wrongHash.report.checks | Where-Object { $_.id -eq "expected-package-sha256" -and $_.status -eq "fail" }).Count -ne 1) { throw "Stale package hash was not rejected." }
  Write-Host "[ok] stale target-install package hash is rejected"

  $ciPath = Write-Fixture "ci-runner" (New-TargetInstallFixture "linux" "ci-native-runner")
  $ciResult = Invoke-Check $ciPath "linux" $packageHashes.linux -RequireOperatorTarget
  if ($ciResult.exitCode -eq 0 -or @($ciResult.report.checks | Where-Object { $_.id -eq "operator-target" -and $_.status -eq "fail" }).Count -ne 1) { throw "CI evidence was accepted as operator target evidence." }
  Write-Host "[ok] CI native-runner evidence cannot replace operator target evidence"

  $extracted = New-TargetInstallFixture "macos"
  $extracted.launch.probe.launchContext = "package-extraction"
  $extracted.launch.probe.scope = "extracted-native-package-headless-runtime-probe"
  $extractedPath = Write-Fixture "extracted-launch" $extracted
  $extractedResult = Invoke-Check $extractedPath "macos" $packageHashes.macos -RequireOperatorTarget
  if ($extractedResult.exitCode -eq 0 -or @($extractedResult.report.checks | Where-Object { $_.id -eq "installed-runtime-probe" -and $_.status -eq "fail" }).Count -ne 1) { throw "Extracted package launch was accepted as installed launch evidence." }
  Write-Host "[ok] package extraction cannot replace installed launcher evidence"

  $missingExitCodes = New-TargetInstallFixture "windows"
  $missingExitCodes.install.Remove("exitCode")
  $missingExitCodes.launch.Remove("exitCode")
  $missingExitCodesPath = Write-Fixture "missing-exit-codes" $missingExitCodes
  $missingExitCodesResult = Invoke-Check $missingExitCodesPath "windows" $packageHashes.windows -RequireOperatorTarget
  if ($missingExitCodesResult.exitCode -eq 0 -or @($missingExitCodesResult.report.checks | Where-Object { $_.id -in @("native-install", "installed-launcher") -and $_.status -eq "fail" }).Count -ne 2) { throw "Missing install or launch exit codes were accepted." }
  Write-Host "[ok] missing install and launch exit codes are rejected"

  $wrongCommit = New-TargetInstallFixture "windows"
  $wrongCommit.sourceCommit = "e" * 40
  $wrongCommitPath = Write-Fixture "wrong-commit" $wrongCommit
  $wrongCommitResult = Invoke-Check $wrongCommitPath "windows" $packageHashes.windows -RequireOperatorTarget
  if ($wrongCommitResult.exitCode -eq 0 -or @($wrongCommitResult.report.checks | Where-Object { $_.id -eq "expected-source-commit" -and $_.status -eq "fail" }).Count -ne 1) { throw "Mismatched source commit was not rejected." }
  Write-Host "[ok] mismatched target-install source commit is rejected"
} finally {
  if (Test-Path -LiteralPath $tempRoot) {
    $resolved = (Resolve-Path -LiteralPath $tempRoot).Path
    if (-not $resolved.StartsWith([System.IO.Path]::GetTempPath(), [System.StringComparison]::OrdinalIgnoreCase)) { throw "Refusing to remove non-temporary contract root: $resolved" }
    Remove-Item -LiteralPath $resolved -Recurse -Force
  }
}

Write-Host "Desktop target install evidence contract tests passed"
exit 0
