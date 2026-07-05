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
  "google-play-store-screenshots",
  "google-play-internal-testing-upload",
  "gemma4-e2b-real-device-download-and-inference-validation",
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
    "app-android/src/main/kotlin/dev/stackchan/companion/android/AndroidDiagnosticsExport.kt",
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
  -Patterns @("PC Brain Mode", "Mobile Brain Mode", "active brain owner", "settings_get", "settings_set", "forget_endpoint", "LiteRT-LM", "Gemma-4-E2B", "download button", "load/eject controls", "gemma-4-E2B-it.litertlm", "2588147712", "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c", "Persona library", "import a validated persona pack", "safety-locked", "Add your Stack-chan", "Wi-Fi bootstrap step", "native Wi-Fi settings", "pairing code", "phone fingerprint", "stackchan://pair", "endpoint_hello.pairing_code", "STACKCHAN_PAIRING_SHORT_CODE", "pairing code <ABC123>", "pairing_code_mismatch", "saved robot", "diagnostics, persona", "handoff status panels", "claim_brain", "release_brain", "settings_result", "owner_status", "hello-connected robot session", "remove path", "Talk surface", "app_text_turn", "robot completes the", "raw WebSocket connection without robot", "stackchan.android.diagnostics-export.v1", "ANDROID_DIAGNOSTICS_EXPORT.json")

Test-TextEvidence `
  -Id "android-test-plan" `
  -Name "Android physical test plan" `
  -RelativePaths @("docs/ANDROID_COMPANION_TEST_PLAN.md") `
  -Patterns @("Android Companion Physical Test Plan", "lab-signed release APK", "app-android-release.apk", "check_android_toolchain.cmd", "RUN_ANDROID_APK_INSTALL.cmd", "RUN_ANDROID_COMPANION_PROBE.cmd", "RUN_ANDROID_SCREEN_OFF_SOAK.cmd", "android/screen-off-soak/", "RUN_ANDROID_LOGCAT_CAPTURE.cmd", "Android dashboard switches from waiting to connected", "Add your Stack-chan", "Wi-Fi bootstrap", "Open Wi-Fi settings", "Join Wi-Fi", "Start phone bridge", "Connect Stack-chan", "Confirm robot ready", "current next step", "Pair on Stack-chan", "Ready to test", "pairing code", "phone fingerprint", "stackchan://pair", "endpoint_hello.pairing_code", "STACKCHAN_PAIRING_SHORT_CODE", "pairing code <ABC123>", "pairing clear", "pairing_code_mismatch", "saved robots", "waiting/setup action", "trusted companion nodes are stored", "raw WebSocket connection without the robot", "Talk screen enables text input", "Push-to-talk", "RECORD_AUDIO", "Gemma-4-E2B", "download, load, eject", "gemma-4-E2B-it.litertlm", "2588147712", "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c", "persona import/export", "stackchan.persona-pack.v1", "app_text_turn", "audio_stream_start", "response_end", "settings, diagnostics, persona, and handoff status", "settings_set", "settings_result", "claim_brain", "release_brain", "owner_status", "Removing a stored trusted companion endpoint", "Forget removes", "ANDROID_DIAGNOSTICS_EXPORT.json", "stackchan.android.diagnostics-export.v1", "saved robot/trusted endpoint state", "redacts the last text turn")

Test-TextEvidence `
  -Id "robot-hello-write-gate" `
  -Name "Robot hello gates protected companion writes" `
  -RelativePaths @("companion/core/src/commonMain/kotlin/dev/stackchan/companion/core/EndpointServer.kt") `
  -Patterns @("robotHelloReceived", "robot_hello_required", "audio, settings writes, or app text turns", "Stack-chan has not completed the bridge hello yet.")

Test-TextEvidence `
  -Id "protected-control-outbound" `
  -Name "Protected control outbound path" `
  -RelativePaths @("companion/core/src/commonMain/kotlin/dev/stackchan/companion/core/EndpointServer.kt") `
  -Patterns @("submitProtectedControl", "ProtectedControlSubmitResult", "SettingsSet", "ClaimBrain", "ReleaseBrain", "Protected control message", "robotHelloReceived")

Test-TextEvidence `
  -Id "android-pairing-walkthrough" `
  -Name "Android guided robot pairing walkthrough" `
  -RelativePaths @("companion/app-android/src/main/kotlin/dev/stackchan/companion/android/MainActivity.kt") `
  -Patterns @("pairingShortCode", "pairingFingerprint", "androidPairingQrPayload", "stackchan", "pair", "pairingInstruction", "nextActionTitle", "nextActionDetail", "removalGuidance", "SavedRobot", "rememberRobot", "onForgetRobot")

