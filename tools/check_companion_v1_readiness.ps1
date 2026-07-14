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
  [ordered]@{
    name = "physical-robot-hardware-validation"
    evidence = "output/hardware-evidence/<candidate>"
    detail = "Complete the physical packet, then run tools\verify_hardware_evidence.cmd -EvidenceRoot <packet> and tools\export_rollout_status.cmd with the same exact release candidate."
  },
  [ordered]@{
    name = "android-apk-install-on-target-phone"
    evidence = "output/android-apk-install/<candidate>/android_apk_install.json"
    detail = "Connect the target phone and run tools\install_android_companion_apk.cmd -ApkPath <release-apk> -SourceCommit <40-character-sha>."
  },
  [ordered]@{
    name = "android-dashboard-connected-state-media"
    evidence = "output/hardware-evidence/<candidate>/media/phone-live-dashboard*"
    detail = "Capture the exact installed build connected to the robot, register media id phone-live-dashboard, and pass the strict Android dashboard evidence gate in tools\verify_hardware_evidence.cmd."
  },
  [ordered]@{
    name = "android-push-to-talk-stt-on-target-phone"
    evidence = "output/android-speech/<candidate>"
    detail = "Capture phone diagnostics/logcat and robot response frames, review ANDROID_SPEECH_REVIEW.md, then run tools\check_android_speech_evidence.cmd -SourceCommit <40-character-sha> -RequireReady -Json."
  },
  [ordered]@{
    name = "android-settings-handoff-on-target-robot"
    evidence = "output/android-controls/<candidate>"
    detail = "Capture settings_set, claim_brain, release_brain, owner_status, and pre-hello rejection, then run tools\check_android_controls_evidence.cmd -SourceCommit <40-character-sha> -RequireReady -Json."
  },
  [ordered]@{
    name = "android-qr-short-code-pairing-on-target-robot"
    evidence = "output/android-pairing/<candidate>"
    detail = "Capture QR/manual-code success, wrong-code rejection, trusted endpoint state, and setup media, then run tools\check_android_pairing_evidence.cmd -SourceCommit <40-character-sha> -RequireReady -Json."
  },
  [ordered]@{
    name = "android-wifi-provisioning-on-target-robot"
    evidence = "output/android-wifi/<candidate>"
    detail = "Capture persisted provisioning, power-cycle reload, clear behavior, and password redaction, then run tools\check_android_wifi_evidence.cmd -SourceCommit <40-character-sha> -RequireReady -Json."
  },
  [ordered]@{
    name = "screen-off-bridge-soak"
    evidence = "output/android-companion-soak/<candidate>"
    detail = "Run the target-phone screen-off soak, review its packet, then run tools\check_android_screen_off_soak_evidence.cmd -SourceCommit <40-character-sha> -RequireReady -Json."
  },
  [ordered]@{
    name = "google-play-store-screenshots"
    evidence = "output/android-play-store/<candidate>/screenshots"
    detail = "Capture the four required final-build screenshot ids on the target phone and validate them with tools\check_android_play_store_evidence.cmd -EvidenceRoot <packet> -Json."
  },
  [ordered]@{
    name = "google-play-internal-testing-upload"
    evidence = "output/android-play-store/<candidate>/ANDROID_PLAY_STORE_EVIDENCE.json"
    detail = "Provision upload signing, pass the read-only Companion Signing Readiness workflow, upload the exact AAB, install from the internal track, record the hosted privacy URL/release/tester/timestamp fields, and pass tools\check_android_play_store_evidence.cmd."
  },
  [ordered]@{
    name = "gemma4-e2b-real-device-download-and-inference-validation"
    evidence = "output/android-gemma/<candidate>"
    detail = "On the target phone complete verified download, load/eject/reload, non-dry-run benchmark, one LiteRT turn, and robot audio/TTS review; then run tools\check_android_gemma_evidence.cmd -SourceCommit <40-character-sha> -RequireReady -Json."
  },
  [ordered]@{
    name = "desktop-target-installs-on-operator-workstations"
    evidence = "output/desktop-target-install/<windows|linux|macos>/<platform>-target-install.json"
    detail = "Install the exact tagged MSI, DEB, and DMG with tools\install_desktop_companion_package.ps1 on native operator workstations, then pass tools\check_desktop_target_install_evidence.ps1 -RequireOperatorTarget for each package hash."
  },
  [ordered]@{
    name = "desktop-production-signing-credentials"
    evidence = "GitHub Actions secrets for Windows Authenticode and macOS Developer ID/notarization"
    detail = "Provision the two STACKCHAN_WINDOWS_* and six STACKCHAN_MACOS_* release secrets, then run the Companion Signing Readiness workflow. The tag workflow fails closed until it can verify timestamped Authenticode, Developer ID, Gatekeeper, and stapled notarization evidence."
  },
  [ordered]@{
    name = "c8-tagged-release-distribution"
    evidence = "GitHub prerelease assets plus COMPANION_RELEASE_EVIDENCE.json and output/companion-v1-evidence/<candidate>"
    detail = "Create the exact upload-signed prerelease tag, run tools\verify_published_release.cmd -Version <tag>, assemble Android/Desktop/rollout evidence, and pass tools\check_companion_v1_evidence_bundle.cmd -EvidenceRoot <packet> -RequireReady -Json."
  }
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

