param()

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$startScript = Join-Path $PSScriptRoot "start_hardware_evidence.ps1"
$progressScript = Join-Path $PSScriptRoot "check_hardware_evidence_progress.ps1"
$createdRoots = New-Object System.Collections.Generic.List[string]

function New-TempRoot {
  param([string]$Prefix)

  $root = Join-Path ([System.IO.Path]::GetTempPath()) ($Prefix + "-" + [guid]::NewGuid().ToString("N"))
  $createdRoots.Add($root) | Out-Null
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  return $root
}

function Write-JsonFile {
  param(
    [string]$Path,
    [object]$Value
  )

  $dir = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($dir)) {
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
  }
  $Value | ConvertTo-Json -Depth 8 | Set-Content -Path $Path -Encoding UTF8
}

function Assert-Contains {
  param(
    [string]$Text,
    [string]$Needle,
    [string]$Description
  )

  if (-not $Text.Contains($Needle)) {
    throw "Missing $Description`: $Needle"
  }
}

function Assert-ReportHas {
  param(
    [object[]]$Items,
    [string]$Needle,
    [string]$Description
  )

  foreach ($item in @($Items)) {
    if ([string]$item -like "*$Needle*") {
      return
    }
  }
  throw "Expected $Description containing '$Needle'."
}

function Invoke-ProgressCheck {
  param([string]$EvidenceRoot)

  $powerShellExe = (Get-Process -Id $PID).Path
  $output = & $powerShellExe `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File $progressScript `
    -EvidenceRoot $EvidenceRoot `
    -ReportPath "BENCH_STATUS.json" 2>&1

  if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) {
    throw "Progress check exited with $LASTEXITCODE.`n$($output | Out-String)"
  }

  $reportPath = Join-Path $EvidenceRoot "BENCH_STATUS.json"
  if (-not (Test-Path -LiteralPath $reportPath)) {
    throw "Progress check did not write BENCH_STATUS.json.`n$($output | Out-String)"
  }

  return Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
}