Test-TextEvidence `
  -Id "shared-pairing-qr-ticket" `
  -Name "Shared setup UI renders pairing QR ticket" `
  -RelativePaths @("companion/ui/src/commonMain/kotlin/dev/stackchan/companion/ui/CompanionConsole.kt") `
  -Patterns @("pairingQrPayload", "PairingQrTicket", "rememberQrCodePainter", "QrErrorCorrectionLevel.Medium", "SCAN OR ENTER")

Test-TextEvidence `
  -Id "android-pairing-code-hello" `
  -Name "Android pairing code helper matches setup ticket" `
  -RelativePaths @("companion/app-android/src/main/kotlin/dev/stackchan/companion/android/AndroidLanAddresses.kt") `
  -Patterns @("androidPairingShortCode", "androidPairingFingerprint", "endpointHello.endpointId", "endpointHello.appVersion")

Test-TextEvidence `
  -Id "android-pairing-code-service" `
  -Name "Android endpoint hello carries displayed pairing code" `
  -RelativePaths @("companion/app-android/src/main/kotlin/dev/stackchan/companion/android/CompanionBridgeService.kt") `
  -Patterns @("endpointBase", "pairingCode = androidPairingShortCode", "EndpointServerConfig")

Test-TextEvidence `
  -Id "firmware-pairing-code-config" `
  -Name "Firmware endpoint trust pairing config" `
  -RelativePaths @("src/io/BridgeEndpointControl.hpp") `
  -Patterns @("BridgeEndpointControlConfig", "requiredPairingCode", "setRequiredPairingCode", "clearRequiredPairingCode", "pairingRejects")

Test-TextEvidence `
  -Id "firmware-pairing-code-gate" `
  -Name "Firmware endpoint trust pairing code gate" `
  -RelativePaths @("src/io/BridgeEndpointControl.cpp") `
  -Patterns @("pairing_code", "pairing_code_mismatch", "normalizePairingCode", "pairingCodeMatches")

Test-TextEvidence `
  -Id "firmware-pairing-code-boot" `
  -Name "Firmware boot wires optional pairing code gate" `
  -RelativePaths @("src/main.cpp") `
  -Patterns @("STACKCHAN_PAIRING_SHORT_CODE", "BridgeEndpointControlConfig", "endpointControlConfig.requiredPairingCode", "handlePairingControl", "bridge_endpoint_pairing_required")

Test-TextEvidence `
  -Id "firmware-pairing-code-test" `
  -Name "Firmware pairing code native regression test" `
  -RelativePaths @("test/test_native_logic/test_main.cpp") `
  -Patterns @("test_bridge_endpoint_control_requires_pairing_code_when_configured", "test_sensor_adapter_parses_pairing_code_commands", "test_bridge_endpoint_control_allows_runtime_pairing_code_changes", "pairing_code_mismatch", "7K9PQ2")

Test-TextEvidence `
  -Id "firmware-pairing-code-serial-command" `
  -Name "Firmware serial pairing code command" `
  -RelativePaths @("src/io/SensorAdapter.cpp") `
  -Patterns @("fillPairingControl", "pairing code <ABC123>", "pairing clear", "hasPairingControl")

Test-TextEvidence `
  -Id "android-saved-robot-store" `
  -Name "Android saved robot add/remove store" `
  -RelativePaths @("companion/app-android/src/main/kotlin/dev/stackchan/companion/android/AndroidBridgeStores.kt") `
  -Patterns @("SavedRobot", "loadSavedRobots", "rememberRobot", "forgetRobot", "saved_robots")

Test-TextEvidence `
  -Id "android-saved-robot-diagnostics" `
  -Name "Android saved robot diagnostics evidence" `
  -RelativePaths @("companion/app-android/src/main/kotlin/dev/stackchan/companion/android/AndroidDiagnosticsExport.kt") `
  -Patterns @("SavedRobot", "saved_robots", "saved_on_phone")

Test-TextEvidence `
  -Id "shared-saved-robot-ui" `
  -Name "Shared Nodes UI exposes saved robot removal" `
  -RelativePaths @("companion/ui/src/commonMain/kotlin/dev/stackchan/companion/ui/CompanionConsole.kt") `
  -Patterns @("savedRobotCount", "onForgetRobot", "Saved robots", "Forget", "nextActionTitle", "removalGuidance", "wifiStatus", "Wi-Fi bootstrap", "onOpenWifiSettings")