function Test-AggregateTextEvidence {
  param(
    [string]$Id,
    [string]$Name,
    [string[]]$RelativePaths,
    [string[]]$Patterns
  )

  $missingFiles = @()
  $combinedText = ""
  foreach ($relativePath in $RelativePaths) {
    $path = Join-RootPath $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      $missingFiles += $relativePath
      continue
    }
    $combinedText += [Environment]::NewLine + (Get-Content -LiteralPath $path -Raw)
  }

  if ($missingFiles.Count -gt 0) {
    Add-Check $Id $Name "fail" ($RelativePaths -join ", ") ("Missing files: " + ($missingFiles -join ", "))
    return
  }

  $missingPatterns = @()
  foreach ($pattern in $Patterns) {
    if ($combinedText -notmatch [regex]::Escape($pattern)) {
      $missingPatterns += $pattern
    }
  }

  if ($missingPatterns.Count -gt 0) {
    Add-Check $Id $Name "fail" ($RelativePaths -join ", ") ("Missing required text: " + ($missingPatterns -join ", "))
  } else {
    Add-Check $Id $Name "pass" ($RelativePaths -join ", ") "Required implementation and validation evidence is present."
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
    Add-Check ("pending-" + $gate.name) $gate.name "pending" $gate.evidence $gate.detail
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
  -Patterns @("PC Brain Mode", "Mobile Brain Mode", "active brain owner", "settings_get", "settings_set", "forget_endpoint", "LiteRT-LM", "Gemma-4-E2B", "download button", "load/eject controls", "staging and unstaging the local model", "LiteRT runtime adapter", "gemma-4-E2B-it.litertlm", "2588147712", "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c", "Persona library", "import a validated persona pack", "safety-locked", "Add your Stack-chan", "Wi-Fi bootstrap step", "native Wi-Fi settings", "pairing code", "phone fingerprint", "stackchan://pair", "endpoint_hello.pairing_code", "STACKCHAN_PAIRING_SHORT_CODE", "pairing code <ABC123>", "pairing_code_mismatch", "wifi set ssid ""<name>"" pass ""<password>"" url ""ws://host:port/bridge""", "wifi clear", "command template", "password-redacted flag", "saved robot", "diagnostics, persona", "handoff status panels", "claim_brain", "release_brain", "settings_result", "owner_status", "hello-connected robot session", "remove path", "Talk surface", "app_text_turn", "robot completes the", "raw WebSocket connection without robot", "stackchan.android.diagnostics-export.v1", "ANDROID_DIAGNOSTICS_EXPORT.json")

Test-TextEvidence `
  -Id "android-test-plan" `
  -Name "Android physical test plan" `
  -RelativePaths @("docs/ANDROID_COMPANION_TEST_PLAN.md") `
  -Patterns @("Android Companion Physical Test Plan", "API 35 AOSP automated-test emulator smoke", "test_android_emulator_launch.ps1", "substitutesForPhysicalEvidence=false", "lab-signed release APK", "app-android-release.apk", "check_android_toolchain.cmd", "RUN_ANDROID_APK_INSTALL.cmd", "RUN_ANDROID_COMPANION_PROBE.cmd", "RUN_ANDROID_SCREEN_OFF_SOAK.cmd", "android/screen-off-soak/", "RUN_ANDROID_LOGCAT_CAPTURE.cmd", "Android dashboard switches from waiting to connected", "Add your Stack-chan", "Wi-Fi bootstrap", "Open Wi-Fi settings", "Join Wi-Fi", "Start phone bridge", "Connect Stack-chan", "Confirm robot ready", "current next step", "Pair on Stack-chan", "Ready to test", "Robot Wi-Fi setup", "wifi set ssid ""<network-name>"" pass ""<network-password>"" url ""ws://<phone-lan-ip>:8765/bridge""", "tools\provision_stackchan_wifi.cmd", "wifi clear", "password redaction", "check_android_wifi_evidence.cmd", "android-wifi-ready", "ANDROID_WIFI_REVIEW.md", "robot_wifi_serial.log", "bridge_wifi_store_loads", "bridge_wifi_store_has_record=1", "pairing code", "phone fingerprint", "stackchan://pair", "endpoint_hello.pairing_code", "STACKCHAN_PAIRING_SHORT_CODE", "pairing code <ABC123>", "pairing clear", "pairing_code_mismatch", "check_android_pairing_evidence.cmd", "android-pairing-ready", "ANDROID_PAIRING_REVIEW.md", "robot_pairing_serial.log", "android_pairing_setup.jpg", "bridge_url_applied", "saved robots", "waiting/setup action", "trusted companion nodes are stored", "raw WebSocket connection without the robot", "Talk screen enables text input", "Push-to-talk", "RECORD_AUDIO", "check_android_speech_evidence.cmd", "android-speech-ready", "ANDROID_SPEECH_REVIEW.md", "robot_speech_serial.log", "Gemma-4-E2B", "download, load, eject", "staging the verified asset", "real inference is gated on LiteRT runtime validation", "gemma-4-E2B-it.litertlm", "2588147712", "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c", "check_android_gemma_evidence.cmd", "android-gemma-real-device-ready", "mobile_brain_litert_turn", "mobile_brain_litert_error", "ANDROID_GEMMA_REVIEW.md", "persona import/export", "stackchan.persona-pack.v1", "app_text_turn", "audio_stream_start", "response_end", "settings, diagnostics, persona, and handoff status", "settings_set", "settings_result", "claim_brain", "release_brain", "owner_status", "check_android_controls_evidence.cmd", "android-controls-ready", "ANDROID_CONTROLS_REVIEW.md", "robot_controls_serial.log", "robot_hello_required", "Removing a stored trusted companion endpoint", "Forget removes", "ANDROID_DIAGNOSTICS_EXPORT.json", "stackchan.android.diagnostics-export.v1", "saved robot/trusted endpoint state", "redacts the last text turn")

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
  -Id "firmware-pairing-ticket-command" `
  -Name "Firmware Android pairing ticket setup command" `
  -RelativePaths @("src/io/SensorAdapter.cpp") `
  -Patterns @("fillPairingTicketControlRaw", "stackchan://pair?", "pair ticket <stackchan://pair?...>", "queryValue", "parsePairingTicketBridgeUrl", "hasPairingTicket")

Test-TextEvidence `
  -Id "firmware-pairing-ticket-handler" `
  -Name "Firmware Android pairing ticket runtime handler" `
  -RelativePaths @("src/main.cpp") `
  -Patterns @("handlePairingTicketControl", "setRequiredPairingCode", "bridge_url_applied", "bridge_ssid_available", "runtimeBridgeWiFiRecord", "restartBridgeWiFi")

Test-TextEvidence `
  -Id "firmware-pairing-ticket-test" `
  -Name "Firmware Android pairing ticket native regression test" `
  -RelativePaths @("test/test_native_logic/test_main.cpp") `
  -Patterns @("test_sensor_adapter_parses_pairing_ticket_payload", "stackchan://pair?bridge=ws%3A%2F%2F192.168.1.42%3A8765%2Fbridge", "fingerprint=sha256%3Aabc123", "wss%3A%2F%2F10.0.0.5")

Test-TextEvidence `
  -Id "firmware-wifi-runtime-command" `
  -Name "Firmware serial Wi-Fi bridge provisioning command" `
  -RelativePaths @("src/io/SensorAdapter.cpp", "src/io/SensorAdapter.hpp") `
  -Patterns @("BenchWiFiProvisioningControl", "fillWiFiProvisioningControlRaw", "tokenizeQuoted", "parseBridgeUrl", 'wifi set ssid \"<name>\" pass \"<password>\"', "wifi clear", "saved to robot flash without echoing password", "hasWiFiProvisioning")

Test-TextEvidence `
  -Id "firmware-wifi-runtime-handler" `
  -Name "Firmware runtime Wi-Fi bridge provisioning handler" `
  -RelativePaths @("src/main.cpp") `
  -Patterns @("handleWiFiProvisioningControl", "restartBridgeWiFi", "BridgeWiFiProvisioningConfig", "gRuntimeWiFiSsid", "runtimeBridgeWiFiRecord", "gBridgeWiFiStore.save", "gBridgeWiFiStore.clear", "storedBridgeWiFiConfigOrDefault", "persisted", "ssid_set", "network_state")

Test-TextEvidence `
  -Id "firmware-wifi-persistent-store" `
  -Name "Firmware persistent Wi-Fi bridge provisioning store" `
  -RelativePaths @("src/io/BridgeWiFiProvisioningStore.cpp") `
  -Patterns @("stackchan.bridge-wifi.v1", "BridgeWiFiProvisioningStore", "BridgeWiFiProvisioningMemoryStore", "BridgeWiFiProvisioningPreferencesStore", "Preferences", "password", "bridge_host", "bridge_port", "hasRecord")

Test-TextEvidence `
  -Id "firmware-wifi-runtime-test" `
  -Name "Firmware Wi-Fi provisioning native regression test" `
  -RelativePaths @("test/test_native_logic/test_main.cpp") `
  -Patterns @("test_sensor_adapter_parses_wifi_provisioning_commands", "test_bridge_wifi_provisioning_store_saves_and_loads_credentials_without_loggable_status", "test_bridge_wifi_provisioning_store_clear_removes_persisted_credentials", "test_bridge_wifi_provisioning_store_rejects_malformed_or_incomplete_payloads", "CaseSensitive123", "Rob Phone", "quoted psk", "ws://10.0.0.5:8765/bridge", "wifi clear", "8765x")

Test-TextEvidence `
  -Id "firmware-wifi-runtime-flash-target" `
  -Name "Firmware Wi-Fi runtime flash target" `
  -RelativePaths @("platformio.ini") `
  -Patterns @("[env:stackchan_wifi]", "extends = env:stackchan", "STACKCHAN_ENABLE_WIFI_BRIDGE=1", "Do not bake Wi-Fi credentials into release or lab builds.", "wifi set ssid ""<name>"" pass ""<password>"" url ""ws://host:port/bridge""")

Test-TextEvidence `
  -Id "firmware-wifi-flash-helper" `
  -Name "Firmware Wi-Fi flash helper exposes runtime target" `
  -RelativePaths @("tools/flash_device.ps1") `
  -Patterns @("stackchan_wifi", "platformio", "--target", "upload")

Test-TextEvidence `
  -Id "firmware-wifi-runtime-bringup-doc" `
  -Name "Firmware Wi-Fi runtime bring-up guidance" `
  -RelativePaths @("docs/DEVICE_BRINGUP.md") `
  -Patterns @("flash_device.cmd -Environment stackchan_wifi", "compiling secrets", "tools\provision_stackchan_wifi.cmd", "wifi set ssid ""<network-name>"" pass ""<network-password>"" url ""ws://<phone-lan-ip>:8765/bridge""", "persists the runtime bridge target in robot flash until", "STACKCHAN_WIFI_SSID", "STACKCHAN_WIFI_PASSWORD", "build flags")

Test-TextEvidence `
  -Id "firmware-wifi-serial-provision-helper" `
  -Name "Firmware Wi-Fi serial provisioning helper" `
  -RelativePaths @("tools/provision_stackchan_wifi.ps1", "tools/provision_stackchan_wifi.cmd") `
  -Patterns @("ConvertTo-SerialQuotedToken", "Read-Host -AsSecureString", "Redact-Line", "wifi set ssid", "pass", "url", "password is too long", "Did not see a [wifi] result line")

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
  -Patterns @("savedRobotCount", "onForgetRobot", "Saved robots", "Forget", "nextActionTitle", "removalGuidance", "wifiStatus", "wifiProvisioningCommand", "Wi-Fi bootstrap", "onOpenWifiSettings")

Test-TextEvidence `
  -Id "android-wifi-bootstrap-setup" `
  -Name "Android Wi-Fi bootstrap setup step" `
  -RelativePaths @("companion/app-android/src/main/kotlin/dev/stackchan/companion/android/MainActivity.kt") `
  -Patterns @("isWifiConnected", "ConnectivityManager", "NetworkCapabilities.TRANSPORT_WIFI", "Settings.ACTION_WIFI_SETTINGS", "wifiConnected", "Open Wi-Fi settings", "Join Wi-Fi", "androidWifiProvisioningCommand", "<network-password>")

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
  -Patterns @("androidModelAssetSurface", "startGemmaModelDownload", "loadGemmaModel", "ejectGemmaModel", "checksumVerified", "Gemma-4-E2B", "LiteRT-LM", "2.58 GB", "SHA-256 verified asset staged for Mobile Brain", "runtime validation", "androidPersonaLibrarySurface", "importPersonaZip", "exportPersonaZip", "stackchan.persona-pack.v1")

Test-TextEvidence `
  -Id "desktop-model-persona-state" `
  -Name "Desktop model asset and persona library state" `
  -RelativePaths @("companion/app-desktop/src/main/kotlin/dev/stackchan/companion/desktop/DesktopCompanionRuntime.kt") `
  -Patterns @("downloadGemmaModel", "loadGemmaModel", "ejectGemmaModel", "gemmaModelChecksum", "checksumVerified", "Gemma-4-E2B", "LiteRT-LM", "importPersonaZip", "exportPersonaZip", "stackchan.persona-pack.v1")

Test-TextEvidence `
  -Id "desktop-model-runtime-honesty" `
  -Name "Desktop model asset runtime honesty" `
  -RelativePaths @("companion/app-desktop/src/main/kotlin/dev/stackchan/companion/desktop/DesktopRuntimeUiState.kt") `
  -Patterns @("SHA-256 verified asset staged for Mobile Brain", "runtime validation", "real inference remains gated")

Test-TextEvidence `
  -Id "gemma-e2b-artifact-gate" `
  -Name "Gemma-4-E2B LiteRT-LM artifact size and checksum gate" `
  -RelativePaths @("companion/app-android/src/main/kotlin/dev/stackchan/companion/android/AndroidBridgeStores.kt", "companion/app-desktop/src/main/kotlin/dev/stackchan/companion/desktop/DesktopCompanionRuntime.kt") `
  -Patterns @("gemma-4-E2B-it.litertlm", "ANDROID_GEMMA_LITERTLM_BYTES", "2_588_147_712L", "ANDROID_GEMMA_LITERTLM_SHA256", "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c", "MessageDigest.getInstance(`"SHA-256`")", "checksum mismatch")

Test-TextEvidence `
  -Id "brain-turn-engine-boundary" `
  -Name "Bridge brain turn engine boundary" `
  -RelativePaths @("companion/core/src/commonMain/kotlin/dev/stackchan/companion/core/BrainTurnEngine.kt") `
  -Patterns @("BrainTurnEngine", "BrainTurnRequest", "BrainTurnResponse", "DeterministicBrainTurnEngine")

Test-TextEvidence `
  -Id "endpoint-server-brain-turn-engine-route" `
  -Name "Endpoint server routes turns through brain engine" `
  -RelativePaths @("companion/core/src/commonMain/kotlin/dev/stackchan/companion/core/EndpointServer.kt") `
  -Patterns @("brainTurnEngine", "BrainTurnRequest", "BrainTurnSource.APP_TEXT", "BrainTurnSource.ROBOT_AUDIO", "brain_turn_failed")

Test-TextEvidence `
  -Id "android-staged-gemma-brain-engine" `
  -Name "Android LiteRT Gemma brain engine honesty" `
  -RelativePaths @("companion/app-android/src/main/kotlin/dev/stackchan/companion/android/AndroidMobileBrainTurnEngine.kt") `
  -Patterns @("androidBrainTurnEngine", "LiteRtGemmaBrainTurnEngine", "EngineConfig", "Backend.GPU()", "Backend.CPU()", "ConversationConfig", "mobile_brain_litert_turn", "mobile_brain_litert_error", "StagedGemmaBrainTurnEngine", "mobile_brain_staged_pending_litert")