try {
  Set-Location $repoRoot

  $startText = Get-Content -LiteralPath $startScript -Raw
  foreach ($pattern in @(
      "RUN_ANDROID_APK_INSTALL.cmd",
      "install_android_companion_apk.ps1",
      '-OutputDir `"$androidApkInstallDir`" %*',
      "RUN_ANDROID_COMPANION_PROBE.cmd",
      "run_android_companion_probe.ps1",
      '-OutputDir `"$androidCompanionProbeDir`" %*',
      "RUN_ANDROID_SCREEN_OFF_SOAK.cmd",
      "run_android_companion_soak.ps1",
      '-OutputDir `"$androidCompanionSoakDir`" %*',
      "RUN_ANDROID_UDP_BEACON_PROBE.cmd",
      "run_android_udp_beacon_probe.ps1",
      '-OutputDir `"$androidUdpBeaconProbeDir`" %*',
      "RUN_ANDROID_LOGCAT_CAPTURE.cmd",
      "capture_android_companion_logcat.ps1",
      '-OutputDir `"$androidLogcatDir`" %*',
      "exit /b %ERRORLEVEL%",
      "androidCompanionProbes = [ordered]@{",
      "apkInstallReport = `"android/apk-install/android_apk_install.json`"",
      "companionProbeReport = `"android/companion-probe/android_companion_probe.json`"",
      "udpBeaconProbeReport = `"android/udp-beacon-probe/android_udp_beacon_probe.json`"",
      "logcatReport = `"android/logcat/android_companion_logcat.json`"",
      "Android dashboard connected state",
      "robot identity",
      "firmware/version signal",
      "last bridge frame",
      "active brain owner",
      "foreground service state"
    )) {
    Assert-Contains -Text $startText -Needle $pattern -Description "Android evidence packet generator contract"
  }

  $progressText = Get-Content -LiteralPath $progressScript -Raw
  foreach ($pattern in @(
      "Test-OptionalAndroidProbeReport",
      "Test-AndroidDashboardManifestEvidence",
      "Test-AndroidCompanionReportPresent",
      "stackchan.android-apk-install.v1",
      "stackchan.android-companion-probe.v1",
      "stackchan.android-companion-soak.v1",
      "stackchan.android-udp-beacon-probe.v1",
      "stackchan.android-companion-logcat.v1",
      "optional unless Android is the companion bridge host",
      "media_manifest.json needs a photo/video entry",
      "Import the Android connected-dashboard screenshot",
      "RUN_ADD_MEDIA.cmd -Type Photo -Notes",
      "Android dashboard connected state; robot identity; firmware/version signal; last bridge frame; active brain owner; foreground service state"
    )) {
    Assert-Contains -Text $progressText -Needle $pattern -Description "Android evidence progress contract"
  }

  $evidenceRoot = New-TempRoot -Prefix "stackchan-android-evidence-packet-contract"
  Write-JsonFile -Path (Join-Path $evidenceRoot "metadata.json") -Value ([ordered]@{
      releaseTag = "contract-test"
      commit = ("c" * 40)
      androidCompanionProbes = [ordered]@{
        apkInstallReport = "android/apk-install/android_apk_install.json"
        companionProbeReport = "android/companion-probe/android_companion_probe.json"
        screenOffSoakReport = "android/screen-off-soak/android_companion_soak.json"
        udpBeaconProbeReport = "android/udp-beacon-probe/android_udp_beacon_probe.json"
        logcatReport = "android/logcat/android_companion_logcat.json"
      }
    })
  Write-JsonFile -Path (Join-Path $evidenceRoot "android/apk-install/android_apk_install.json") -Value ([ordered]@{
      schema = "stackchan.android-apk-install.v1"
      status = "installed"
      apkSha256 = ("a" * 64)
      sourceCommit = ("b" * 40)
      versionName = "1.0.0"
      versionCode = "100"
    })
  Write-JsonFile -Path (Join-Path $evidenceRoot "android/companion-probe/android_companion_probe.json") -Value ([ordered]@{
      schema = "stackchan.android-companion-probe.v1"
      status = "pass"
      issues = @()
    })
  Write-JsonFile -Path (Join-Path $evidenceRoot "android/screen-off-soak/android_companion_soak.json") -Value ([ordered]@{
      schema = "stackchan.android-companion-soak.v1"
      status = "pass"
      issues = @()
    })
  Write-JsonFile -Path (Join-Path $evidenceRoot "android/udp-beacon-probe/android_udp_beacon_probe.json") -Value ([ordered]@{
      schema = "stackchan.android-udp-beacon-probe.v1"
      status = "pass"
      issues = @()
    })
  Write-JsonFile -Path (Join-Path $evidenceRoot "android/logcat/android_companion_logcat.json") -Value ([ordered]@{
      schema = "stackchan.android-companion-logcat.v1"
      status = "captured"
      issues = @()
    })

  $report = Invoke-ProgressCheck -EvidenceRoot $evidenceRoot
  Assert-ReportHas -Items @($report.passes) -Needle "Android APK install evidence report status: installed" -Description "APK install progress pass"
  Assert-ReportHas -Items @($report.passes) -Needle "Android companion bridge probe report status: pass" -Description "companion probe progress pass"
  Assert-ReportHas -Items @($report.passes) -Needle "Android screen-off soak report status: pass" -Description "screen-off soak progress pass"
  Assert-ReportHas -Items @($report.passes) -Needle "Android UDP beacon probe report status: pass" -Description "UDP beacon progress pass"
  Assert-ReportHas -Items @($report.passes) -Needle "Android companion logcat capture report status: captured" -Description "logcat progress pass"
  Assert-ReportHas -Items @($report.findings) -Needle "connected-dashboard screenshot" -Description "dashboard screenshot finding"
  Assert-ReportHas -Items @($report.findings) -Needle "RUN_ADD_MEDIA.cmd -Type Photo -Notes" -Description "dashboard import command"

  Write-Host "Android evidence packet contract tests passed."
} finally {
  foreach ($root in $createdRoots) {
    if ([string]::IsNullOrWhiteSpace($root)) {
      continue
    }
    $resolvedRoot = Resolve-Path -LiteralPath $root -ErrorAction SilentlyContinue
    if ($null -ne $resolvedRoot -and $resolvedRoot.Path.StartsWith([System.IO.Path]::GetTempPath(), [System.StringComparison]::OrdinalIgnoreCase)) {
      Remove-Item -LiteralPath $resolvedRoot.Path -Recurse -Force
    }
  }
}