Test-TextEvidence `
  -Id "android-wifi-bootstrap-setup" `
  -Name "Android Wi-Fi bootstrap setup step" `
  -RelativePaths @("companion/app-android/src/main/kotlin/dev/stackchan/companion/android/MainActivity.kt") `
  -Patterns @("isWifiConnected", "ConnectivityManager", "NetworkCapabilities.TRANSPORT_WIFI", "Settings.ACTION_WIFI_SETTINGS", "wifiConnected", "Open Wi-Fi settings", "Join Wi-Fi")

Test-TextEvidence `
  -Id "shared-g3-control-surfaces" `
  -Name "Shared settings diagnostics persona handoff surfaces" `
  -RelativePaths @("companion/ui/src/commonMain/kotlin/dev/stackchan/companion/ui/CompanionConsole.kt") `
  -Patterns @("SettingsSurfaceUiState", "DiagnosticsSurfaceUiState", "BrainHandoffUiState", "SettingsSurfacePanel", "DiagnosticsSurfacePanel", "HandoffSurfacePanel", "Select persona", "onSelectPersona", "onSaveDisplaySettings", "onPrivacySettings", "Claim phone")

Test-TextEvidence `
  -Id "shared-model-persona-surfaces" `
  -Name "Shared model asset and persona library surfaces" `
  -RelativePaths @("companion/ui/src/commonMain/kotlin/dev/stackchan/companion/ui/CompanionConsole.kt") `
  -Patterns @("ModelAssetUiState", "Gemma-4-E2B", "LiteRT-LM", "Download model", "Load", "Eject", "Model settings", "PersonaLibraryUiState", "Import persona", "Export active", "stackchan.persona-pack.v1")

Test-TextEvidence `
  -Id "android-model-persona-state" `
  -Name "Android model asset and persona library state" `
  -RelativePaths @("companion/app-android/src/main/kotlin/dev/stackchan/companion/android/MainActivity.kt", "companion/app-android/src/main/kotlin/dev/stackchan/companion/android/AndroidBridgeStores.kt", "provenance/companion/app-android/src/main/kotlin/dev/stackchan/companion/android/MainActivity.kt") `
  -Patterns @("androidModelAssetSurface", "startGemmaModelDownload", "loadGemmaModel", "ejectGemmaModel", "Gemma-4-E2B", "LiteRT-LM", "2.58 GB", "androidPersonaLibrarySurface", "importPersonaZip", "exportPersonaZip", "stackchan.persona-pack.v1")

Test-TextEvidence `
  -Id "desktop-model-persona-state" `
  -Name "Desktop model asset and persona library state" `
  -RelativePaths @("companion/app-desktop/src/main/kotlin/dev/stackchan/companion/desktop/DesktopCompanionRuntime.kt") `
  -Patterns @("downloadGemmaModel", "loadGemmaModel", "ejectGemmaModel", "Gemma-4-E2B", "LiteRT-LM", "importPersonaZip", "exportPersonaZip", "stackchan.persona-pack.v1")

Test-TextEvidence `
  -Id "gemma-e2b-artifact-gate" `
  -Name "Gemma-4-E2B LiteRT-LM artifact size gate" `
  -RelativePaths @("companion/app-android/src/main/kotlin/dev/stackchan/companion/android/AndroidBridgeStores.kt", "companion/app-desktop/src/main/kotlin/dev/stackchan/companion/desktop/DesktopCompanionRuntime.kt") `
  -Patterns @("gemma-4-E2B-it.litertlm", "GEMMA_LITERTLM_BYTES", "2_588_147_712L", "GEMMA_LITERTLM_SHA256", "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c")

Test-TextEvidence `
  -Id "desktop-persona-file-picker" `
  -Name "Desktop persona import export file picker" `
  -RelativePaths @("companion/app-desktop/src/main/kotlin/dev/stackchan/companion/desktop/Main.kt") `
  -Patterns @("onImportPersona", "onExportPersona", "choosePersonaImportZip", "choosePersonaExportZip")

Test-TextEvidence `
  -Id "shared-honest-live-telemetry" `
  -Name "Shared UI labels non-live telemetry honestly" `
  -RelativePaths @("companion/ui/src/commonMain/kotlin/dev/stackchan/companion/ui/CompanionConsole.kt") `
  -Patterns @("heartbeatStatus", "Heartbeat: not measured", "No robot telemetry", "Audio status //", "Signal preview; not live robot audio.", "Manual servos and triggers (locked)")