Test-TextEvidence `
  -Id "android-litertlm-dependency" `
  -Name "Android LiteRT-LM dependency and native library declarations" `
  -RelativePaths @("companion/gradle/libs.versions.toml") `
  -Patterns @("litertlm = ""0.13.1""", "com.google.ai.edge.litertlm:litertlm-android")

Test-TextEvidence `
  -Id "android-litertlm-native-libraries" `
  -Name "Android LiteRT-LM optional native library declarations" `
  -RelativePaths @("companion/app-android/src/main/AndroidManifest.xml") `
  -Patterns @("libvndksupport.so", "libOpenCL.so", "android:required=""false""")

Test-TextEvidence `
  -Id "brain-turn-engine-tests" `
  -Name "Brain turn engine route tests" `
  -RelativePaths @("companion/core/src/desktopTest/kotlin/dev/stackchan/companion/core/EndpointServerTest.kt", "companion/app-android/src/test/kotlin/dev/stackchan/companion/android/AndroidBridgeRuntimeStatusTest.kt") `
  -Patterns @("endpointServerRoutesSubmittedTextTurnsThroughConfiguredBrainEngine", "endpointServerRoutesAudioTurnsThroughConfiguredBrainEngine")

Test-TextEvidence `
  -Id "android-staged-gemma-engine-test" `
  -Name "Android staged Gemma brain engine test" `
  -RelativePaths @("companion/app-android/src/test/kotlin/dev/stackchan/companion/android/AndroidBridgeRuntimeStatusTest.kt") `
  -Patterns @("stagedGemmaAssetSelectsTransparentPendingLiteRtBrainEngine", "mobile_brain_staged_pending_litert", "LiteRT runtime inference is not validated")

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
  -Patterns @("DesktopPythonRuntimeStatus", "inspectDesktopPythonRuntime", "Python 3.10+", "STACKCHAN_BRAIN_PYTHON", "scriptAvailable", "searchedCommands", "desktopBrainManagedPythonCandidates", "STACKCHAN_BRAIN_PYTHON_RUNTIME", "python-runtime", "packagedDesktopBrainScriptPath")

Test-TextEvidence `
  -Id "desktop-python-runtime-payload-status" `
  -Name "Desktop managed Python runtime payload status" `
  -RelativePaths @("companion/app-desktop/src/main/kotlin/dev/stackchan/companion/desktop/DesktopBrainSupervisor.kt") `
  -Patterns @("DesktopManagedPythonRuntimeStatus", "inspectDesktopManagedPythonRuntime", "stackchan-python-runtime.json", "No managed Python runtime payload found", "Managed Python runtime payload present")

Test-TextEvidence `
  -Id "desktop-python-runtime-payload-evidence" `
  -Name "Desktop managed Python runtime payload diagnostics evidence" `
  -RelativePaths @("companion/app-desktop/src/main/kotlin/dev/stackchan/companion/desktop/DesktopDiagnosticsExport.kt", "companion/app-desktop/src/main/kotlin/dev/stackchan/companion/desktop/BrainSupervisorRehearsal.kt") `
  -Patterns @("managed_runtime", "present", "manifest_path", "python_path")

Test-TextEvidence `
  -Id "desktop-python-runtime-payload-contract" `
  -Name "Desktop managed Python runtime payload contract" `
  -RelativePaths @("docs/DESKTOP_PYTHON_RUNTIME.md", "tools/check_desktop_python_runtime_payload.ps1") `
  -Patterns @("Desktop Managed Python Runtime", "stackchan.desktop-python-runtime.v1", "python-runtime", "runtime/python", "stackchan-python-runtime.json", "Python 3.10 or newer", "check_desktop_python_runtime_payload.ps1")

Test-TextEvidence `
  -Id "desktop-python-runtime-payload-checker" `
  -Name "Desktop managed Python runtime payload checker" `
  -RelativePaths @("tools/check_desktop_python_runtime_payload.ps1") `
  -Patterns @("stackchan.desktop-python-runtime.v1", "stackchan.desktop-python-runtime-payload.v1", "Find-PythonExecutable", "Test-PythonVersion", "STACKCHAN_BRAIN_PYTHON_RUNTIME", "Python 3.10+", "manifest-platform-match", "manifest-sha256-format", "manifest-python-version-match", "platform =", "pythonVersion =", "runtimeSha256", "runtimeSource", "probedPythonVersion")

Test-TextEvidence `
  -Id "desktop-python-runtime-payload-contract-test" `
  -Name "Desktop managed Python runtime payload contract test" `
  -RelativePaths @("tools/test_desktop_python_runtime_payload_contract.ps1") `
  -Patterns @("placeholder sha256 is rejected", "placeholder runtime source is rejected", "platform mismatch is rejected", "pythonVersion mismatch is rejected", "valid desktop runtime payload is accepted", "platform, pythonVersion, probedPythonVersion, runtimeSha256, and runtimeSource", "Desktop Python runtime payload contract tests passed")

Test-TextEvidence `
  -Id "desktop-package-evidence-export" `
  -Name "Native desktop package/runtime evidence exporter" `
  -RelativePaths @("tools/export_desktop_package_evidence.ps1") `
  -Patterns @("stackchan.desktop-package-evidence.v1", "stackchan.desktop-python-runtime-prepare.v1", "Get-RuntimePayloadHash", "native-app-resources", "Expand-DesktopPackage", "RequireInstallerPayload", "RequireLaunchEvidence", "launchEvidence", "processedPayloadSha256", "processedFileCount", "Installer runtime payload hash does not match processed Gradle resources")

Test-TextEvidence `
  -Id "desktop-package-launch-smoke" `
  -Name "Exact native desktop package launch smoke" `
  -RelativePaths @("tools/test_desktop_package_launch.ps1", "tools/test_desktop_package_launch.cmd", "companion/app-desktop/src/main/kotlin/dev/stackchan/companion/desktop/PackagedRuntimeSmoke.kt") `
  -Patterns @("stackchan.desktop-package-launch-evidence.v1", "stackchan.desktop-packaged-runtime-smoke.v1", "exact-native-package-extraction-and-headless-launch", "extracted-native-package-headless-runtime-probe", "package-extraction", "substitutesForTargetInstall", "--package-smoke-output=", "--package-smoke-context=")

Test-AggregateTextEvidence `
  -Id "desktop-target-install-evidence" `
  -Name "Native desktop operator target-install evidence" `
  -RelativePaths @("tools/install_desktop_companion_package.ps1", "tools/check_desktop_target_install_evidence.ps1") `
  -Patterns @("stackchan.desktop-target-install-evidence.v1", "stackchan.desktop-target-install-evidence-check.v1", "installed-and-ready", "operator-target-workstation", "ci-native-runner", "exact-native-package-install-and-headless-launch", "installed-native-package-headless-runtime-probe", "RequireOperatorTarget", "substitutesForHumanAcceptance")

Test-TextEvidence `
  -Id "desktop-target-install-evidence-contract" `
  -Name "Native desktop target-install evidence contract" `
  -RelativePaths @("tools/test_desktop_target_install_evidence_contract.ps1", "tools/test_desktop_target_install_evidence_contract.cmd") `
  -Patterns @("operator target-install evidence is accepted for Windows, Linux, and macOS", "stale target-install package hash is rejected", "CI native-runner evidence cannot replace operator target evidence", "package extraction cannot replace installed launcher evidence", "missing install and launch exit codes are rejected", "mismatched target-install source commit is rejected", "Desktop target install evidence contract tests passed")

Test-TextEvidence `
  -Id "desktop-package-evidence-contract" `
  -Name "Native desktop package/runtime evidence contract test" `
  -RelativePaths @("tools/test_desktop_package_evidence_contract.ps1", "tools/test_desktop_package_evidence_contract.cmd") `
  -Patterns @("tagged release requires native signing, notarization, and provenance attestation", "complete installer-derived desktop package evidence is accepted", "installed launch context cannot replace package-extraction evidence", "installer runtime tampering is rejected", "JAR-embedded executable runtime is rejected", "aggregate companion evidence accepts all three native package reports", "aggregate companion evidence rejects installer-derived runtime mismatch", "aggregate companion evidence rejects stale exact-package launch evidence", "aggregate companion evidence rejects missing native distribution trust", "strict aggregate evidence rejects a missing native package report", "wrong platform package extension is rejected", "processed runtime tampering is rejected", "runtime prepare platform mismatch is rejected", "Desktop package evidence contract tests passed")

Test-AggregateTextEvidence `
  -Id "desktop-release-signing-readiness" `
  -Name "Desktop release signing credential preflight" `
  -RelativePaths @("tools/check_desktop_release_signing_readiness.ps1", "tools/test_desktop_release_signing_readiness_contract.ps1", ".github/workflows/companion-signing-readiness.yml", ".github/workflows/firmware.yml") `
  -Patterns @("stackchan.desktop-signing-readiness.v1", "private code-signing certificate", "RequireNativeToolchain", "ValidateAppleNotaryCredentials", "does not chain to a root trusted by the native host", "temporary Authenticode signing probe", "temporary Developer ID signing probe", "manual signing readiness workflow validates without publishing", "tagged release runs native desktop signing preflight", "companion CI runs the desktop signing readiness contract", "invalid Windows PKCS12 base64 is rejected", "wrong Windows PKCS12 password is rejected", "Windows certificate without code-signing EKU is rejected", "near-expiry Windows certificate is rejected", "undersized Windows signing key is rejected", "mismatched macOS signing identity is rejected", "mismatched Apple team ID is rejected", "Desktop release signing readiness contract passed", "workflow_dispatch", "contents: read")

Test-TextEvidence `
  -Id "desktop-v1-evidence-bundle-check" `
  -Name "Desktop v1 aggregate evidence bundle check" `
  -RelativePaths @("tools/check_desktop_v1_evidence_bundle.ps1") `
  -Patterns @("stackchan.desktop-v1-evidence-bundle.v1", "desktop-v1-evidence-ready", "pending-desktop-v1-evidence-bundle", "stackchan.desktop-python-runtime-payload.v1", "stackchan.desktop-target-install-evidence.v1", "windowsTargetInstallReport", "macosTargetInstallReport", "linuxTargetInstallReport", "Test-DesktopTargetInstallReport", "RequireOperatorTarget", "Target installation decision: pass", "pc-brain-deploy-ready", "pc-brain-quiet-soak-ready", "production-voice-source-ready", "companion-readiness-source-commit-match", "pc-brain-deploy-commit-match", "pc-brain-quiet-soak-commit-match", "voice-source-commit-match", "sourceCommit", "windowsMsiSha256", "macosDmgSha256", "linuxDebSha256", "runtime-windows-summary", "runtime-macos-summary", "runtime-linux-summary", "Test-RuntimePayloadSummary", "runtimeSha256", "runtimeSource", "probedPythonVersion", "Get-ReviewSourceCommit", "Source commit:", "DESKTOP_V1_REVIEW.md", "RequireReady")

