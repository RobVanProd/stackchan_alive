param(
  [string]$Root = "",
  [switch]$Json
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Root)) {
  $Root = Resolve-Path (Join-Path $PSScriptRoot "..")
} else {
  $Root = Resolve-Path $Root
}

$checks = @()
$pendingGates = @(
  "physical-robot-hardware-validation",
  "android-apk-install-on-target-phone",
  "android-dashboard-connected-state-media",
  "screen-off-bridge-soak",
  "c8-tagged-release-distribution",
  "production-voice-source-before-consumer-rollout"
)

function Add-Check {
  param(
    [string]$Id,
    [string]$Name,
    [ValidateSet("pass", "fail", "pending")]
    [string]$Status,
    [string]$Evidence,
    [string]$Detail
  )

  $script:checks += [ordered]@{
    id = $Id
    name = $Name
    status = $Status
    evidence = $Evidence
    detail = $Detail
  }
}

function Join-RootPath {
  param([string]$RelativePath)
  return Join-Path $Root $RelativePath
}

function Find-FirstExistingPath {
  param(
    [string[]]$RelativePaths,
    [string]$PathType = "Any"
  )

  foreach ($relativePath in $RelativePaths) {
    $path = Join-RootPath $relativePath
    if ($PathType -eq "Leaf") {
      if (Test-Path -LiteralPath $path -PathType Leaf) {
        return [ordered]@{ relative = $relativePath; path = $path }
      }
    } elseif ($PathType -eq "Container") {
      if (Test-Path -LiteralPath $path -PathType Container) {
        return [ordered]@{ relative = $relativePath; path = $path }
      }
    } elseif (Test-Path -LiteralPath $path) {
      return [ordered]@{ relative = $relativePath; path = $path }
    }
  }

  return $null
}

function Test-TextEvidence {
  param(
    [string]$Id,
    [string]$Name,
    [string[]]$RelativePaths,
    [string[]]$Patterns
  )

  $match = Find-FirstExistingPath -RelativePaths $RelativePaths -PathType "Leaf"
  if ($null -eq $match) {
    Add-Check $Id $Name "fail" "" ("Missing file. Looked for: " + ($RelativePaths -join ", "))
    return
  }

  $text = Get-Content -LiteralPath $match.path -Raw
  $missing = @()
  foreach ($pattern in $Patterns) {
    if ($text -notmatch [regex]::Escape($pattern)) {
      $missing += $pattern
    }
  }

  if ($missing.Count -gt 0) {
    Add-Check $Id $Name "fail" $match.relative ("Missing required text: " + ($missing -join ", "))
  } else {
    Add-Check $Id $Name "pass" $match.relative "Required guidance is present."
  }
}

function Test-RequiredFiles {
  param(
    [string]$Id,
    [string]$Name,
    [string[]]$RelativeFiles
  )

  $missing = @()
  foreach ($relativeFile in $RelativeFiles) {
    if (-not (Test-Path -LiteralPath (Join-RootPath $relativeFile) -PathType Leaf)) {
      $missing += $relativeFile
    }
  }

  if ($missing.Count -gt 0) {
    Add-Check $Id $Name "fail" "" ("Missing files: " + ($missing -join ", "))
  } else {
    Add-Check $Id $Name "pass" ($RelativeFiles -join ", ") "Required files are present."
  }
}

function Test-RequiredFileSetCandidates {
  param(
    [string]$Id,
    [string]$Name,
    [string[][]]$CandidateSets
  )

  $setSummaries = @()
  foreach ($candidateSet in $CandidateSets) {
    $missing = @()
    foreach ($relativeFile in $candidateSet) {
      if (-not (Test-Path -LiteralPath (Join-RootPath $relativeFile) -PathType Leaf)) {
        $missing += $relativeFile
      }
    }
    if ($missing.Count -eq 0) {
      Add-Check $Id $Name "pass" ($candidateSet -join ", ") "Required files are present."
      return
    }
    $setSummaries += ("missing from candidate set: " + ($missing -join ", "))
  }

  Add-Check $Id $Name "fail" "" ($setSummaries -join "; ")
}