Test-TextEvidence `
  -Id "android-honest-live-telemetry" `
  -Name "Android UI avoids fake heartbeat and audio meters" `
  -RelativePaths @("companion/app-android/src/main/kotlin/dev/stackchan/companion/android/MainActivity.kt", "provenance/companion/app-android/src/main/kotlin/dev/stackchan/companion/android/MainActivity.kt") `
  -Patterns @("androidHeartbeatStatus", "Heartbeat: received", "Heartbeat: awaiting hello", "Bridge connected; no live meter")

Test-TextEvidence `
  -Id "android-g3-control-state" `
  -Name "Android settings diagnostics persona handoff state" `
  -RelativePaths @("companion/app-android/src/main/kotlin/dev/stackchan/companion/android/MainActivity.kt", "provenance/companion/app-android/src/main/kotlin/dev/stackchan/companion/android/MainActivity.kt") `
  -Patterns @("androidSettingsSurface", "androidDiagnosticsSurface", "androidHandoffSurface", "SettingsRepository", "applySettingsPatch", "submitSettingsPatchToRobot", "onSelectPersona", "onSaveDisplaySettings", "onPrivacySettings", "onClaimBrain", "onReleaseBrain", "settings_set", "owner_status")

Test-TextEvidence `
  -Id "desktop-g3-control-state" `
  -Name "Desktop settings diagnostics persona handoff state" `
  -RelativePaths @("companion/app-desktop/src/main/kotlin/dev/stackchan/companion/desktop/DesktopRuntimeUiState.kt", "provenance/companion/app-desktop/src/main/kotlin/dev/stackchan/companion/desktop/DesktopRuntimeUiState.kt") `
  -Patterns @("toSettingsSurface", "toDiagnosticsSurface", "toHandoffSurface", "SettingsSnapshot", "settings_set", "owner round-trip")

Test-TextEvidence `
  -Id "desktop-g3-settings-actions" `
  -Name "Desktop safe settings actions" `
  -RelativePaths @("companion/app-desktop/src/main/kotlin/dev/stackchan/companion/desktop/DesktopCompanionRuntime.kt") `
  -Patterns @("selectNextPersona", "toggleDisplayReducedMotion", "toggleDiagnosticsLogExport", "SettingsSet", "claimBrain", "releaseBrain", "submitProtectedControl")

Test-TextEvidence `
  -Id "desktop-python-runtime-preflight" `
  -Name "Desktop Python brain runtime preflight" `
  -RelativePaths @("companion/app-desktop/src/main/kotlin/dev/stackchan/companion/desktop/DesktopBrainSupervisor.kt") `
  -Patterns @("DesktopPythonRuntimeStatus", "inspectDesktopPythonRuntime", "Python 3.10+", "STACKCHAN_BRAIN_PYTHON", "scriptAvailable", "searchedCommands")

Test-TextEvidence `
  -Id "desktop-python-runtime-evidence" `
  -Name "Desktop Python runtime diagnostics evidence" `
  -RelativePaths @("companion/app-desktop/src/main/kotlin/dev/stackchan/companion/desktop/DesktopDiagnosticsExport.kt", "companion/app-desktop/src/main/kotlin/dev/stackchan/companion/desktop/BrainSupervisorRehearsal.kt") `
  -Patterns @("python_runtime", "available", "version", "script_available", "searched_commands")

Test-TextEvidence `
  -Id "android-push-to-talk-permission" `
  -Name "Android push-to-talk microphone permission" `
  -RelativePaths @("companion/app-android/src/main/AndroidManifest.xml", "provenance/companion/app-android/src/main/AndroidManifest.xml") `
  -Patterns @("android.permission.RECORD_AUDIO")

Test-TextEvidence `
  -Id "android-push-to-talk-stt-controller" `
  -Name "Android push-to-talk speech recognizer controller" `
  -RelativePaths @("companion/app-android/src/main/kotlin/dev/stackchan/companion/android/AndroidSpeechTurnController.kt", "provenance/companion/app-android/src/main/kotlin/dev/stackchan/companion/android/AndroidSpeechTurnController.kt") `
  -Patterns @("SpeechRecognizer", "RecognizerIntent.ACTION_RECOGNIZE_SPEECH", "onFinalTranscript", "onPartialTranscript")