Test-TextEvidence `
  -Id "desktop-v1-evidence-bundle-contract" `
  -Name "Desktop v1 aggregate evidence bundle contract test" `
  -RelativePaths @("tools/test_desktop_v1_evidence_bundle_contract.ps1") `
  -Patterns @("placeholder Desktop v1 evidence bundle is pending", "complete Desktop v1 evidence bundle is accepted", "desktop package artifact hashes", "missing Desktop v1 runtime payload summary is rejected", "missing Desktop v1 runtime payload source is rejected", "mismatched Desktop v1 runtime payload platform is rejected", "stale Desktop v1 target-install package hash is rejected", "CI install rehearsal cannot replace Desktop v1 operator target evidence", "mismatched Desktop v1 companion readiness source commit is rejected", "mismatched Desktop v1 review source commit is rejected", "mismatched Desktop v1 voice-source commit is rejected", "mismatched Desktop v1 PC Brain deploy commit is rejected", "mismatched Desktop v1 PC Brain quiet-soak commit is rejected", "desktop-v1-evidence-ready", "pending-desktop-v1-evidence-bundle", "Desktop v1 evidence bundle contract tests passed")

Test-TextEvidence `
  -Id "companion-v1-evidence-bundle-check" `
  -Name "Companion v1 aggregate evidence bundle check" `
  -RelativePaths @("tools/check_companion_v1_evidence_bundle.ps1") `
  -Patterns @("stackchan.companion-v1-evidence-bundle.v1", "companion-v1-evidence-ready", "pending-companion-v1-evidence-bundle", "stackchan.android-v1-evidence-bundle-check.v1", "stackchan.desktop-v1-evidence-bundle-check.v1", "stackchan.rollout-status.v1", "consumer-promotion-ready", "companion-readiness-commit-match", "release-evidence-commit-match", "github-actions-commit-match", "rollout-status-version-match", "android-v1-commit-match", "android-v1-application-id-match", "android-v1-version-name-match", "android-v1-version-code-match", "android-v1-gemma-benchmark-summary", "android-v1-dashboard-media-summary", "gemmaBenchmarkProfile", "gemmaBenchmarkMedianMs", "androidGemmaBenchmarkProfile", "androidGemmaBenchmarkMedianMs", "androidDashboardMediaIds", "phone-live-dashboard", "android-v1-release-apk-hash-match", "android-v1-release-aab-hash-match", "desktop-v1-commit-match", "desktop-v1-artifact-hashes-match", "desktopDistributionTrustRequired", "authenticode-sha256-timestamped", "developer-id-notarized-stapled", "release-package-evidence-present", "voice-source-commit-match", "rollout-hardware-root-match", "rollout-hardware-commit-match", "sourceCommit", "firmwareSourceCommit", "firmware-source-commit", "releaseVersion", "applicationId", "apkSha256", "versionCode", "packageEvidence", "Get-ReviewSourceCommit", "Get-ReviewReleaseVersion", "Get-Sha256Text", "Convert-ToAndroidVersionName", "Get-AndroidSourceApplicationId", "Test-AndroidApplicationIdMatchesSource", "Get-AndroidSourceVersionCode", "Test-AndroidVersionCodeMatchesSource", "Test-AndroidV1EvidenceSummary", "Test-AndroidReleaseApkHashMatchesReleaseEvidence", "Test-AndroidReleaseAabHashMatchesReleaseEvidence", "Test-DesktopArtifactHashesMatchReleaseEvidence", "Test-ReleasePackageEvidencePresent", "Test-RolloutHardwareEvidence", "Source commit:", "Release version:", "COMPANION_V1_REVIEW.md", "RequireReady")

Test-TextEvidence `
  -Id "companion-v1-evidence-bundle-contract" `
  -Name "Companion v1 aggregate evidence bundle contract test" `
  -RelativePaths @("tools/test_companion_v1_evidence_bundle_contract.ps1") `
  -Patterns @("placeholder Companion v1 evidence bundle is pending", "complete Companion v1 evidence bundle with distinct release and firmware commits is accepted", "missing desktop distribution trust is rejected by final Companion v1 evidence", "legacy same-commit Companion v1 evidence bundle remains accepted", "stale Companion v1 Android evidence summary is rejected", "slow or incomplete Companion v1 Android evidence summary is rejected", "Android Gemma benchmark and dashboard media summaries", "mismatched Companion v1 release ZIP hash is rejected", "mismatched Companion v1 source-readiness commit is rejected", "mismatched Companion v1 hardware evidence root is rejected", "mismatched Companion v1 hardware evidence commit is rejected", "mismatched Companion v1 report commit is rejected", "mismatched Companion v1 Android bundle commit is rejected", "mismatched Companion v1 Android applicationId is rejected", "mismatched Companion v1 Android app version is rejected", "mismatched Companion v1 Android app versionCode is rejected", "mismatched Companion v1 Android release APK hash is rejected", "mismatched Companion v1 Android release AAB hash is rejected", "mismatched Companion v1 Desktop package hash is rejected", "mismatched Companion v1 Desktop bundle commit is rejected", "mismatched Companion v1 voice-source commit is rejected", "mismatched Companion v1 review source commit is rejected", "mismatched Companion v1 review release version is rejected", "companion-v1-evidence-ready", "pending-companion-v1-evidence-bundle", "Companion v1 evidence bundle contract tests passed")

Test-TextEvidence `
  -Id "companion-v1-consumer-promotion-binding" `
  -Name "Consumer promotion binds aggregate Companion v1 evidence" `
  -RelativePaths @("tools/verify_consumer_promotion.ps1", "tools/test_consumer_promotion_contract.ps1", "tools/start_hardware_evidence.ps1", "docs/RELEASE_PROCESS.md") `
  -Patterns @("CompanionV1EvidenceRoot", "Assert-CompanionV1PromotionReady", "check_companion_v1_evidence_bundle.ps1", "-RequireReady", "companion-v1-evidence-ready", "Companion v1 aggregate source commit mismatch", "Companion v1 aggregate firmware source commit mismatch", "Companion v1 aggregate release version mismatch", "Companion v1 hardware evidence root does not match the packet being promoted", "Companion v1 release ZIP SHA-256 does not match the package being promoted", "Consumer promotion requires -PackageZip", "companionV1EvidenceRoot")

Test-TextEvidence `
  -Id "desktop-python-runtime-payload-prep-tool" `
  -Name "Desktop managed Python runtime payload preparation tool" `
  -RelativePaths @("tools/prepare_desktop_python_runtime.ps1", "docs/DESKTOP_PYTHON_RUNTIME.md") `
  -Patterns @("stackchan.desktop-python-runtime-prepare.v1", "stackchan.desktop-python-runtime.v1", "stackchan-python-runtime.json", "Get-RuntimePayloadHash", "check_desktop_python_runtime_payload.ps1", "DryRun", "preparedBy", "prepare_desktop_python_runtime.ps1")

Test-TextEvidence `
  -Id "desktop-python-runtime-payload-packaging" `
  -Name "Desktop managed Python runtime payload packaging hook" `
  -RelativePaths @("companion/app-desktop/build.gradle.kts") `
  -Patterns @("stackchan.desktop.pythonRuntimeRoot", "STACKCHAN_DESKTOP_PYTHON_RUNTIME_ROOT", "validateDesktopPythonRuntimePayload", "prepareDesktopNativeAppResources", "appResourcesRootDir", "into(`"common/python-runtime`")", "desktopPythonRuntimeRoot")

Test-TextEvidence `
  -Id "desktop-packaged-brain-script" `
  -Name "Desktop package includes PC brain service script" `
  -RelativePaths @("companion/app-desktop/build.gradle.kts") `
  -Patterns @("lan_service.py", "cancellation.py", "cancellable_process.py", "conversation_latency.py", "conversation_session.py", "utterance_text.py", "character_harness.py", "reference_bridge.py", "stt_adapter.py", "tts_adapter.py", "into(`"brain/bridge`")", "into(`"brain/personas`")", "voice_source_provenance.yaml", "stackchan_spark_greeting.wav")

Test-TextEvidence `
  -Id "desktop-packaged-brain-script-test" `
  -Name "Desktop packaged PC brain service script test" `
  -RelativePaths @("companion/app-desktop/src/test/kotlin/dev/stackchan/companion/desktop/DesktopBrainSupervisorTest.kt") `
  -Patterns @("packagedBrainScriptExtractsLanServiceResource", "--runner-profile", "reference_bridge.py", "personas", "voice_source_provenance.yaml", "--help")

Test-TextEvidence `
  -Id "desktop-python-runtime-evidence" `
  -Name "Desktop Python runtime diagnostics evidence" `
  -RelativePaths @("companion/app-desktop/src/main/kotlin/dev/stackchan/companion/desktop/DesktopDiagnosticsExport.kt", "companion/app-desktop/src/main/kotlin/dev/stackchan/companion/desktop/BrainSupervisorRehearsal.kt") `
  -Patterns @("python_runtime", "available", "version", "script_available", "searched_commands")

Test-TextEvidence `
  -Id "pc-brain-live-probe" `
  -Name "PC Brain live WebSocket probe" `
  -RelativePaths @("bridge/pc_brain_probe.py") `
  -Patterns @("stackchan.pc-brain-probe.v1", "endpoint_hello", "claim_brain", "utterance_end", "response_end", "binary_frames", "binary_bytes", "PC_BRAIN_PROBE.json")

Test-TextEvidence `
  -Id "pc-brain-launch-helper" `
  -Name "PC Brain Ollama selected-voice launch helper" `
  -RelativePaths @("tools/start_pc_brain.ps1") `
  -Patterns @("STACKCHAN_OLLAMA_MODEL", "STACKCHAN_FFMPEG_EXE", "STACKCHAN_SELECTED_VOICE_MAX_AUDIO_BYTES", "ollama_stackchan_runner.py", "selected_voice_tts.py", "--downlink-binary-frame-delay-ms", "--auto-turn-text", "lan_service.pid")

