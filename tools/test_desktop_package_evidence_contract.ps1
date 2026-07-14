param()

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$checker = Join-Path $PSScriptRoot "export_desktop_package_evidence.ps1"
$releaseExporter = Join-Path $PSScriptRoot "export_companion_release_evidence.ps1"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-desktop-package-evidence-" + [guid]::NewGuid().ToString("N"))
$powerShellHost = (Get-Process -Id $PID).Path

$checkerText = Get-Content -LiteralPath $checker -Raw
foreach ($pattern in @("Test-MacOSSignatureNormalizedRuntimeIdentity", '"--verify", "--strict"', "LC_CODE_SIGNATURE", "Get-MachOCodeContentIdentity", 'contentIdentityStatus = "ready-signature-normalized"', "architectureProofs.ToArray()", "proofs.ToArray()")) {
  if ($checkerText -notmatch [regex]::Escape($pattern)) {
    throw "Desktop package evidence must prove macOS installer rewrites by strict code-signature normalization: missing $pattern"
  }
}
Write-Host "[ok] macOS installer runtime identity requires strict code-signature normalization"

function Get-Sha256Text {
  param([string]$Path)
  return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Get-PayloadHash {
  param([string]$Root)
  $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd("\", "/")
  $prefix = $rootFull + [System.IO.Path]::DirectorySeparatorChar
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $utf8 = [System.Text.Encoding]::UTF8
  $files = Get-ChildItem -LiteralPath $Root -File -Recurse |
    Where-Object { $_.Name -ne "stackchan-python-runtime.json" } |
    Sort-Object FullName
  foreach ($file in $files) {
    $relative = $file.FullName.Substring($prefix.Length).Replace("\", "/")
    $pathBytes = $utf8.GetBytes("$relative`n")
    $null = $sha.TransformBlock($pathBytes, 0, $pathBytes.Length, $pathBytes, 0)
    $hashBytes = $utf8.GetBytes("$(Get-Sha256Text $file.FullName)`n")
    $null = $sha.TransformBlock($hashBytes, 0, $hashBytes.Length, $hashBytes, 0)
  }
  $empty = [byte[]]@()
  $null = $sha.TransformFinalBlock($empty, 0, 0)
  return (($sha.Hash | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Invoke-Evidence {
  param(
    [string]$PackagePath,
    [string]$PreparePath,
    [string]$ProcessedRoot,
    [string]$ExtractionRoot,
    [string]$LaunchPath,
    [string]$OutPath
  )
  $output = & $powerShellHost -NoProfile -File $checker `
    -Platform windows `
    -PackagePath $PackagePath `
    -RuntimePrepareJsonPath $PreparePath `
    -ProcessedRuntimeRoot $ProcessedRoot `
    -PackageExtractionRoot $ExtractionRoot `
    -LaunchEvidencePath $LaunchPath `
    -Version v1.0.0 `
    -Commit 1111111111111111111111111111111111111111 `
    -OutPath $OutPath `
    -RequireInstallerPayload `
    -RequireLaunchEvidence `
    -UseExistingPackageExtraction `
    -Json 2>&1 | Out-String
  return [ordered]@{ exitCode = $LASTEXITCODE; output = $output }
}

function New-FixtureApplicationJar {
  param(
    [string]$JarRoot,
    [string]$JarPath
  )
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  if (Test-Path -LiteralPath $JarPath) { Remove-Item -LiteralPath $JarPath -Force }
  [System.IO.Compression.ZipFile]::CreateFromDirectory($JarRoot, $JarPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)
}

try {
  $processedRoot = Join-Path $tempRoot "processed/python-runtime"
  New-Item -ItemType Directory -Force -Path (Join-Path $processedRoot "Lib") | Out-Null
  Set-Content -LiteralPath (Join-Path $processedRoot "python.exe") -Value "synthetic executable" -Encoding ASCII
  Set-Content -LiteralPath (Join-Path $processedRoot "Lib/runtime.txt") -Value "synthetic runtime" -Encoding ASCII
  $payloadHash = Get-PayloadHash $processedRoot
  $manifest = [ordered]@{
    schema = "stackchan.desktop-python-runtime.v1"
    pythonVersion = "Python 3.12.4"
    platform = "windows"
    source = "contract-fixture"
    sha256 = $payloadHash
    license = "Python Software Foundation License Version 2"
    builtAt = "2026-07-13T00:00:00Z"
  }
  $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $processedRoot "stackchan-python-runtime.json") -Encoding UTF8

  $preparePath = Join-Path $tempRoot "windows-prepare.json"
  $prepare = [ordered]@{
    schema = "stackchan.desktop-python-runtime-prepare.v1"
    status = "ready"
    platform = "windows"
    payloadSha256 = $payloadHash
    validation = [ordered]@{
      schema = "stackchan.desktop-python-runtime-payload.v1"
      status = "ready"
      platform = "windows"
      runtimeSha256 = $payloadHash
      runtimeSource = "contract-fixture"
      pythonVersion = "Python 3.12.4"
      probedPythonVersion = "Python 3.12.4"
    }
  }
  $prepare | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $preparePath -Encoding UTF8
  $packagePath = Join-Path $tempRoot "Stackchan Companion-1.0.0.msi"
  Set-Content -LiteralPath $packagePath -Value "synthetic msi" -Encoding ASCII

  $requiredBrainFiles = @(
    "brain/bridge/lan_service.py",
    "brain/bridge/reference_bridge.py",
    "brain/data/voice_source_provenance.yaml",
    "brain/docs/media/voice/stackchan_spark_greeting.wav"
  )
  $jarRoot = Join-Path $tempRoot "jar-root"
  foreach ($brainPath in $requiredBrainFiles) {
    $targetPath = Join-Path $jarRoot $brainPath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $targetPath) | Out-Null
    Set-Content -LiteralPath $targetPath -Value "fixture resource: $brainPath" -Encoding ASCII
  }
  $extractionRoot = Join-Path $tempRoot "package-extraction"
  New-Item -ItemType Directory -Force -Path $extractionRoot | Out-Null
  $installerRuntimeRoot = Join-Path $extractionRoot "Stackchan Companion/python-runtime"
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $installerRuntimeRoot) | Out-Null
  Copy-Item -LiteralPath $processedRoot -Destination $installerRuntimeRoot -Recurse
  $fixtureJar = Join-Path $extractionRoot "app-desktop-1.0.0-fixture.jar"
  New-FixtureApplicationJar -JarRoot $jarRoot -JarPath $fixtureJar

  $launchPath = Join-Path $tempRoot "windows-package-launch.json"
  $launch = [ordered]@{
    schema = "stackchan.desktop-package-launch-evidence.v1"
    status = "ready"
    platform = "windows"
    package = [ordered]@{ name = (Split-Path -Leaf $packagePath); bytes = (Get-Item $packagePath).Length; sha256 = Get-Sha256Text $packagePath }
    extractionMethod = "native"
    extractionRoot = $extractionRoot
    launcherPath = "fixture/Stackchan Companion.exe"
    processExitCode = 0
    probe = [ordered]@{
      schema = "stackchan.desktop-packaged-runtime-smoke.v1"
      status = "ready"
      platform = "windows"
      appVersion = "1.0.0"
      protocol = "stackchan.bridge.v1"
      runtimePresent = $true
      pythonAvailable = $true
      pythonVersion = "Python 3.12.4"
      brainScriptAvailable = $true
      launchContext = "package-extraction"
      scope = "extracted-native-package-headless-runtime-probe"
      substitutesForTargetInstall = $false
      issues = @()
    }
    scope = "exact-native-package-extraction-and-headless-launch"
    substitutesForTargetInstall = $false
    issues = @()
  }
  $launch | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $launchPath -Encoding UTF8

  $readyPath = Join-Path $tempRoot "ready.json"
  $ready = Invoke-Evidence $packagePath $preparePath $processedRoot $extractionRoot $launchPath $readyPath
  if ($ready.exitCode -ne 0) { throw "Complete desktop package evidence was rejected: $($ready.output)" }
  $readyReport = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
  if ($readyReport.status -ne "ready" -or
      $readyReport.runtime.processedPayloadSha256 -ne $payloadHash -or
      $readyReport.installerPayload.status -ne "ready" -or
      $readyReport.installerPayload.runtimeLocation -ne "native-app-resources" -or
      $readyReport.installerPayload.runtimePayloadSha256 -ne $payloadHash -or
      $readyReport.installerPayload.contentIdentityStatus -ne "ready-exact" -or
      $readyReport.launchEvidence.status -ne "ready" -or
      @($readyReport.installerPayload.requiredBrainFiles).Count -ne $requiredBrainFiles.Count) {
    throw "Complete desktop package evidence did not preserve the processed and installer runtime proof."
  }
  Write-Host "[ok] complete installer-derived desktop package evidence is accepted"

  $launch.probe.launchContext = "installed-package"
  $launch.probe.scope = "installed-native-package-headless-runtime-probe"
  $launch | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $launchPath -Encoding UTF8
  $wrongLaunchContext = Invoke-Evidence $packagePath $preparePath $processedRoot $extractionRoot $launchPath (Join-Path $tempRoot "wrong-launch-context.json")
  if ($wrongLaunchContext.exitCode -eq 0 -or $wrongLaunchContext.output -notmatch "probe context is invalid") {
    throw "Installed-package probe context was accepted as extraction evidence."
  }
  Write-Host "[ok] installed launch context cannot replace package-extraction evidence"
  $launch.probe.launchContext = "package-extraction"
  $launch.probe.scope = "extracted-native-package-headless-runtime-probe"
  $launch | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $launchPath -Encoding UTF8

  Set-Content -LiteralPath (Join-Path $installerRuntimeRoot "Lib/runtime.txt") -Value "tampered installer runtime" -Encoding ASCII
  $tamperedInstaller = Invoke-Evidence $packagePath $preparePath $processedRoot $extractionRoot $launchPath (Join-Path $tempRoot "tampered-installer.json")
  if ($tamperedInstaller.exitCode -eq 0 -or
      $tamperedInstaller.output -notmatch "Installer runtime payload hash does not match" -or
      $tamperedInstaller.output -notmatch "Processed/installer runtime difference: changed Lib/runtime.txt") {
    throw "Tampered installer runtime was not rejected."
  }
  Write-Host "[ok] installer runtime tampering is rejected"
  Set-Content -LiteralPath (Join-Path $installerRuntimeRoot "Lib/runtime.txt") -Value "synthetic runtime" -Encoding ASCII

  $jarRuntimeRoot = Join-Path $jarRoot "python-runtime"
  Copy-Item -LiteralPath $processedRoot -Destination $jarRuntimeRoot -Recurse
  New-FixtureApplicationJar -JarRoot $jarRoot -JarPath $fixtureJar
  $embeddedRuntime = Invoke-Evidence $packagePath $preparePath $processedRoot $extractionRoot $launchPath (Join-Path $tempRoot "embedded-runtime.json")
  if ($embeddedRuntime.exitCode -eq 0 -or $embeddedRuntime.output -notmatch "must not contain the executable managed runtime") {
    throw "JAR-embedded executable runtime was not rejected."
  }
  Write-Host "[ok] JAR-embedded executable runtime is rejected"
  Remove-Item -LiteralPath $jarRuntimeRoot -Recurse -Force
  New-FixtureApplicationJar -JarRoot $jarRoot -JarPath $fixtureJar

  $aggregateRoot = Join-Path $tempRoot "aggregate"
  New-Item -ItemType Directory -Force -Path $aggregateRoot | Out-Null
  foreach ($target in @(
    [ordered]@{ platform = "windows"; extension = ".msi" },
    [ordered]@{ platform = "linux"; extension = ".deb" },
    [ordered]@{ platform = "macos"; extension = ".dmg" }
  )) {
    $targetPackage = Join-Path $aggregateRoot ("stackchan-companion-{0}-v1.0.0{1}" -f $target.platform, $target.extension)
    Set-Content -LiteralPath $targetPackage -Value ("synthetic {0} package" -f $target.platform) -Encoding ASCII
    $targetItem = Get-Item -LiteralPath $targetPackage
    $targetPackageSha = Get-Sha256Text $targetItem.FullName
    $processedFiles = @(Get-ChildItem -LiteralPath $processedRoot -File -Recurse)
    $processedBytes = [int64](($processedFiles | Measure-Object -Property Length -Sum).Sum)
    $targetReport = [ordered]@{
      schema = "stackchan.desktop-package-evidence.v1"
      status = "ready"
      platform = $target.platform
      version = "v1.0.0"
      commit = "1111111111111111111111111111111111111111"
      package = [ordered]@{
        name = $targetItem.Name
        extension = $target.extension
        bytes = [int64]$targetItem.Length
        sha256 = $targetPackageSha
      }
      runtime = [ordered]@{
        payloadSha256 = $payloadHash
        processedPayloadSha256 = $payloadHash
        source = "contract-fixture"
        pythonVersion = "Python 3.12.4"
        probedPythonVersion = "Python 3.12.4"
        processedFileCount = $processedFiles.Count
        processedBytes = $processedBytes
      }
      installerPayload = [ordered]@{
        required = $true
        status = "ready"
        extractionMethod = "native"
        appJarName = "app-desktop-1.0.0-fixture.jar"
        appJarSha256 = $payloadHash
        packageSha256 = $targetPackageSha
        runtimeLocation = "native-app-resources"
        runtimeRootRelative = "Stackchan Companion/python-runtime"
        runtimePayloadSha256 = $payloadHash
        runtimeFileCount = $processedFiles.Count
        runtimeBytes = $processedBytes
        runtimeManifestSchema = "stackchan.desktop-python-runtime.v1"
        runtimeManifestPlatform = $target.platform
        runtimeManifestSha256 = $payloadHash
        contentIdentityStatus = "ready-exact"
        signatureNormalization = [ordered]@{
          status = "not-required"
          tool = ""
          processedPayloadSha256 = ""
          installerPayloadSha256 = ""
          changedFileCount = 0
          files = @()
        }
        requiredBrainFiles = @($requiredBrainFiles)
      }
      launchEvidence = [ordered]@{
        required = $true
        status = "ready"
        packageSha256 = $targetPackageSha
        extractionMethod = "native"
        launcherPath = "fixture/Stackchan Companion"
        processExitCode = 0
        pythonVersion = "Python 3.12.4"
        scope = "exact-native-package-extraction-and-headless-launch"
      }
      issues = @()
    }
    if ($target.platform -eq "macos") {
      $macosInstallerPayloadSha = "b" * 64
      $targetReport.installerPayload.runtimePayloadSha256 = $macosInstallerPayloadSha
      $targetReport.installerPayload.runtimeBytes = $processedBytes + 128
      $targetReport.installerPayload.contentIdentityStatus = "ready-signature-normalized"
      $targetReport.installerPayload.signatureNormalization = [ordered]@{
        status = "ready"
        tool = "codesign"
        processedPayloadSha256 = $payloadHash
        installerPayloadSha256 = $macosInstallerPayloadSha
        changedFileCount = 1
        files = @([ordered]@{
          path = "lib/libpython3.12.dylib"
          processedFileSha256 = "c" * 64
          installerFileSha256 = "d" * 64
          normalizedFileSha256 = "e" * 64
          architectures = @([ordered]@{
            architecture = "arm64"
            codeContentSha256 = "f" * 64
            codeBytes = 1024
            processedSignatureBytes = 256
            installerSignatureBytes = 192
            processedLinkEditFileBytes = 4096
            installerLinkEditFileBytes = 4032
            processedLinkEditVirtualBytes = 16384
            installerLinkEditVirtualBytes = 8192
          })
        })
      }
    }
    $targetReport | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $aggregateRoot ("{0}-package-evidence.json" -f $target.platform)) -Encoding UTF8
  }

  $aggregateOut = Join-Path $tempRoot "aggregate-out"
  $aggregateOutput = & $powerShellHost -NoProfile -File $releaseExporter `
    -Version v1.0.0 `
    -Commit 1111111111111111111111111111111111111111 `
    -DesktopArtifactRoot $aggregateRoot `
    -DesktopPackageEvidenceRoot $aggregateRoot `
    -OutDir $aggregateOut `
    -Json 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { throw "Complete aggregate desktop package evidence unexpectedly failed: $aggregateOutput" }
  $aggregateReport = $aggregateOutput | ConvertFrom-Json
  if ($aggregateReport.desktopPackageEvidence.status -ne "ready" -or @($aggregateReport.desktopPackageEvidence.platforms).Count -ne 3) {
    throw "Complete aggregate desktop package evidence did not report three ready platforms."
  }
  Write-Host "[ok] aggregate companion evidence accepts all three native package reports"

  $macosReportPath = Join-Path $aggregateRoot "macos-package-evidence.json"
  $macosReport = Get-Content -LiteralPath $macosReportPath -Raw | ConvertFrom-Json
  $macosReport.installerPayload.runtimePayloadSha256 = "0" * 64
  $macosReport | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $macosReportPath -Encoding UTF8
  $aggregateTamperedOutput = & $powerShellHost -NoProfile -File $releaseExporter `
    -Version v1.0.0 `
    -Commit 1111111111111111111111111111111111111111 `
    -DesktopArtifactRoot $aggregateRoot `
    -DesktopPackageEvidenceRoot $aggregateRoot `
    -OutDir (Join-Path $tempRoot "aggregate-tampered-out") `
    -RequireDesktopPackageEvidence `
    -Json 2>&1 | Out-String
  if ($LASTEXITCODE -ne 2) { throw "Strict aggregate evidence did not reject a tampered installer runtime: $aggregateTamperedOutput" }
  $aggregateTamperedReport = $aggregateTamperedOutput | ConvertFrom-Json
  if (@($aggregateTamperedReport.pending) -notcontains "desktop-native-package-runtime-evidence") {
    throw "Strict aggregate evidence did not preserve the installer runtime mismatch marker."
  }
  Write-Host "[ok] aggregate companion evidence rejects installer-derived runtime mismatch"
  $macosReport.installerPayload.runtimePayloadSha256 = $macosReport.installerPayload.signatureNormalization.installerPayloadSha256
  $macosReport | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $macosReportPath -Encoding UTF8

  $macosReport.launchEvidence.packageSha256 = "0" * 64
  $macosReport | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $macosReportPath -Encoding UTF8
  $staleLaunchOutput = & $powerShellHost -NoProfile -File $releaseExporter `
    -Version v1.0.0 `
    -Commit 1111111111111111111111111111111111111111 `
    -DesktopArtifactRoot $aggregateRoot `
    -DesktopPackageEvidenceRoot $aggregateRoot `
    -OutDir (Join-Path $tempRoot "aggregate-stale-launch-out") `
    -RequireDesktopPackageEvidence `
    -Json 2>&1 | Out-String
  if ($LASTEXITCODE -ne 2 -or $staleLaunchOutput -notmatch "desktop-native-package-runtime-evidence") { throw "Strict aggregate evidence did not reject stale package launch evidence." }
  Write-Host "[ok] aggregate companion evidence rejects stale exact-package launch evidence"
  $macosReport.launchEvidence.packageSha256 = (Get-Sha256Text (Join-Path $aggregateRoot "stackchan-companion-macos-v1.0.0.dmg"))
  $macosReport | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $macosReportPath -Encoding UTF8

  Remove-Item -LiteralPath $macosReportPath -Force
  $missingOut = Join-Path $tempRoot "aggregate-missing-out"
  $missingOutput = & $powerShellHost -NoProfile -File $releaseExporter `
    -Version v1.0.0 `
    -Commit 1111111111111111111111111111111111111111 `
    -DesktopArtifactRoot $aggregateRoot `
    -DesktopPackageEvidenceRoot $aggregateRoot `
    -OutDir $missingOut `
    -RequireDesktopPackageEvidence `
    -Json 2>&1 | Out-String
  if ($LASTEXITCODE -ne 2) { throw "Strict aggregate evidence did not fail when a native report was missing: $missingOutput" }
  $missingReport = $missingOutput | ConvertFrom-Json
  if (@($missingReport.pending) -notcontains "desktop-native-package-runtime-evidence") {
    throw "Strict aggregate evidence did not preserve the missing native package marker."
  }
  Write-Host "[ok] strict aggregate evidence rejects a missing native package report"

  $wrongExtension = Join-Path $tempRoot "Stackchan Companion-1.0.0.deb"
  Copy-Item -LiteralPath $packagePath -Destination $wrongExtension
  $wrong = Invoke-Evidence $wrongExtension $preparePath $processedRoot $extractionRoot $launchPath (Join-Path $tempRoot "wrong-extension.json")
  if ($wrong.exitCode -eq 0 -or $wrong.output -notmatch "must use .msi") { throw "Wrong desktop package extension was not rejected." }
  Write-Host "[ok] wrong platform package extension is rejected"

  Set-Content -LiteralPath (Join-Path $processedRoot "Lib/runtime.txt") -Value "tampered runtime" -Encoding ASCII
  $tampered = Invoke-Evidence $packagePath $preparePath $processedRoot $extractionRoot $launchPath (Join-Path $tempRoot "tampered.json")
  if ($tampered.exitCode -eq 0 -or $tampered.output -notmatch "payload hash does not match") { throw "Tampered processed runtime was not rejected." }
  Write-Host "[ok] processed runtime tampering is rejected"

  $prepare.platform = "linux"
  $prepare.validation.platform = "linux"
  $prepare | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $preparePath -Encoding UTF8
  $wrongPlatform = Invoke-Evidence $packagePath $preparePath $processedRoot $extractionRoot $launchPath (Join-Path $tempRoot "wrong-platform.json")
  if ($wrongPlatform.exitCode -eq 0 -or $wrongPlatform.output -notmatch "must be windows") { throw "Wrong runtime evidence platform was not rejected." }
  Write-Host "[ok] runtime prepare platform mismatch is rejected"
} finally {
  if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

Write-Host "Desktop package evidence contract tests passed"
exit 0
