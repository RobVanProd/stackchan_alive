param()

$ErrorActionPreference = "Stop"
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$checker = Join-Path $PSScriptRoot "export_desktop_package_evidence.ps1"
$releaseExporter = Join-Path $PSScriptRoot "export_companion_release_evidence.ps1"
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("stackchan-desktop-package-evidence-" + [guid]::NewGuid().ToString("N"))

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
    [string]$OutPath
  )
  $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $checker `
    -Platform windows `
    -PackagePath $PackagePath `
    -RuntimePrepareJsonPath $PreparePath `
    -ProcessedRuntimeRoot $ProcessedRoot `
    -Version v1.0.0 `
    -Commit 1111111111111111111111111111111111111111 `
    -OutPath $OutPath `
    -Json 2>&1 | Out-String
  return [ordered]@{ exitCode = $LASTEXITCODE; output = $output }
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

  $readyPath = Join-Path $tempRoot "ready.json"
  $ready = Invoke-Evidence $packagePath $preparePath $processedRoot $readyPath
  if ($ready.exitCode -ne 0) { throw "Complete desktop package evidence was rejected: $($ready.output)" }
  $readyReport = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
  if ($readyReport.status -ne "ready" -or $readyReport.runtime.processedPayloadSha256 -ne $payloadHash) {
    throw "Complete desktop package evidence did not preserve the processed runtime hash."
  }
  Write-Host "[ok] complete desktop package evidence is accepted"

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
        sha256 = Get-Sha256Text $targetItem.FullName
      }
      runtime = [ordered]@{
        payloadSha256 = $payloadHash
        processedPayloadSha256 = $payloadHash
        source = "contract-fixture"
        pythonVersion = "Python 3.12.4"
        probedPythonVersion = "Python 3.12.4"
        processedFileCount = 2
        processedBytes = 64
      }
      issues = @()
    }
    $targetReport | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath (Join-Path $aggregateRoot ("{0}-package-evidence.json" -f $target.platform)) -Encoding UTF8
  }

  $aggregateOut = Join-Path $tempRoot "aggregate-out"
  $aggregateOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $releaseExporter `
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

  Remove-Item -LiteralPath (Join-Path $aggregateRoot "macos-package-evidence.json") -Force
  $missingOut = Join-Path $tempRoot "aggregate-missing-out"
  $missingOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $releaseExporter `
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
  $wrong = Invoke-Evidence $wrongExtension $preparePath $processedRoot (Join-Path $tempRoot "wrong-extension.json")
  if ($wrong.exitCode -eq 0 -or $wrong.output -notmatch "must use .msi") { throw "Wrong desktop package extension was not rejected." }
  Write-Host "[ok] wrong platform package extension is rejected"

  Set-Content -LiteralPath (Join-Path $processedRoot "Lib/runtime.txt") -Value "tampered runtime" -Encoding ASCII
  $tampered = Invoke-Evidence $packagePath $preparePath $processedRoot (Join-Path $tempRoot "tampered.json")
  if ($tampered.exitCode -eq 0 -or $tampered.output -notmatch "payload hash does not match") { throw "Tampered processed runtime was not rejected." }
  Write-Host "[ok] processed runtime tampering is rejected"

  $prepare.platform = "linux"
  $prepare.validation.platform = "linux"
  $prepare | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $preparePath -Encoding UTF8
  $wrongPlatform = Invoke-Evidence $packagePath $preparePath $processedRoot (Join-Path $tempRoot "wrong-platform.json")
  if ($wrongPlatform.exitCode -eq 0 -or $wrongPlatform.output -notmatch "must be windows") { throw "Wrong runtime evidence platform was not rejected." }
  Write-Host "[ok] runtime prepare platform mismatch is rejected"
} finally {
  if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}

Write-Host "Desktop package evidence contract tests passed"