Test-AggregateTextEvidence `
  -Id "pc-brain-trusted-facts" `
  -Name "PC Brain deterministic trusted facts and silent production smoke" `
  -RelativePaths @("bridge/local_facts.py", "bridge/trusted_facts_smoke.py", "bridge/test_local_facts.py", "bridge/test_trusted_facts_smoke.py", "docs/BRAIN_MODEL.md") `
  -Patterns @("resolve_local_fact", "local_clock", "memory_recall", "stackchan.trusted-facts-smoke.v1", "modelInvocations", "audioPlayed", "passthroughCases", "trusted_facts_smoke.py")

Test-TextEvidence `
  -Id "pc-brain-deploy-evidence-helper" `
  -Name "PC Brain deploy evidence collector" `
  -RelativePaths @("tools/collect_pc_brain_deploy_evidence.ps1") `
  -Patterns @("stackchan.pc-brain-deploy-evidence.v1", "sourceCommit", "SourceCommit", "Source commit:", "stackchan_debug.json", "PC_BRAIN_DEPLOY_EVIDENCE.json", "PC_BRAIN_DEPLOY_EVIDENCE.md", "bridge_downlink_playback_errors", "audio_stream_not_started", "audio_stream_chunk_mismatch", "playback_chunk_mismatch")

Test-TextEvidence `
  -Id "pc-brain-deploy-evidence-check" `
  -Name "PC Brain deploy evidence checker" `
  -RelativePaths @("tools/check_pc_brain_deploy_evidence.ps1") `
  -Patterns @("stackchan.pc-brain-deploy-evidence-check.v1", "stackchan.pc-brain-deploy-evidence.v1", "pc-brain-deploy-ready", "sourceCommit", "Get-ReviewSourceCommit", "source-commit", "human-review-source-commit-match", "audio-stream-started", "playback-started", "speaker-task-bytes-match", "RequireTests", "RequireReady")

Test-TextEvidence `
  -Id "pc-brain-quiet-soak-runner" `
  -Name "PC Brain quiet soak runner" `
  -RelativePaths @("tools/run_pc_brain_quiet_soak.ps1") `
  -Patterns @("stackchan.pc-brain-quiet-soak.v1", "sourceCommit", "SourceCommit", "Source commit:", "requested_duration_seconds", "interval_seconds", "debug-endpoint-ok", "unexpected_audio_stream_during_quiet_soak", "PC_BRAIN_QUIET_SOAK.json", "PC_BRAIN_QUIET_SOAK.md")

Test-TextEvidence `
  -Id "pc-brain-quiet-soak-evidence-check" `
  -Name "PC Brain quiet soak evidence checker" `
  -RelativePaths @("tools/check_pc_brain_quiet_soak_evidence.ps1") `
  -Patterns @("stackchan.pc-brain-quiet-soak-evidence-check.v1", "stackchan.pc-brain-quiet-soak.v1", "pc-brain-quiet-soak-ready", "sourceCommit", "Get-ReviewSourceCommit", "source-commit", "human-review-source-commit-match", "no-unexpected-audio-streams", "bridge-message-monotonic", "MinDurationSeconds", "RequireReady")

Test-TextEvidence `
  -Id "pc-brain-runner-and-selected-voice" `
  -Name "PC Brain Ollama runner and selected voice TTS" `
  -RelativePaths @("bridge/ollama_stackchan_runner.py", "bridge/selected_voice_tts.py") `
  -Patterns @("Ollama-backed Stackchan runner", "STACKCHAN_OLLAMA_MODEL", "STACKCHAN_OLLAMA_API_URL", "keep_alive", "run_api", "run_cli", "validate_response")

Test-AggregateTextEvidence `
  -Id "pc-brain-voice-v2-streaming" `
  -Name "PC Brain Voice V2 streaming, mouth, and supervised validation" `
  -RelativePaths @("bridge/lan_service.py", "bridge/rvc_directml_tts_client.py", "bridge/rvc_directml_worker_service.py", "bridge/voice_v2_directml_runtime.py", "tools/start_voice_v2_supervised_validation.ps1", "tools/check_voice_v2_supervised_evidence.ps1", "docs/VOICE_V2_DIRECTML.md") `
  -Patterns @("mouth_frame_for_audio_window", "tts_mouth_frames", "user_text=user_text", "STACKCHAN_RVC_DIRECTML_WORKER_URL", "DirectMlRvcRuntime", "speaker_stream_chunked", "voice-v2-supervised-ready", "host-robot-byte-match", "Speech-mouth evidence")

Test-TextEvidence `
  -Id "pc-brain-selected-voice-tts" `
  -Name "PC Brain selected voice TTS adapter" `
  -RelativePaths @("bridge/selected_voice_tts.py") `
  -Patterns @("stackchan.tts-metadata.v1", "STACKCHAN_SELECTED_VOICE_SAMPLE", "STACKCHAN_SELECTED_VOICE_MAX_AUDIO_BYTES", "audio_format", "pcm16", "audio_b64", "stackchan-rvc-bright-robot")

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
  -Patterns @("speechPermissionLauncher", "Manifest.permission.RECORD_AUDIO", "CompanionBridgeService.submitTextTurn", "Speech transcript", "StackchanSpeech", "stackchan_speech_evidence", "final_transcript", "submit_result", "transcript_redacted=1", "raw_audio_retention=none", "Microphone permission denied. Enable it in Android app settings, then retry. No transcript was sent.", "Settings.ACTION_APPLICATION_DETAILS_SETTINGS")

Test-TextEvidence `
  -Id "shared-push-to-talk-ui" `
  -Name "Shared Talk UI exposes push-to-talk state" `
  -RelativePaths @("companion/ui/src/commonMain/kotlin/dev/stackchan/companion/ui/CompanionConsole.kt", "provenance/companion/ui/src/commonMain/kotlin/dev/stackchan/companion/ui/CompanionConsole.kt") `
  -Patterns @("pushToTalkEnabled", "pushToTalkLabel", "pushToTalkStatus", "onPushToTalk")

Test-TextEvidence `
  -Id "android-diagnostics-export" `
  -Name "Android diagnostics export implementation" `
  -RelativePaths @("companion/app-android/src/main/kotlin/dev/stackchan/companion/android/AndroidDiagnosticsExport.kt") `
  -Patterns @("stackchan.android.diagnostics-export.v1", "ANDROID_DIAGNOSTICS_EXPORT.json", "AndroidAppIdentity", "package_name", "version_name", "version_code", "last_text_turn_present", "robot_socket_connected", "raw_audio_retention", "last text turn redacted to presence only", "wifi_provisioning_command_template", "password_redacted", "model_id", "expected_sha256", "runner_status", "mobile_brain_litert_turn", "mobile_brain_litert_error", "requires_real_device_inference_evidence")

Test-TextEvidence `
  -Id "android-diagnostics-export-evidence-check" `
  -Name "Android diagnostics export evidence check" `
  -RelativePaths @("tools/check_android_diagnostics_export_evidence.ps1", "provenance/tools/check_android_diagnostics_export_evidence.ps1") `
  -Patterns @("stackchan.android-diagnostics-export-evidence.v1", "stackchan.android.diagnostics-export.v1", "ANDROID_DIAGNOSTICS_EXPORT.json", "ANDROID_DIAGNOSTICS_REVIEW.md", "package_name", "version_code", "app-package-name", "app-version-code", "Get-AndroidSourceIdentity", "password_redacted", "last_text_turn_present", "requires_real_device_inference_evidence", "sourceCommit", "expectedSourceCommit", "diagnostics-review-source-commit-match", "applicationId", "versionName", "versionCode", "Get-ReviewSourceCommit", "pending-android-diagnostics-export-evidence", "Support decision: pass", "RequireReady")

Test-TextEvidence `
  -Id "android-diagnostics-export-evidence-contract" `
  -Name "Android diagnostics export evidence contract test" `
  -RelativePaths @("tools/test_android_diagnostics_export_evidence_contract.ps1", "provenance/tools/test_android_diagnostics_export_evidence_contract.ps1") `
  -Patterns @("complete Android diagnostics export evidence is accepted", "mismatched Android diagnostics package name is rejected", "mismatched Android diagnostics versionCode is rejected", "stale Android diagnostics review source commit is rejected", "applicationId, versionName, versionCode, and expectedSourceCommit", "Android diagnostics export evidence contract tests passed")

Test-TextEvidence `
  -Id "android-speech-evidence-check" `
  -Name "Android speech push-to-talk evidence check" `
  -RelativePaths @("tools/check_android_speech_evidence.ps1", "provenance/tools/check_android_speech_evidence.ps1") `
  -Patterns @("stackchan.android-speech-evidence.v1", "ANDROID_SPEECH_REVIEW.md", "android_speech_logcat.txt", "robot_speech_serial.log", "stackchan_speech_evidence", "event=final_transcript", "event=submit_result", "accepted=1", "seq_present=1", "message_type=app_text_turn", "transcript_redacted=1", "raw_audio_retention=none", "response_start", "audio_stream_start", "audio_stream_end", "response_end", "sourceCommit", "expectedSourceCommit", "speech-review-source-commit-match", "Get-ReviewSourceCommit", "Speech recognizer decision: pass", "Transcript submission decision: pass", "Robot response-frame decision: pass", "pending-android-speech-evidence", "android-speech-ready", "RequireReady")

Test-TextEvidence `
  -Id "android-speech-evidence-contract" `
  -Name "Android speech push-to-talk evidence contract test" `
  -RelativePaths @("tools/test_android_speech_evidence_contract.ps1", "tools/test_android_speech_evidence_contract.cmd") `
  -Patterns @("complete Android speech evidence is accepted", "missing Android speech robot response frames remain pending", "Android speech diagnostics transcript privacy leak is rejected", "stale Android speech review source commit is rejected", "Android speech evidence contract tests passed")

Test-TextEvidence `
  -Id "android-controls-evidence-check" `
  -Name "Android protected controls evidence check" `
  -RelativePaths @("tools/check_android_controls_evidence.ps1", "provenance/tools/check_android_controls_evidence.ps1") `
  -Patterns @("stackchan.android-controls-evidence.v1", "ANDROID_CONTROLS_REVIEW.md", "robot_controls_serial.log", "settings_set", "settings_result", "claim_brain", "release_brain", "owner_status", "robot_hello_required", "sourceCommit", "expectedSourceCommit", "controls-review-source-commit-match", "Get-ReviewSourceCommit", "Settings write decision: pass", "Claim brain decision: pass", "Release brain decision: pass", "Robot hello gate decision: pass", "pending-android-controls-evidence", "android-controls-ready", "RequireReady")

Test-TextEvidence `
  -Id "android-controls-evidence-contract" `
  -Name "Android protected controls evidence contract test" `
  -RelativePaths @("tools/test_android_controls_evidence_contract.ps1", "tools/test_android_controls_evidence_contract.cmd") `
  -Patterns @("complete Android controls evidence is accepted", "missing Android controls robot hello gate remains pending", "Android controls non-Android endpoint identity is rejected", "stale Android controls review source commit is rejected", "Android controls evidence contract tests passed")