function Test-ProtocolFixtures {
  $fixtureRoot = Find-FirstExistingPath -RelativePaths @("protocol-fixtures", "provenance/protocol-fixtures") -PathType "Container"
  if ($null -eq $fixtureRoot) {
    Add-Check "protocol-fixtures" "Protocol fixture provenance" "fail" "" "Missing protocol-fixtures or provenance/protocol-fixtures."
    return
  }

  $required = @(
    "endpoint_hello.json",
    "bridge_hello.json",
    "heartbeat.json",
    "claim_brain.json",
    "owner_status.json",
    "settings_get.json",
    "settings_set.json",
    "trusted_endpoints.json",
    "forget_endpoint.json",
    "audio_stream_start.json",
    "audio.json",
    "audio_stream_end.json",
    "unknown_future_message.json",
    "invalid/missing_type.json",
    "invalid/wrong_protocol.json",
    "invalid/camel_case_field.json"
  )
  $missing = @()
  foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot.path $relative) -PathType Leaf)) {
      $missing += $relative
    }
  }

  if ($missing.Count -gt 0) {
    Add-Check "protocol-fixtures" "Protocol fixture provenance" "fail" $fixtureRoot.relative ("Missing fixtures: " + ($missing -join ", "))
  } else {
    Add-Check "protocol-fixtures" "Protocol fixture provenance" "pass" $fixtureRoot.relative "Valid, future-message, and invalid fixtures are present."
  }
}

function Test-CompanionSourceTree {
  $sourceRoot = Find-FirstExistingPath -RelativePaths @("companion", "provenance/companion") -PathType "Container"
  if ($null -eq $sourceRoot) {
    Add-Check "companion-source-tree" "Companion KMP source tree" "fail" "" "Missing companion or provenance/companion."
    return
  }

  $required = @(
    "settings.gradle.kts",
    "gradle/libs.versions.toml",
    "core/src/commonMain/kotlin/dev/stackchan/companion/core/ProtocolMessage.kt",
    "core/src/commonMain/kotlin/dev/stackchan/companion/core/EndpointServer.kt",
    "core/src/commonMain/kotlin/dev/stackchan/companion/core/BrainOwnerCoordinator.kt",
    "core/src/desktopTest/kotlin/dev/stackchan/companion/core/ProtocolFixtureConformanceTest.kt",
    "core/src/desktopTest/kotlin/dev/stackchan/companion/core/EndpointServerTest.kt",
    "core/src/desktopTest/kotlin/dev/stackchan/companion/core/JmDnsDiscoveryTest.kt",
    "core/src/commonTest/kotlin/dev/stackchan/companion/core/BrainOwnerCoordinatorTest.kt",
    "app-android/src/main/AndroidManifest.xml",
    "app-android/src/main/kotlin/dev/stackchan/companion/android/CompanionBridgeService.kt",
    "app-desktop/src/main/kotlin/dev/stackchan/companion/desktop/C0Spike.kt",
    "app-desktop/src/main/kotlin/dev/stackchan/companion/desktop/DesktopBrainSupervisor.kt",
    "ui/src/commonMain/kotlin/dev/stackchan/companion/ui/CompanionConsole.kt"
  )

  $missing = @()
  foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $sourceRoot.path $relative) -PathType Leaf)) {
      $missing += $relative
    }
  }

  if ($missing.Count -gt 0) {
    Add-Check "companion-source-tree" "Companion KMP source tree" "fail" $sourceRoot.relative ("Missing companion files: " + ($missing -join ", "))
  } else {
    Add-Check "companion-source-tree" "Companion KMP source tree" "pass" $sourceRoot.relative "Shared core, Android, desktop, UI, and C0/C1 tests are present."
  }
}

function Add-PendingGateChecks {
  foreach ($gate in $pendingGates) {
    Add-Check ("pending-" + $gate) $gate "pending" "" "Requires target hardware, release signing/distribution, or production-source evidence outside this source/package check."
  }
}

Test-TextEvidence `
  -Id "cross-platform-plan" `
  -Name "Drive cross-platform plan packaged" `
  -RelativePaths @("docs/COMPANION_CROSS_PLATFORM_PLAN.md") `
  -Patterns @("Cross-Platform Build & Distribution Plan", "Kotlin Multiplatform", "Compose Multiplatform", "Hydraulic Conveyor", "C0", "C1", "C8", "RELEASE_EVIDENCE.json")

Test-TextEvidence `
  -Id "android-companion-spec" `
  -Name "Android companion behavioral contract" `
  -RelativePaths @("docs/ANDROID_COMPANION_SPEC.md") `
  -Patterns @("PC Brain Mode", "Mobile Brain Mode", "active brain owner", "settings_get", "settings_set", "forget_endpoint", "LiteRT-LM", "safety-locked")