Test-TextEvidence `
  -Id "android-push-to-talk-submit" `
  -Name "Android push-to-talk transcript submission" `
  -RelativePaths @("companion/app-android/src/main/kotlin/dev/stackchan/companion/android/MainActivity.kt", "provenance/companion/app-android/src/main/kotlin/dev/stackchan/companion/android/MainActivity.kt") `
  -Patterns @("speechPermissionLauncher", "Manifest.permission.RECORD_AUDIO", "CompanionBridgeService.submitTextTurn", "Speech transcript")

Test-TextEvidence `
  -Id "shared-push-to-talk-ui" `
  -Name "Shared Talk UI exposes push-to-talk state" `
  -RelativePaths @("companion/ui/src/commonMain/kotlin/dev/stackchan/companion/ui/CompanionConsole.kt", "provenance/companion/ui/src/commonMain/kotlin/dev/stackchan/companion/ui/CompanionConsole.kt") `
  -Patterns @("pushToTalkEnabled", "pushToTalkLabel", "pushToTalkStatus", "onPushToTalk")

Test-TextEvidence `
  -Id "android-diagnostics-export" `
  -Name "Android diagnostics export implementation" `
  -RelativePaths @("companion/app-android/src/main/kotlin/dev/stackchan/companion/android/AndroidDiagnosticsExport.kt") `
  -Patterns @("stackchan.android.diagnostics-export.v1", "ANDROID_DIAGNOSTICS_EXPORT.json", "last_text_turn_present", "robot_socket_connected", "raw_audio_retention", "last text turn redacted to presence only")

Test-TextEvidence `
  -Id "android-play-release-prep" `
  -Name "Android Play release preparation" `
  -RelativePaths @("docs/ANDROID_PLAY_RELEASE.md", "provenance/docs/ANDROID_PLAY_RELEASE.md") `
  -Patterns @("Android Play Release Checklist", "app-android-release.aab", "Play App Signing", "STACKCHAN_ANDROID_KEYSTORE", "docs/store-assets/play/icon-512.png", "feature-graphic-1024x500.png", "fastlane/metadata/android/en-US/", "physical robot validation", "RECORD_AUDIO", "Play Console internal testing")

Test-TextEvidence `
  -Id "android-play-readiness-check" `
  -Name "Android Play source readiness check" `
  -RelativePaths @("tools/check_android_play_release_readiness.ps1", "provenance/tools/check_android_play_release_readiness.ps1") `
  -Patterns @("stackchan.android-play-release-readiness.v1", "Play high-resolution icon", "Gradle Play upload signing inputs", "CI builds Android release bundle", "Release evidence covers AAB signing", "play-store-evidence-checker")

Test-TextEvidence `
  -Id "android-play-store-evidence-check" `
  -Name "Android Play Store post-upload evidence check" `
  -RelativePaths @("tools/check_android_play_store_evidence.ps1", "provenance/tools/check_android_play_store_evidence.ps1") `
  -Patterns @("stackchan.android-play-store-evidence.v1", "play-internal-testing-ready", "releaseAabSha256", "playSigningEnabled", "internalTestingInstallStatus", "screenshots")

Test-TextEvidence `
  -Id "android-screen-off-soak-helper" `
  -Name "Android screen-off soak helper" `
  -RelativePaths @("bridge/android_companion_soak.py", "tools/run_android_companion_soak.ps1") `
  -Patterns @("stackchan.android-companion-soak.v1", "DEFAULT_DURATION_SECONDS = 600.0", "DEFAULT_INTERVAL_SECONDS = 30.0", "android_companion_soak.json", "ANDROID_COMPANION_SOAK.md", "--duration-seconds", "--interval-seconds", "--max-failures")

Test-TextEvidence `
  -Id "ci-companion-tests" `
  -Name "Companion CI pre-arrival checks" `
  -RelativePaths @(".github/workflows/firmware.yml", "provenance/firmware.yml") `
  -Patterns @("companion-tests", "companion-platform-builds", "companion-release-evidence", "export_companion_release_evidence.ps1", "java-version: `"21`"", "android-actions/setup-android", "platforms;android-36", "build-tools;36.0.0", "./gradlew check :app-desktop:c0Spike", ":app-android:bundleRelease", "check_android_play_release_readiness.ps1")

Test-TextEvidence `
  -Id "companion-release-signing-evidence" `
  -Name "Companion release APK signing evidence" `
  -RelativePaths @("tools/export_companion_release_evidence.ps1") `
  -Patterns @("ApkSignerPath", "apksigner", "androidSigning", "android-release-apk-signature", "APK Signature Scheme v2", "androidBundleSigning", "android-release-aab-signature", "jarsigner")

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