Test-TextEvidence `
  -Id "android-pairing-evidence-check" `
  -Name "Android QR short-code pairing evidence check" `
  -RelativePaths @("tools/check_android_pairing_evidence.ps1", "provenance/tools/check_android_pairing_evidence.ps1") `
  -Patterns @("stackchan.android-pairing-evidence.v1", "ANDROID_PAIRING_REVIEW.md", "robot_pairing_serial.log", "android_pairing_setup.jpg", "pairing_code_present", "stackchan://pair", "pairing_code_mismatch", "bridge_url_applied", "endpoint_hello_result", "trusted_endpoints_result", "sourceCommit", "expectedSourceCommit", "pairing-review-source-commit-match", "Get-ReviewSourceCommit", "Setup media decision: pass", "Wrong-code rejection decision: pass", "QR ticket/manual code decision: pass", "Trusted endpoint decision: pass", "Password privacy decision: pass", "pending-android-pairing-evidence", "android-pairing-ready", "RequireReady")

Test-TextEvidence `
  -Id "android-pairing-evidence-contract" `
  -Name "Android QR short-code pairing evidence contract test" `
  -RelativePaths @("tools/test_android_pairing_evidence_contract.ps1", "tools/test_android_pairing_evidence_contract.cmd") `
  -Patterns @("complete Android pairing evidence is accepted", "missing Android pairing wrong-code rejection remains pending", "Android pairing non-Android endpoint identity is rejected", "stale Android pairing review source commit is rejected", "Android pairing evidence contract tests passed")

Test-TextEvidence `
  -Id "android-wifi-evidence-check" `
  -Name "Android Wi-Fi provisioning evidence check" `
  -RelativePaths @("tools/check_android_wifi_evidence.ps1", "provenance/tools/check_android_wifi_evidence.ps1") `
  -Patterns @("stackchan.android-wifi-evidence.v1", "ANDROID_WIFI_REVIEW.md", "robot_wifi_serial.log", "wifi_provisioning_command_template", "password_redacted", "[wifi]", "persisted=1", "store_has_record=1", "enabled=1", "ssid_set=1", "bridge_wifi_store_loads", "bridge_wifi_store_has_record=1", "wifi clear", "store_has_record=0", "sourceCommit", "expectedSourceCommit", "wifi-review-source-commit-match", "Get-ReviewSourceCommit", "Power-cycle reload decision: pass", "Clear command decision: pass", "pending-android-wifi-evidence", "android-wifi-ready", "RequireReady")

Test-TextEvidence `
  -Id "android-wifi-evidence-contract" `
  -Name "Android Wi-Fi provisioning evidence contract test" `
  -RelativePaths @("tools/test_android_wifi_evidence_contract.ps1", "tools/test_android_wifi_evidence_contract.cmd") `
  -Patterns @("complete Android Wi-Fi evidence is accepted", "missing Android Wi-Fi reload proof remains pending", "Android Wi-Fi robot log password leak is rejected", "stale Android Wi-Fi review source commit is rejected", "Android Wi-Fi evidence contract tests passed")

Test-TextEvidence `
  -Id "android-gemma-evidence-check" `
  -Name "Android Gemma real-device evidence check" `
  -RelativePaths @("tools/check_android_gemma_evidence.ps1", "provenance/tools/check_android_gemma_evidence.ps1") `
  -Patterns @("stackchan.android-gemma-evidence.v1", "ANDROID_GEMMA_REVIEW.md", "android_gemma_logcat.txt", "BenchmarkPath", "stackchan.model-benchmark.v1", "gemma4-e2b-litert-lm", "benchmark-candidate-gate", "benchmark-profile-ready", "benchmark-speed", "Benchmark decision: pass", "Gemma-4-E2B", "LiteRT-LM", "gemma-4-E2B-it.litertlm", "2588147712", "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c", "litert_adapter_selected", "mobile_brain_litert_turn", "mobile_brain_litert_error", "sourceCommit", "expectedSourceCommit", "ExpectedSourceCommit", "Get-ReviewSourceCommit", "gemma-review-source-commit-match", "Eject/reload decision: pass", "Robot audio/TTS decision: pass", "pending-android-gemma-evidence", "android-gemma-real-device-ready", "RequireReady")

Test-TextEvidence `
  -Id "android-gemma-evidence-contract" `
  -Name "Android Gemma evidence contract test" `
  -RelativePaths @("tools/test_android_gemma_evidence_contract.ps1", "provenance/tools/test_android_gemma_evidence_contract.ps1") `
  -Patterns @("complete Android Gemma benchmark evidence is accepted", "missing Android Gemma benchmark evidence is rejected", "dry-run Android Gemma benchmark evidence is rejected", "slow Android Gemma benchmark evidence is rejected", "stale Android Gemma review source commit is rejected", "Android Gemma evidence contract tests passed")

Test-TextEvidence `
  -Id "android-play-release-prep" `
  -Name "Android Play release preparation" `
  -RelativePaths @("docs/ANDROID_PLAY_RELEASE.md", "provenance/docs/ANDROID_PLAY_RELEASE.md") `
  -Patterns @("Android Play Release Checklist", "app-android-release.aab", "Play App Signing", "STACKCHAN_ANDROID_KEYSTORE", "One-Time Upload Key Provisioning", "keytool -genkeypair", "cryptographically validates", "test_android_upload_signing_contract.ps1", "certificate SHA-256 fingerprint", "2033-10-22", "exact release APK artifact", "RequireAndroidEmulatorEvidence", "gh secret set STACKCHAN_ANDROID_KEYSTORE_B64", "gh secret list --app actions", "Companion Signing Readiness", "companion-signing-readiness.yml", "two independent offline media", "docs/store-assets/play/icon-512.png", "feature-graphic-1024x500.png", "SCREENSHOT_CAPTURE_PLAN.md", "fastlane/metadata/android/en-US/", "ANDROID_PLAY_POLICY_DECLARATIONS.md", "ANDROID_PLAY_PRIVACY_POLICY.md", "physical robot validation", "RECORD_AUDIO", "Play Console internal testing")

Test-TextEvidence `
  -Id "android-play-policy-declarations" `
  -Name "Android Play policy and data-safety declarations" `
  -RelativePaths @("docs/ANDROID_PLAY_POLICY_DECLARATIONS.md", "provenance/docs/ANDROID_PLAY_POLICY_DECLARATIONS.md") `
  -Patterns @("Google Play Data safety form", "Google Play User Data policy", "Privacy policy URL", "https://robvanprod.github.io/stackchan_alive/privacy/", "ANDROID_PLAY_PRIVACY_POLICY.md", "Data Safety Draft", "Collected only for optional, ephemeral app functionality", "RECORD_AUDIO", "configured Android SpeechRecognizer may transmit microphone audio", "password_redacted=true", "not represented as end-to-end encrypted", "Foreground service Play Console draft", "connectedDevice", "REQUEST_IGNORE_BATTERY_OPTIMIZATIONS", "not directed to children")

Test-TextEvidence `
  -Id "android-play-privacy-policy-page" `
  -Name "Android Play privacy policy page" `
  -RelativePaths @("docs/ANDROID_PLAY_PRIVACY_POLICY.md", "provenance/docs/ANDROID_PLAY_PRIVACY_POLICY.md") `
  -Patterns @("Stackchan Companion Privacy Policy", "July 14, 2026", "https://robvanprod.github.io/stackchan_alive/privacy/", "dev.stackchan.companion", "does not create accounts", "does not persist raw microphone audio", "may process microphone audio", "diagnostics export", "password_redacted=true", "optional Mobile Brain model", "saved robot and trusted companion records", "not represented as end-to-end encrypted", "not directed to children")

Test-TextEvidence `
  -Id "android-play-privacy-policy-site" `
  -Name "Deployable public privacy-policy site" `
  -RelativePaths @("site/privacy/index.html") `
  -Patterns @("Stackchan Companion Privacy Policy", "July 14, 2026", "dev.stackchan.companion", "Privacy inquiries", "configured Android speech-recognition service", "may process audio", "password_redacted=true", "not represented as end-to-end encrypted", "not directed to children")

Test-TextEvidence `
  -Id "android-play-privacy-deployment-record" `
  -Name "Published privacy-policy deployment record" `
  -RelativePaths @("docs/store-assets/play/PRIVACY_POLICY_DEPLOYMENT.json") `
  -Patterns @("stackchan.privacy-policy-deployment.v1", "deployed", "https://robvanprod.github.io/stackchan_alive/privacy/", "site/privacy/index.html", "afbebbd3429e00a6f76cb238788ce7664f1b6fda", "49cefe092920c0a12da50896356394d380df6904", "1094346889", "28d1cca7889f8d95c0587025ee5d46c213a85ac814c538e3c36090b377fd1f47", "httpsEnforced")

Test-TextEvidence `
  -Id "android-play-privacy-deployment-checker" `
  -Name "Published privacy-policy deployment checker" `
  -RelativePaths @("tools/check_privacy_policy_deployment.ps1", "provenance/tools/check_privacy_policy_deployment.ps1") `
  -Patterns @("stackchan.privacy-policy-deployment-check.v1", "privacy-policy-deployment-ready", "live-https", "Published policy byte identity", "Published policy disclosures", "sourceSha256", "servedSha256")

Test-TextEvidence `
  -Id "android-play-privacy-deployment-contract" `
  -Name "Privacy-policy deployment contract" `
  -RelativePaths @("tools/test_privacy_policy_deployment_contract.ps1", "provenance/tools/test_privacy_policy_deployment_contract.ps1") `
  -Patterns @("exact published privacy policy bytes are accepted", "tampered published privacy policy bytes are rejected", "noncanonical privacy policy URL is rejected", "stale privacy policy source hash is rejected", "pending privacy policy deployment status is rejected", "5/5")

Test-TextEvidence `
  -Id "android-play-privacy-pages-workflow" `
  -Name "Privacy-policy Pages deployment workflow" `
  -RelativePaths @(".github/workflows/pages.yml", "provenance/pages.yml") `
  -Patterns @("Deploy privacy policy", "main", "site/**", "pages: write", "id-token: write", "actions/configure-pages@v5", "actions/upload-pages-artifact@v4", "path: site", "actions/deploy-pages@v4")