Test-TextEvidence `
  -Id "android-test-plan" `
  -Name "Android physical test plan" `
  -RelativePaths @("docs/ANDROID_COMPANION_TEST_PLAN.md") `
  -Patterns @("Android Companion Physical Test Plan", "lab-signed release APK", "app-android-release.apk", "check_android_toolchain.cmd", "RUN_ANDROID_APK_INSTALL.cmd", "RUN_ANDROID_COMPANION_PROBE.cmd", "RUN_ANDROID_SCREEN_OFF_SOAK.cmd", "android/screen-off-soak/", "RUN_ANDROID_LOGCAT_CAPTURE.cmd", "Android dashboard switches from waiting to connected")

Test-TextEvidence `
  -Id "android-screen-off-soak-helper" `
  -Name "Android screen-off soak helper" `
  -RelativePaths @("bridge/android_companion_soak.py", "tools/run_android_companion_soak.ps1") `
  -Patterns @("stackchan.android-companion-soak.v1", "DEFAULT_DURATION_SECONDS = 600.0", "DEFAULT_INTERVAL_SECONDS = 30.0", "android_companion_soak.json", "ANDROID_COMPANION_SOAK.md", "--duration-seconds", "--interval-seconds", "--max-failures")

Test-TextEvidence `
  -Id "ci-companion-tests" `
  -Name "Companion CI pre-arrival checks" `
  -RelativePaths @(".github/workflows/firmware.yml", "provenance/firmware.yml") `
  -Patterns @("companion-tests", "companion-platform-builds", "companion-release-evidence", "export_companion_release_evidence.ps1", "java-version: `"21`"", "android-actions/setup-android", "platforms;android-36", "./gradlew check :app-desktop:c0Spike")

Test-TextEvidence `
  -Id "android-toolchain-check" `
  -Name "Android build toolchain preflight" `
  -RelativePaths @("tools/check_android_toolchain.ps1") `
  -Patterns @("stackchan.android-toolchain-check.v1", "JAVA_HOME", "ANDROID_SDK_ROOT", "platforms/android-36", "companion/gradlew.bat")

Test-TextEvidence `
  -Id "gradle-toolchain-pins" `
  -Name "Companion Gradle toolchain pins" `
  -RelativePaths @("companion/gradle/libs.versions.toml", "provenance/companion/gradle/libs.versions.toml") `
  -Patterns @("kotlin", "compose", "ktor", "jmdns", "agp")

Test-TextEvidence `
  -Id "android-foreground-service" `
  -Name "Android bridge foreground service" `
  -RelativePaths @("companion/app-android/src/main/AndroidManifest.xml", "provenance/companion/app-android/src/main/AndroidManifest.xml") `
  -Patterns @("CompanionBridgeService", "foregroundServiceType", "connectedDevice")

Test-RequiredFileSetCandidates `
  -Id "python-fixture-tests" `
  -Name "Python protocol fixture conformance" `
  -CandidateSets @(
    @("bridge/test_protocol_fixtures.py", "bridge/export_protocol_fixtures.py"),
    @("provenance/bridge/test_protocol_fixtures.py", "provenance/bridge/export_protocol_fixtures.py")
  )

Test-ProtocolFixtures
Test-CompanionSourceTree
Add-PendingGateChecks

$failedChecks = @($checks | Where-Object { $_.status -eq "fail" })
$passedChecks = @($checks | Where-Object { $_.status -eq "pass" })
$pendingChecks = @($checks | Where-Object { $_.status -eq "pending" })
$status = if ($failedChecks.Count -gt 0) { "not-ready" } else { "source-ready-pending-hardware" }

$report = [ordered]@{
  schema = "stackchan.companion-v1-readiness.v1"
  status = $status
  root = [string]$Root
  passed = $passedChecks.Count
  failed = $failedChecks.Count
  pending = $pendingChecks.Count
  checks = @($checks)
}

if ($Json) {
  $report | ConvertTo-Json -Depth 8
} else {
  Write-Host "Companion v1 readiness: $status"
  Write-Host "Root: $Root"
  Write-Host "Passed: $($passedChecks.Count)  Failed: $($failedChecks.Count)  Pending gates: $($pendingChecks.Count)"
  Write-Host ""
  foreach ($check in $checks) {
    $prefix = if ($check.status -eq "pass") { "PASS" } elseif ($check.status -eq "pending") { "PENDING" } else { "FAIL" }
    Write-Host "[$prefix] $($check.name)"
    if (-not [string]::IsNullOrWhiteSpace($check.evidence)) {
      Write-Host "  evidence: $($check.evidence)"
    }
    if (-not [string]::IsNullOrWhiteSpace($check.detail)) {
      Write-Host "  detail: $($check.detail)"
    }
  }
}

if ($failedChecks.Count -gt 0) {
  exit 2
}