Test-TextEvidence `
  -Id "android-play-privacy-app-identity" `
  -Name "Canonical privacy-policy URL in companion identity" `
  -RelativePaths @("companion/core/src/commonMain/kotlin/dev/stackchan/companion/core/CompanionIdentity.kt", "provenance/companion/core/src/commonMain/kotlin/dev/stackchan/companion/core/CompanionIdentity.kt") `
  -Patterns @("privacyPolicyUrl", "https://robvanprod.github.io/stackchan_alive/privacy/")

Test-TextEvidence `
  -Id "android-play-privacy-android-link" `
  -Name "Android in-app privacy-policy link" `
  -RelativePaths @("companion/app-android/src/main/kotlin/dev/stackchan/companion/android/MainActivity.kt", "provenance/companion/app-android/src/main/kotlin/dev/stackchan/companion/android/MainActivity.kt") `
  -Patterns @("onOpenPrivacyPolicy", "Intent.ACTION_VIEW", "CompanionIdentity.privacyPolicyUrl")

Test-TextEvidence `
  -Id "android-play-privacy-desktop-link" `
  -Name "Desktop in-app privacy-policy link" `
  -RelativePaths @("companion/app-desktop/src/main/kotlin/dev/stackchan/companion/desktop/Main.kt", "provenance/companion/app-desktop/src/main/kotlin/dev/stackchan/companion/desktop/Main.kt") `
  -Patterns @("onOpenPrivacyPolicy", "Desktop.Action.BROWSE", "CompanionIdentity.privacyPolicyUrl")

Test-TextEvidence `
  -Id "android-play-privacy-shared-ui" `
  -Name "Shared in-app privacy-policy command" `
  -RelativePaths @("companion/ui/src/commonMain/kotlin/dev/stackchan/companion/ui/CompanionConsole.kt", "provenance/companion/ui/src/commonMain/kotlin/dev/stackchan/companion/ui/CompanionConsole.kt") `
  -Patterns @("onOpenPrivacyPolicy", "Privacy policy", "Export logs")

Test-TextEvidence `
  -Id "android-play-speech-offline-preference" `
  -Name "Android speech requests offline recognition" `
  -RelativePaths @("companion/app-android/src/main/kotlin/dev/stackchan/companion/android/AndroidSpeechTurnController.kt", "provenance/companion/app-android/src/main/kotlin/dev/stackchan/companion/android/AndroidSpeechTurnController.kt") `
  -Patterns @("RecognizerIntent.EXTRA_PREFER_OFFLINE", "true")

Test-TextEvidence `
  -Id "android-play-readiness-check" `
  -Name "Android Play source readiness check" `
  -RelativePaths @("tools/check_android_play_release_readiness.ps1", "provenance/tools/check_android_play_release_readiness.ps1") `
  -Patterns @("stackchan.android-play-release-readiness.v1", "RequireUploadSigning", "uploadSigningRequired", "ExportParameters", "Play high-resolution icon", "Play screenshot capture plan", "Gradle Play upload signing inputs", "keytool private-key validation", "RSACertificateExtensions", "project policy requires at least 4096 bits", "2033-10-23 UTC", "certificate SHA-256", "CI builds Android release bundle", "CI runs Android emulator launch smoke", "Tag release validates upload key and exact release APK launch", "RequireAndroidEmulatorEvidence", "Release evidence covers AAB signing", "play-store-evidence-checker", "applicationId", "play-policy-declarations", "play-privacy-policy-page", "play-privacy-policy-site", "play-privacy-pages-workflow", "play-privacy-android-link", "play-privacy-desktop-link", "play-speech-offline-preference")

Test-TextEvidence `
  -Id "android-upload-signing-contract" `
  -Name "Android upload signing contract test" `
  -RelativePaths @("tools/test_android_upload_signing_contract.ps1", "provenance/tools/test_android_upload_signing_contract.ps1") `
  -Patterns @("manual signing readiness workflow validates Android upload key without publishing", "tagged Android release requires upload signing readiness", "required upload signing credentials fail closed when missing", "valid 4096-bit private upload key is accepted", "missing upload-key alias is rejected", "wrong keystore password is rejected", "wrong private-key password is rejected", "weak 2048-bit upload key is rejected", "Android debug certificate subject is rejected", "upload certificate expiring before the Play minimum is rejected", "output exposed a contract credential")

Test-TextEvidence `
  -Id "android-emulator-launch-smoke" `
  -Name "Android emulator install and launch smoke" `
  -RelativePaths @("tools/test_android_emulator_launch.ps1", "provenance/tools/test_android_emulator_launch.ps1") `
  -Patterns @("stackchan.android-emulator-launch-smoke.v1", "ro.kernel.qemu=1", "POST_NOTIFICATIONS", "MainActivity is not the top resumed activity", "CompanionBridgeService is absent after launch", "fatalProcessMatches", "substitutesForPhysicalEvidence", "emulator-install-launch-service-smoke-only")

Test-TextEvidence `
  -Id "android-emulator-release-evidence-check" `
  -Name "Android emulator release APK evidence binding" `
  -RelativePaths @("tools/check_android_emulator_release_evidence.ps1", "provenance/tools/check_android_emulator_release_evidence.ps1") `
  -Patterns @("stackchan.android-emulator-release-evidence-check.v1", "stackchan.android-emulator-launch-smoke.v1", "MinApiLevel = 35", "dev.stackchan.companion", "MainActivity was not resumed", "CompanionBridgeService was not present", "fatalProcessMatches must be zero", "substitutesForPhysicalEvidence=false", "APK SHA-256 does not match the release APK")

Test-TextEvidence `
  -Id "android-emulator-release-evidence-contract" `
  -Name "Android emulator release evidence contract test" `
  -RelativePaths @("tools/test_android_emulator_release_evidence_contract.ps1", "provenance/tools/test_android_emulator_release_evidence_contract.ps1") `
  -Patterns @("matching release APK evidence", "stale APK hash is rejected", "old emulator API is rejected", "failed launch smoke is rejected", "non-resumed activity is rejected", "missing bridge service is rejected", "fatal process match is rejected", "physical-evidence substitution is rejected", "wrong package identity is rejected", "9/9 passed")

Test-TextEvidence `
  -Id "android-play-store-evidence-check" `
  -Name "Android Play Store post-upload evidence check" `
  -RelativePaths @("tools/check_android_play_store_evidence.ps1", "provenance/tools/check_android_play_store_evidence.ps1") `
  -Patterns @("stackchan.android-play-store-evidence.v1", "play-internal-testing-ready", "internal-testing-ready", "applicationId", "releaseAabSha256", "releaseAabSha256 =", "versionName =", "versionCode =", "playSigningEnabled", "privacyPolicyUrl", "privacyPolicySourcePath", "docs/ANDROID_PLAY_PRIVACY_POLICY.md", "playConsoleReleaseName", "testerGroup", "uploadedAtUtc", "play-console-release", "tester-group", "uploaded-at-utc", "internalTestingInstallStatus", "screenshots", "sourceCommit for", "appVersion for", "Source commit:", "App version:", "Decision: pass", "phone-pairing-setup", "phone-live-dashboard", "phone-brain-model", "phone-personas-diagnostics", "ANDROID_PLAY_POLICY_DECLARATIONS.md", "raw microphone audio is not stored")

Test-TextEvidence `
  -Id "android-play-store-evidence-contract" `
  -Name "Android Play Store evidence contract test" `
  -RelativePaths @("tools/test_android_play_store_evidence_contract.ps1", "provenance/tools/test_android_play_store_evidence_contract.ps1") `
  -Patterns @("placeholder Play Store template is rejected", "complete Play Store internal testing packet is accepted", "applicationId, versionName, versionCode, and releaseAabSha256", "mismatched Play screenshot source commit is rejected", "mismatched Play screenshot app version is rejected", "mismatched Play data-safety review source commit is rejected", "non-pass Play policy review decision is rejected", "pending-play-store-evidence", "play-internal-testing-ready", "phone-pairing-setup", "phone-live-dashboard", "phone-brain-model", "phone-personas-diagnostics")

Test-TextEvidence `
  -Id "android-v1-evidence-bundle-check" `
  -Name "Android v1 aggregate evidence bundle check" `
  -RelativePaths @("tools/check_android_v1_evidence_bundle.ps1", "provenance/tools/check_android_v1_evidence_bundle.ps1") `
  -Patterns @("stackchan.android-v1-evidence-bundle.v1", "android-v1-evidence-ready", "pending-android-v1-evidence-bundle", "android-speech-ready", "android-controls-ready", "android-pairing-ready", "android-wifi-ready", "android-gemma-real-device-ready", "android-screen-off-soak-ready", "play-internal-testing-ready", "sourceCommit", "expectedSourceCommit", "applicationId", "packageName", "apkSha256", "versionName", "versionCode", "releaseAabSha256", "gemmaBenchmarkProfile", "gemma-benchmark-profile", "gemma-benchmark-speed", "benchmarkMedianMs", "gemma4-e2b-litert-lm", "androidDashboardEvidenceRoot", "androidDashboardMedia", "androidDashboardMediaIds", "dashboard-evidence", "phone-live-dashboard", "Connected dashboard media decision", "companion-readiness-source-commit-match", "apk-install-source-commit-match", "diagnostics-expected-source-commit-match", "speech-expected-source-commit-match", "controls-expected-source-commit-match", "pairing-expected-source-commit-match", "wifi-expected-source-commit-match", "gemma-expected-source-commit-match", "screen-off-soak-expected-source-commit-match", "apk-install-application-id-match", "play-store-application-id-match", "speech-source-commit-match", "screen-off-soak-source-commit-match", "play-store-source-commit-match", "play-store-version-name-match", "play-store-version-code-match", "Get-AndroidSourceApplicationId", "Get-ReviewSourceCommit", "Source commit:", "ANDROID_V1_REVIEW.md", "RequireReady")

Test-TextEvidence `
  -Id "android-v1-evidence-bundle-contract" `
  -Name "Android v1 aggregate evidence bundle contract test" `
  -RelativePaths @("tools/test_android_v1_evidence_bundle_contract.ps1", "provenance/tools/test_android_v1_evidence_bundle_contract.ps1") `
  -Patterns @("placeholder Android v1 evidence bundle is pending", "complete Android v1 evidence bundle is accepted", "Android v1 dashboard verified status without media is rejected", "Android v1 dashboard media source commit mismatch is rejected", "mismatched Android v1 companion readiness source commit is rejected", "mismatched Android v1 speech source commit is rejected", "Android v1 evidence without strict SourceCommit pin is rejected", "Android v1 Gemma report without benchmark fields is rejected", "Android v1 Gemma report with slow benchmark fields is rejected", "mismatched Android v1 Play Store source commit is rejected", "mismatched Android v1 APK install packageName is rejected", "mismatched Android v1 Play Store applicationId is rejected", "mismatched Android v1 review source commit is rejected", "Gemma benchmark profile and speed evidence", "dashboard media IDs", "android-v1-evidence-ready", "pending-android-v1-evidence-bundle", "stackchan.android-apk-install.v1")

Test-TextEvidence `
  -Id "android-screen-off-soak-helper" `
  -Name "Android screen-off soak helper" `
  -RelativePaths @("bridge/android_companion_soak.py", "tools/run_android_companion_soak.ps1") `
  -Patterns @("stackchan.android-companion-soak.v1", "DEFAULT_DURATION_SECONDS = 600.0", "DEFAULT_INTERVAL_SECONDS = 30.0", "android_companion_soak.json", "ANDROID_COMPANION_SOAK.md", "--duration-seconds", "--interval-seconds", "--max-failures")

Test-TextEvidence `
  -Id "android-screen-off-soak-evidence-check" `
  -Name "Android screen-off soak evidence check" `
  -RelativePaths @("tools/check_android_screen_off_soak_evidence.ps1") `
  -Patterns @("stackchan.android-screen-off-soak-evidence.v1", "ANDROID_SCREEN_OFF_SOAK_REVIEW.md", "android_companion_soak.json", "ANDROID_COMPANION_SOAK.md", "stackchan.android-companion-soak.v1", "requested_duration_seconds", "success_rate", "endpoint_kind", "sourceCommit", "expectedSourceCommit", "soak-review-source-commit-match", "Get-ReviewSourceCommit", "android-screen-off-soak-ready", "pending-android-screen-off-soak-evidence", "Screen-off decision: pass", "Heartbeat continuity decision: pass", "Wake-lock release decision: pass", "Foreground-service decision: pass", "RequireReady")

Test-TextEvidence `
  -Id "android-screen-off-soak-evidence-contract" `
  -Name "Android screen-off soak evidence contract test" `
  -RelativePaths @("tools/test_android_screen_off_soak_evidence_contract.ps1", "tools/test_android_screen_off_soak_evidence_contract.cmd") `
  -Patterns @("complete Android screen-off soak evidence is accepted", "short Android screen-off soak duration is rejected", "unstable Android screen-off endpoint identity remains pending", "stale Android screen-off soak review source commit is rejected", "Android screen-off soak evidence contract tests passed")

Test-TextEvidence `
  -Id "android-screen-off-soak-evidence-docs" `
  -Name "Android screen-off soak evidence docs" `
  -RelativePaths @("docs/ANDROID_COMPANION_TEST_PLAN.md") `
  -Patterns @("check_android_screen_off_soak_evidence.cmd", "ANDROID_SCREEN_OFF_SOAK_REVIEW.md", "android-screen-off-soak-ready", "Strict soak evidence gate")

Test-TextEvidence `
  -Id "voice-source-readiness-check" `
  -Name "Production voice-source readiness check" `
  -RelativePaths @("tools/check_voice_source_readiness.ps1") `
  -Patterns @("stackchan.voice-source-readiness.v1", "pending-production-voice-source", "production-voice-source-ready", "licensed_or_owned_production_voice_source", "rvc-candidate-rights-review", "voice-source-source-commit", "voice-source-provenance-commit-match", "voiceSourceCommit", "source_commit", "sourceCommit", "SourceCommit", "RequireProductionReady")

Test-TextEvidence `
  -Id "voice-source-readiness-contract" `
  -Name "Production voice-source readiness contract test" `
  -RelativePaths @("tools/test_voice_source_readiness_contract.ps1", "tools/test_voice_source_readiness_contract.cmd") `
  -Patterns @("pending production voice source remains pending", "complete production voice source is accepted", "fixed voice-source commit remains valid across later package commits", "missing production voice-source provenance commit is rejected", "unresolved RVC rights review prevents production voice-source readiness", "Voice source readiness contract tests passed")

Test-TextEvidence `
  -Id "ci-companion-tests" `
  -Name "Companion CI pre-arrival checks" `
  -RelativePaths @(".github/workflows/firmware.yml", "provenance/firmware.yml") `
  -Patterns @("workflow_dispatch", "github.event_name != 'workflow_dispatch'", "github.event_name == 'workflow_dispatch'", "companion-tests", "companion-android-emulator-smoke", "companion-platform-builds", "companion-release-evidence", "export_companion_release_evidence.ps1", "java-version: `"21`"", "python-version: `"3.12`"", "android-actions/setup-android", "platforms;android-36", "build-tools;36.0.0", "system-images;android-35;aosp_atd;x86_64", "ANDROID_AVD_HOME", "timeout 180 adb wait-for-device", "./gradlew check :app-desktop:c0Spike", ":app-android:bundleRelease", "stackchan.allowLabDebugReleaseSigning=true", "check_companion_release_version.ps1", "test_companion_release_version_contract.ps1", "check_android_play_release_readiness.ps1", "test_android_upload_signing_contract.ps1", "test_android_emulator_launch.ps1", "test_android_emulator_release_evidence_contract.ps1", "AndroidEmulatorEvidencePath", "RequireAndroidEmulatorEvidence", "test_desktop_package_evidence_contract.ps1", "test_desktop_package_launch.ps1", "prepare_desktop_python_runtime.ps1", "STACKCHAN_DESKTOP_PYTHON_RUNTIME_ROOT", "export_desktop_package_evidence.ps1", "RequireInstallerPayload", "RequireLaunchEvidence", "RequireDesktopPackageEvidence")

Test-TextEvidence `
  -Id "desktop-managed-runtime-native-package-matrix" `
  -Name "Desktop managed Python runtimes in native package matrix" `
  -RelativePaths @(".github/workflows/firmware.yml", ".github/workflows/release.yml") `
  -Patterns @("desktop-windows", "desktop-linux", "desktop-macos", "Prepare managed Python runtime for desktop package", "prepare_desktop_python_runtime.ps1", "STACKCHAN_DESKTOP_PYTHON_RUNTIME_ROOT", "Export native desktop package evidence", "export_desktop_package_evidence.ps1", "RequireInstallerPayload", "RequireLaunchEvidence", "windows-package-evidence.json", "linux-package-evidence.json", "macos-package-evidence.json")

Test-TextEvidence `
  -Id "companion-release-version-gate" `
  -Name "Companion cross-platform release version gate" `
  -RelativePaths @("tools/check_companion_release_version.ps1") `
  -Patterns @("stackchan.companion-release-version.v1", "ExpectedVersion", "versionName", "versionCode", "packageVersion", "CompanionIdentity.kt", "appVersion", "blocked-version-mismatch", "Tag/version mismatch")

Test-TextEvidence `
  -Id "companion-release-version-contract" `
  -Name "Companion release version contract test" `
  -RelativePaths @("tools/test_companion_release_version_contract.ps1", "tools/test_companion_release_version_contract.cmd") `
  -Patterns @("current companion declarations match", "mismatched release tag is rejected", "cross-platform version drift is rejected", "Companion release version contract tests passed")

Test-TextEvidence `
  -Id "companion-tag-release-workflow" `
  -Name "Companion all-platform tag release workflow" `
  -RelativePaths @(".github/workflows/release.yml") `
  -Patterns @("companion-android-release", "companion-android-emulator-smoke", "companion-desktop-release", "STACKCHAN_ANDROID_KEYSTORE_B64", "STACKCHAN_ANDROID_KEYSTORE_PASSWORD", "STACKCHAN_ANDROID_KEY_ALIAS", "STACKCHAN_ANDROID_KEY_PASSWORD", "STACKCHAN_WINDOWS_PFX_B64", "STACKCHAN_WINDOWS_PFX_PASSWORD", "STACKCHAN_MACOS_CERTIFICATE_B64", "STACKCHAN_MACOS_CERTIFICATE_PASSWORD", "STACKCHAN_MACOS_SIGNING_IDENTITY", "STACKCHAN_MACOS_NOTARIZATION_APPLE_ID", "STACKCHAN_MACOS_NOTARIZATION_PASSWORD", "STACKCHAN_MACOS_NOTARIZATION_TEAM_ID", "check_android_play_release_readiness.ps1 -RequireUploadSigning -Json", "check_desktop_release_signing_readiness.ps1", "Validate production desktop signing credentials", "RequireNativeToolchain", "ValidateAppleNotaryCredentials", "ANDROID_AVD_HOME", "timeout 180 adb wait-for-device", "test_android_emulator_launch.ps1", "AndroidEmulatorEvidencePath", "RequireAndroidEmulatorEvidence", "prepare_desktop_python_runtime.ps1", "test_desktop_package_launch.ps1", "export_desktop_package_evidence.ps1", "STACKCHAN_DESKTOP_PYTHON_RUNTIME_ROOT", "RequireInstallerPayload", "RequireLaunchEvidence", "RequireDistributionTrust", "RequireUploadSigning", "RequireDesktopPackageEvidence", "RequireDesktopDistributionTrust", ":app-desktop:notarizeDmg", "actions/attest@v4", "Get-ReleaseCompanionAssetEntries", "COMPANION_RELEASE_EVIDENCE.json")

Test-TextEvidence `
  -Id "companion-release-signing-evidence" `
  -Name "Companion release signing and native trust evidence" `
  -RelativePaths @("tools/export_companion_release_evidence.ps1") `
  -Patterns @("ApkSignerPath", "apksigner", "androidSigning", "android-release-apk-signature", "APK Signature Scheme v2", "androidBundleSigning", "android-release-aab-signature", "jarsigner", "RequireUploadSigning", "upload-key", "blocked-release-evidence", "blockingPending", "AndroidEmulatorEvidencePath", "RequireAndroidEmulatorEvidence", "androidEmulatorEvidenceRequired", "android-emulator-release-apk-evidence", "check_android_emulator_release_evidence.ps1", "DesktopPythonRuntimeRoot", "check_desktop_python_runtime_payload.ps1", "desktopPythonRuntime", "desktop-managed-python-runtime-payload", "DesktopPackageEvidenceRoot", "RequireDesktopPackageEvidence", "desktopPackageEvidenceRequired", "RequireDesktopDistributionTrust", "desktopDistributionTrustRequired", "distributionTrustStatus", "authenticode-sha256-timestamped", "developer-id-notarized-stapled", "installerAppJarSha256", "installerRuntimeSha256", "installerBrainFiles", "desktop-native-package-runtime-evidence", "desktop-native-distribution-trust")

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
  sourceCommit = Get-GitText @("rev-parse", "HEAD")
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
