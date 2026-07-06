package dev.stackchan.companion.android

import dev.stackchan.companion.core.BrainTurnRequest
import dev.stackchan.companion.core.BrainTurnSource
import dev.stackchan.companion.core.EndpointSessionSnapshot
import dev.stackchan.companion.core.SettingsRepository
import dev.stackchan.companion.core.TrustedEndpoint
import dev.stackchan.companion.core.defaultAndroidEndpointHello
import dev.stackchan.companion.ui.ConversationMessage
import java.nio.file.Files
import java.time.Instant
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Test

class AndroidBridgeRuntimeStatusTest {
    @Test
    fun androidGemmaChecksumUsesSha256() {
        val file = Files.createTempFile("stackchan-android-gemma-checksum", ".bin").toFile()
        file.writeText("stackchan")

        assertEquals(
            "4eee5709fc6b59a2545c6ef4b47b63a67b5f4a5c5c6015e9b574fda3e368330e",
            androidGemmaModelChecksum(file),
        )
    }

    @Test
    fun connectedRobotStatusFeedsOperatorLabels() {
        val status = AndroidBridgeRuntimeStatus(
            manualBridgeUrls = listOf("ws://192.168.1.42:8765/bridge"),
            serviceStatus = "Foreground",
            serviceDetail = "Bridge ready at ws://192.168.1.42:8765/bridge; session wake lock active",
            robotConnected = true,
            robotId = "stackchan-bench-01",
            robotName = "Stackchan Bench",
            firmwareVersion = "bench-v1",
            lastMessageType = "heartbeat",
            activeBrainOwner = "android-companion-c0",
        )

        assertEquals("ws://192.168.1.42:8765/bridge", status.primaryBridgeUrl)
        assertEquals("Stackchan Bench", status.robotDisplayName)
        assertEquals("bench-v1", status.robotFingerprint)
        assertEquals("heartbeat", status.robotState)
        assertEquals("Connected: Stackchan Bench", status.connectionLabel)
        assertEquals(
            "Robot Stackchan Bench last reported `heartbeat`; brain owner: android-companion-c0.",
            status.consoleMessage,
        )
    }

    @Test
    fun stoppedStatusDoesNotClaimBridgeReady() {
        val status = AndroidBridgeRuntimeStatus(
            manualBridgeUrls = listOf("ws://192.168.1.42:8765/bridge"),
            serviceStatus = "Stopped",
            serviceDetail = "Android bridge service stopped.",
        )

        assertEquals("Awaiting Stackchan robot", status.robotDisplayName)
        assertEquals("No robot hello yet", status.robotFingerprint)
        assertEquals("Bridge stopped", status.robotState)
        assertEquals("Bridge stopped: ws://192.168.1.42:8765/bridge", status.connectionLabel)
    }

    @Test
    fun failedStatusDoesNotClaimStaleRobotConnection() {
        val status = AndroidBridgeRuntimeStatus(
            manualBridgeUrls = listOf("ws://192.168.1.42:8765/bridge"),
            serviceStatus = "Failed",
            serviceDetail = "Bridge failed: port already in use",
            robotConnected = true,
            robotId = "stackchan-bench-01",
            robotName = "Stackchan Bench",
            firmwareVersion = "bench-v1",
            lastMessageType = "heartbeat",
            activeBrainOwner = "phone-rob-01",
        )

        assertEquals("Bridge failed", status.robotState)
        assertEquals("Bridge failed: ws://192.168.1.42:8765/bridge", status.connectionLabel)
        assertEquals("Bridge failed: port already in use", status.consoleMessage)
    }

    @Test
    fun startingStatusDoesNotClaimBridgeReady() {
        val status = AndroidBridgeRuntimeStatus(
            manualBridgeUrls = listOf("ws://192.168.1.42:8765/bridge"),
            serviceStatus = "Starting",
            serviceDetail = "Starting bridge at ws://192.168.1.42:8765/bridge",
            robotConnected = true,
            robotId = "stackchan-bench-01",
            robotName = "Stackchan Bench",
            firmwareVersion = "bench-v1",
            lastMessageType = "heartbeat",
        )

        assertEquals("Bridge starting", status.robotState)
        assertEquals("Bridge starting: ws://192.168.1.42:8765/bridge", status.connectionLabel)
        assertEquals("Starting bridge at ws://192.168.1.42:8765/bridge", status.consoleMessage)
    }

    @Test
    fun serviceFailureClearsPreviousRobotSession() {
        AndroidBridgeRuntimeStatusStore.updateSession(
            snapshot = EndpointSessionSnapshot(
                connected = true,
                robotHelloReceived = true,
                deviceId = "stackchan-bench-01",
                deviceName = "Stackchan Bench",
                firmwareVersion = "bench-v1",
                activeBrainOwner = "phone-rob-01",
                lastMessageType = "heartbeat",
            ),
            detail = "Bridge ready at ws://192.168.1.42:8765/bridge; session wake lock active",
        )

        AndroidBridgeRuntimeStatusStore.setServiceStatus("Failed", "Bridge failed: port already in use")

        val status = AndroidBridgeRuntimeStatusStore.status.value
        assertFalse(status.robotSocketConnected)
        assertFalse(status.robotConnected)
        assertEquals("", status.robotId)
        assertEquals("", status.robotName)
        assertEquals("", status.firmwareVersion)
        assertEquals("", status.lastMessageType)
        assertEquals("", status.activeBrainOwner)
        assertEquals("Bridge failed", status.robotState)
    }

    @Test
    fun socketConnectionDoesNotMarkRobotConnectedBeforeHello() {
        AndroidBridgeRuntimeStatusStore.setServiceStatus(
            "Foreground",
            "Bridge ready at ws://192.168.1.42:8765/bridge; waiting for robot session",
        )
        AndroidBridgeRuntimeStatusStore.updateSession(
            snapshot = EndpointSessionSnapshot(
                connected = true,
                robotHelloReceived = false,
                lastMessageType = "",
            ),
            detail = "Bridge ready at ws://192.168.1.42:8765/bridge; waiting for robot hello",
        )

        val status = AndroidBridgeRuntimeStatusStore.status.value

        assertTrue(status.robotSocketConnected)
        assertFalse(status.robotConnected)
        assertEquals("Awaiting robot hello", status.robotState)
        assertEquals("Robot detected: waiting for hello", status.connectionLabel)
        assertTrue(status.consoleMessage.contains("Waiting for robot hello"))
    }

    @Test
    fun androidUiStateUsesBridgeServiceOperatorLabels() {
        val uiState = androidCompanionUiState(
            endpointHello = defaultAndroidEndpointHello(endpointId = "phone-rob-01"),
            trustedEndpoints = emptyList(),
            bridgeStatus = AndroidBridgeRuntimeStatus(
                manualBridgeUrls = listOf("ws://192.168.1.42:8765/bridge"),
                serviceStatus = "Foreground",
                serviceDetail = "Bridge ready at ws://192.168.1.42:8765/bridge; waiting for robot session",
            ),
        )

        assertEquals("Android Bridge Service", uiState.brainService.panelTitle)
        assertEquals("Stop bridge", uiState.brainService.primaryActionRunningLabel)
        assertEquals("Start bridge", uiState.brainService.primaryActionStoppedLabel)
        assertEquals("Restart bridge", uiState.brainService.restartActionLabel)
        assertEquals("CompanionBridgeService", uiState.brainService.command)
        assertEquals("ws://192.168.1.42:8765/bridge", uiState.brainService.endpoint)
        assertFalse(uiState.brainService.showBrainHandoffActions)
        assertFalse(uiState.conversation.inputEnabled)
        assertTrue(uiState.conversation.status.contains("Connect Stack-chan"))
    }

    @Test
    fun androidUiStateUsesLiveBridgeTelemetryInsteadOfDemoDefaults() {
        val uiState = androidCompanionUiState(
            endpointHello = defaultAndroidEndpointHello(endpointId = "phone-rob-01"),
            trustedEndpoints = emptyList(),
            bridgeStatus = AndroidBridgeRuntimeStatus(
                manualBridgeUrls = listOf("ws://192.168.1.42:8765/bridge"),
                serviceStatus = "Foreground",
                serviceDetail = "Bridge ready at ws://192.168.1.42:8765/bridge; session wake lock active",
                robotConnected = true,
                robotId = "stackchan-bench-01",
                robotName = "Stackchan Bench",
                firmwareVersion = "bench-v1",
                lastMessageType = "heartbeat",
                activeBrainOwner = "phone-rob-01",
            ),
        )

        assertFalse(uiState.servoArmed)
        assertEquals("spark", uiState.activePersona)
        assertEquals("Heartbeat: received", uiState.heartbeatStatus)
        assertEquals("Bridge connected; no live meter", uiState.audioStatus)
        assertEquals("Stackchan Bench", uiState.telemetry.first { it.label == "Robot" }.value)
        assertEquals("bench-v1", uiState.telemetry.first { it.label == "Firmware" }.value)
        assertEquals("heartbeat", uiState.telemetry.first { it.label == "Last frame" }.value)
        assertEquals("Foreground", uiState.telemetry.first { it.label == "Service" }.value)
        assertFalse(uiState.heartbeatStatus.contains("8ms"))
        assertTrue(uiState.telemetry.none { it.value == "87%" || it.value == "42.5 C" || it.value == "v3.1.0" })
        assertTrue(uiState.conversation.inputEnabled)
        assertTrue(uiState.conversation.status.contains("Connected to Stackchan Bench"))
    }

    @Test
    fun androidConnectedDashboardStateContainsArrivalDayEvidenceFields() {
        val endpointHello = defaultAndroidEndpointHello(endpointId = "phone-rob-01")
        val uiState = androidCompanionUiState(
            endpointHello = endpointHello,
            trustedEndpoints = emptyList(),
            bridgeStatus = AndroidBridgeRuntimeStatus(
                manualBridgeUrls = listOf(
                    "ws://192.168.1.42:8765/bridge",
                    "ws://10.0.0.42:8765/bridge",
                ),
                serviceStatus = "Foreground",
                serviceDetail = "Bridge ready at ws://192.168.1.42:8765/bridge; session wake lock active",
                robotConnected = true,
                robotId = "stackchan-bench-01",
                robotName = "Stackchan Bench",
                firmwareVersion = "bench-v1",
                lastMessageType = "heartbeat",
                activeBrainOwner = "phone-rob-01",
            ),
        )

        assertEquals("Connected: Stackchan Bench", uiState.connection)
        assertEquals("phone-rob-01", uiState.brainOwner)
        assertEquals("ws://192.168.1.42:8765/bridge", uiState.brainService.endpoint)
        assertEquals("Foreground", uiState.brainService.status)
        assertEquals("Stackchan Bench", uiState.telemetry.first { it.label == "Robot" }.value)
        assertEquals("bench-v1", uiState.telemetry.first { it.label == "Firmware" }.value)
        assertEquals("heartbeat", uiState.telemetry.first { it.label == "Last frame" }.value)
        assertEquals("Foreground", uiState.telemetry.first { it.label == "Service" }.value)
        assertTrue(uiState.brainService.recentLogs.any { it == "Manual fallback URL: ws://192.168.1.42:8765/bridge" })
        assertTrue(uiState.brainService.recentLogs.any { it == "Other LAN URLs: ws://10.0.0.42:8765/bridge" })
        assertTrue(uiState.brainService.recentLogs.any { it == "Robot: Stackchan Bench / bench-v1" })
        assertTrue(uiState.brainService.recentLogs.any { it == "Last bridge frame: heartbeat" })
        assertTrue(uiState.brainService.recentLogs.any { it == "Brain owner: phone-rob-01" })
        assertTrue(uiState.brainService.recentLogs.any { it.contains("Android NSD advertises _stackchan-bridge._tcp.local") })
        assertTrue(uiState.brainService.recentLogs.any { it.contains("UDP beacon broadcasts endpoint metadata") })

        val robotRow = uiState.endpoints.first { it.kind == "robot" }
        assertEquals("Stackchan Bench", robotRow.name)
        assertEquals("bench-v1", robotRow.fingerprint)
        assertTrue(robotRow.connected)

        val phoneRow = uiState.endpoints.first { it.kind == "android" }
        assertEquals("${endpointHello.endpointName} (This Phone)", phoneRow.name)
        assertEquals("phone-rob-01", phoneRow.fingerprint)
        assertTrue(phoneRow.connected)
        assertTrue(phoneRow.activeBrain)
    }

    @Test
    fun androidUiStateExposesFriendlyStackchanSetupState() {
        val uiState = androidCompanionUiState(
            endpointHello = defaultAndroidEndpointHello(endpointId = "phone-rob-01"),
            trustedEndpoints = emptyList(),
            bridgeStatus = AndroidBridgeRuntimeStatus(
                manualBridgeUrls = listOf(
                    "ws://192.168.1.42:8765/bridge",
                    "ws://10.0.0.42:8765/bridge",
                ),
                serviceStatus = "Foreground",
                serviceDetail = "Bridge ready at ws://192.168.1.42:8765/bridge; waiting for robot session",
            ),
        )

        assertEquals("ws://192.168.1.42:8765/bridge", uiState.robotSetup.primaryBridgeUrl)
        assertEquals(listOf("ws://10.0.0.42:8765/bridge"), uiState.robotSetup.otherBridgeUrls)
        assertTrue(uiState.robotSetup.serviceRunning)
        assertFalse(uiState.robotSetup.robotConnected)
        assertEquals("Awaiting Stackchan robot", uiState.robotSetup.robotName)
        assertEquals("Add your Stack-chan", uiState.robotSetup.setupTitle)
        assertTrue(uiState.robotSetup.setupStatus.contains("Bridge is ready"))
        assertEquals("Pair on Stack-chan", uiState.robotSetup.nextActionTitle)
        assertTrue(uiState.robotSetup.nextActionDetail.contains("ws://192.168.1.42:8765/bridge"))
        assertTrue(uiState.robotSetup.nextActionDetail.contains(uiState.robotSetup.pairingShortCode))
        assertEquals(6, uiState.robotSetup.pairingShortCode.length)
        assertTrue(uiState.robotSetup.pairingFingerprint.startsWith("sha256:"))
        assertTrue(uiState.robotSetup.pairingQrPayload.startsWith("stackchan://pair?"))
        assertTrue(uiState.robotSetup.pairingQrPayload.contains("bridge=ws%3A%2F%2F192.168.1.42%3A8765%2Fbridge"))
        assertTrue(uiState.robotSetup.pairingQrPayload.contains("code=${uiState.robotSetup.pairingShortCode}"))
        assertTrue(uiState.robotSetup.pairingQrPayload.contains("fingerprint=sha256%3A"))
        assertTrue(uiState.robotSetup.pairingQrPayload.contains("endpoint_id=phone-rob-01"))
        assertTrue(uiState.robotSetup.pairingInstruction.contains("pairing code"))
        assertTrue(uiState.robotSetup.wifiStatus.contains("Wi-Fi is active"))
        assertTrue(uiState.robotSetup.wifiInstruction.contains("mDNS"))
        assertTrue(uiState.robotSetup.wifiProvisioningSummary.contains("robot serial console"))
        assertEquals(
            "wifi set ssid \"<network-name>\" pass \"<network-password>\" url \"ws://192.168.1.42:8765/bridge\"",
            uiState.robotSetup.wifiProvisioningCommand,
        )
        assertEquals("wifi clear", uiState.robotSetup.wifiClearCommand)
        assertTrue(uiState.robotSetup.removalGuidance.contains("After first pairing"))
        assertEquals(0, uiState.robotSetup.trustedCompanionCount)
        assertEquals(0, uiState.robotSetup.savedRobotCount)
        assertEquals(4, uiState.robotSetup.steps.size)
        assertTrue(uiState.robotSetup.steps[0].completed)
        assertFalse(uiState.robotSetup.steps[0].current)
        assertTrue(uiState.robotSetup.steps[1].completed)
        assertFalse(uiState.robotSetup.steps[1].current)
        assertFalse(uiState.robotSetup.steps[2].completed)
        assertTrue(uiState.robotSetup.steps[2].current)
        assertFalse(uiState.robotSetup.steps[3].completed)
    }

    @Test
    fun androidUiStateShowsWifiBootstrapBeforePairingWhenWifiIsOff() {
        val uiState = androidCompanionUiState(
            endpointHello = defaultAndroidEndpointHello(endpointId = "phone-rob-01"),
            trustedEndpoints = emptyList(),
            bridgeStatus = AndroidBridgeRuntimeStatus(
                manualBridgeUrls = listOf("ws://192.168.1.42:8765/bridge"),
                serviceStatus = "Stopped",
                serviceDetail = "Bridge stopped",
            ),
            wifiConnected = false,
        )

        assertTrue(uiState.robotSetup.wifiStatus.contains("not active"))
        assertTrue(uiState.robotSetup.wifiInstruction.contains("Open Wi-Fi settings"))
        assertEquals("Open Wi-Fi settings", uiState.robotSetup.wifiActionLabel)
        assertTrue(uiState.robotSetup.wifiActionEnabled)
        assertEquals("", uiState.robotSetup.wifiProvisioningCommand)
        assertEquals("", uiState.robotSetup.pairingQrPayload)
        assertEquals(4, uiState.robotSetup.steps.size)
        assertEquals("Join Wi-Fi", uiState.robotSetup.steps[0].label)
        assertFalse(uiState.robotSetup.steps[0].completed)
        assertTrue(uiState.robotSetup.steps[0].current)
        assertFalse(uiState.robotSetup.steps[1].current)
    }

    @Test
    fun androidUiStateMarksSetupCompleteWhenRobotHelloArrives() {
        val uiState = androidCompanionUiState(
            endpointHello = defaultAndroidEndpointHello(endpointId = "phone-rob-01"),
            trustedEndpoints = emptyList(),
            bridgeStatus = AndroidBridgeRuntimeStatus(
                manualBridgeUrls = listOf("ws://192.168.1.42:8765/bridge"),
                serviceStatus = "Foreground",
                serviceDetail = "Bridge ready at ws://192.168.1.42:8765/bridge; session wake lock active",
                robotSocketConnected = true,
                robotConnected = true,
                robotId = "stackchan-bench-01",
                robotName = "Stackchan Bench",
                firmwareVersion = "bench-v1",
                lastMessageType = "heartbeat",
            ),
        )

        assertTrue(uiState.robotSetup.robotConnected)
        assertTrue(uiState.robotSetup.setupStatus.contains("Stackchan Bench is connected"))
        assertEquals("Ready to test", uiState.robotSetup.nextActionTitle)
        assertTrue(uiState.robotSetup.nextActionDetail.contains("Open Talk"))
        assertTrue(uiState.robotSetup.pairingInstruction.contains("saved"))
        assertTrue(uiState.robotSetup.steps.all { it.completed })
        assertTrue(uiState.robotSetup.steps.last().current)
        assertTrue(uiState.endpoints.first { it.kind == "robot" }.connected)
    }

    @Test
    fun androidUiStateShowsRobotDetectedBeforeHello() {
        val uiState = androidCompanionUiState(
            endpointHello = defaultAndroidEndpointHello(endpointId = "phone-rob-01"),
            trustedEndpoints = emptyList(),
            bridgeStatus = AndroidBridgeRuntimeStatus(
                manualBridgeUrls = listOf("ws://192.168.1.42:8765/bridge"),
                serviceStatus = "Foreground",
                serviceDetail = "Bridge ready at ws://192.168.1.42:8765/bridge; waiting for robot hello",
                robotSocketConnected = true,
            ),
        )

        assertFalse(uiState.robotSetup.robotConnected)
        assertEquals("Finish Stack-chan pairing", uiState.robotSetup.setupTitle)
        assertTrue(uiState.robotSetup.setupStatus.contains("Waiting for the bridge hello"))
        assertEquals("Stackchan detected", uiState.robotSetup.robotName)
        assertEquals("Bridge socket open; no robot hello yet", uiState.robotSetup.robotFingerprint)
        assertTrue(uiState.robotSetup.steps[2].completed)
        assertFalse(uiState.robotSetup.steps[2].current)
        assertFalse(uiState.robotSetup.steps[3].completed)
        assertTrue(uiState.robotSetup.steps[3].current)
        assertEquals("Confirm the robot hello", uiState.robotSetup.nextActionTitle)
        assertTrue(uiState.robotSetup.nextActionDetail.contains("wait for firmware to send hello"))
        assertTrue(uiState.robotSetup.pairingInstruction.contains("Confirm"))
        assertEquals("Robot detected: waiting for hello", uiState.connection)
        assertTrue(uiState.consoleMessage.contains("Waiting for robot hello"))
        assertEquals("Waiting for hello", uiState.telemetry.first { it.label == "Robot" }.detail)
    }

    @Test
    fun androidUiStateShowsTextTurnConversationStatus() {
        val uiState = androidCompanionUiState(
            endpointHello = defaultAndroidEndpointHello(endpointId = "phone-rob-01"),
            trustedEndpoints = emptyList(),
            conversationMessages = listOf(
                ConversationMessage("You", "Hello Stack-chan", "Sent"),
                ConversationMessage("Bridge", "Hello Stack-chan", "Sent seq 10001"),
            ),
            bridgeStatus = AndroidBridgeRuntimeStatus(
                manualBridgeUrls = listOf("ws://192.168.1.42:8765/bridge"),
                serviceStatus = "Foreground",
                serviceDetail = "Bridge ready at ws://192.168.1.42:8765/bridge; session wake lock active",
                robotSocketConnected = true,
                robotConnected = true,
                robotId = "stackchan-bench-01",
                robotName = "Stackchan Bench",
                firmwareVersion = "bench-v1",
                lastMessageType = "app_text_turn",
                textTurnsSubmitted = 1,
                lastTextTurn = "Hello Stack-chan",
            ),
        )

        assertTrue(uiState.conversation.inputEnabled)
        assertTrue(uiState.conversation.status.contains("Text turns sent: 1"))
        assertEquals("Hello Stack-chan", uiState.conversation.messages.last().text)
    }

    @Test
    fun androidUiStateEnablesPushToTalkWhenSpeechRecognizerAndRobotAreReady() {
        val uiState = androidCompanionUiState(
            endpointHello = defaultAndroidEndpointHello(endpointId = "phone-rob-01"),
            trustedEndpoints = emptyList(),
            bridgeStatus = AndroidBridgeRuntimeStatus(
                manualBridgeUrls = listOf("ws://192.168.1.42:8765/bridge"),
                serviceStatus = "Foreground",
                serviceDetail = "Bridge ready at ws://192.168.1.42:8765/bridge; session wake lock active",
                robotSocketConnected = true,
                robotConnected = true,
                robotId = "stackchan-bench-01",
                robotName = "Stackchan Bench",
                firmwareVersion = "bench-v1",
            ),
            pushToTalkAvailable = true,
            pushToTalkPermissionGranted = true,
            pushToTalkStatus = "Microphone turns use Android speech recognition.",
        )

        assertTrue(uiState.conversation.inputEnabled)
        assertTrue(uiState.conversation.pushToTalkEnabled)
        assertEquals("Push-to-talk", uiState.conversation.pushToTalkLabel)
        assertEquals(
            "Microphone turns use Android speech recognition.",
            uiState.conversation.pushToTalkStatus,
        )
    }

    @Test
    fun androidUiStatePromptsForMicrophonePermissionBeforePushToTalk() {
        val uiState = androidCompanionUiState(
            endpointHello = defaultAndroidEndpointHello(endpointId = "phone-rob-01"),
            trustedEndpoints = emptyList(),
            bridgeStatus = AndroidBridgeRuntimeStatus(
                manualBridgeUrls = listOf("ws://192.168.1.42:8765/bridge"),
                serviceStatus = "Foreground",
                serviceDetail = "Bridge ready at ws://192.168.1.42:8765/bridge; session wake lock active",
                robotSocketConnected = true,
                robotConnected = true,
                robotId = "stackchan-bench-01",
            ),
            pushToTalkAvailable = true,
            pushToTalkPermissionGranted = false,
            pushToTalkPermissionDenied = false,
            pushToTalkStatus = "Microphone turns use Android speech recognition.",
        )

        assertTrue(uiState.conversation.pushToTalkEnabled)
        assertEquals("Allow mic", uiState.conversation.pushToTalkLabel)
        assertTrue(uiState.conversation.pushToTalkStatus.contains("approve microphone access"))
        assertTrue(uiState.conversation.pushToTalkStatus.contains("Denied turns are not sent"))
    }

    @Test
    fun androidUiStateExplainsMicrophonePermissionDenialAndRetry() {
        val uiState = androidCompanionUiState(
            endpointHello = defaultAndroidEndpointHello(endpointId = "phone-rob-01"),
            trustedEndpoints = emptyList(),
            bridgeStatus = AndroidBridgeRuntimeStatus(
                manualBridgeUrls = listOf("ws://192.168.1.42:8765/bridge"),
                serviceStatus = "Foreground",
                serviceDetail = "Bridge ready at ws://192.168.1.42:8765/bridge; session wake lock active",
                robotSocketConnected = true,
                robotConnected = true,
                robotId = "stackchan-bench-01",
            ),
            pushToTalkAvailable = true,
            pushToTalkPermissionGranted = false,
            pushToTalkPermissionDenied = true,
            pushToTalkStatus = "Microphone turns use Android speech recognition.",
        )

        assertTrue(uiState.conversation.pushToTalkEnabled)
        assertEquals("Allow mic", uiState.conversation.pushToTalkLabel)
        assertEquals(
            "Microphone permission denied. Enable it in Android app settings, then retry. No transcript was sent.",
            uiState.conversation.pushToTalkStatus,
        )
    }

    @Test
    fun androidUiStateKeepsPushToTalkDisabledUntilRobotHello() {
        val uiState = androidCompanionUiState(
            endpointHello = defaultAndroidEndpointHello(endpointId = "phone-rob-01"),
            trustedEndpoints = emptyList(),
            bridgeStatus = AndroidBridgeRuntimeStatus(
                manualBridgeUrls = listOf("ws://192.168.1.42:8765/bridge"),
                serviceStatus = "Foreground",
                serviceDetail = "Bridge ready at ws://192.168.1.42:8765/bridge; waiting for robot hello",
                robotSocketConnected = true,
            ),
            pushToTalkAvailable = true,
        )

        assertFalse(uiState.conversation.inputEnabled)
        assertFalse(uiState.conversation.pushToTalkEnabled)
        assertEquals("Push-to-talk", uiState.conversation.pushToTalkLabel)
    }

    @Test
    fun androidUiStateLabelsPushToTalkUnavailableWithoutSpeechRecognizer() {
        val uiState = androidCompanionUiState(
            endpointHello = defaultAndroidEndpointHello(endpointId = "phone-rob-01"),
            trustedEndpoints = emptyList(),
            bridgeStatus = AndroidBridgeRuntimeStatus(
                manualBridgeUrls = listOf("ws://192.168.1.42:8765/bridge"),
                serviceStatus = "Foreground",
                serviceDetail = "Bridge ready at ws://192.168.1.42:8765/bridge; session wake lock active",
                robotSocketConnected = true,
                robotConnected = true,
                robotId = "stackchan-bench-01",
            ),
            pushToTalkAvailable = false,
        )

        assertTrue(uiState.conversation.inputEnabled)
        assertFalse(uiState.conversation.pushToTalkEnabled)
        assertEquals("Mic unavailable", uiState.conversation.pushToTalkLabel)
        assertTrue(uiState.conversation.pushToTalkStatus.contains("Android speech recognition is unavailable"))
    }

    @Test
    fun androidUiStateMarksStoredCompanionsRemovable() {
        val trusted = TrustedEndpoint(
            endpointId = "studio-mac-01",
            endpointName = "Studio Mac",
            endpointKind = "pc",
            publicKeyFingerprint = "sha256:abcdef0123456789",
            priority = 90,
            capabilities = listOf("settings", "diagnostics"),
        )
        val uiState = androidCompanionUiState(
            endpointHello = defaultAndroidEndpointHello(endpointId = "phone-rob-01"),
            trustedEndpoints = listOf(trusted),
            bridgeStatus = AndroidBridgeRuntimeStatus(
                manualBridgeUrls = listOf("ws://192.168.1.42:8765/bridge"),
                serviceStatus = "Foreground",
                serviceDetail = "Bridge ready at ws://192.168.1.42:8765/bridge; waiting for robot session",
            ),
        )

        val storedEndpoint = uiState.endpoints.first { it.endpointId == "studio-mac-01" }
        assertEquals("Studio Mac", storedEndpoint.name)
        assertTrue(storedEndpoint.removable)
        assertEquals(1, uiState.robotSetup.trustedCompanionCount)
        assertFalse(uiState.endpoints.first { it.kind == "android" }.removable)
        assertFalse(uiState.endpoints.first { it.kind == "robot" }.removable)
    }

    @Test
    fun androidUiStateExposesSettingsDiagnosticsAndHandoffSurfaces() {
        val settings = SettingsRepository()
        val uiState = androidCompanionUiState(
            endpointHello = defaultAndroidEndpointHello(endpointId = "phone-rob-01"),
            settingsRepository = settings,
            trustedEndpoints = listOf(
                TrustedEndpoint(
                    endpointId = "studio-mac-01",
                    endpointName = "Studio Mac",
                    endpointKind = "pc",
                    publicKeyFingerprint = "sha256:abcdef0123456789",
                    priority = 90,
                    capabilities = listOf("settings", "diagnostics", "brain_owner"),
                ),
            ),
            bridgeStatus = AndroidBridgeRuntimeStatus(
                manualBridgeUrls = listOf("ws://192.168.1.42:8765/bridge"),
                serviceStatus = "Foreground",
                serviceDetail = "Bridge ready at ws://192.168.1.42:8765/bridge; session wake lock active",
                robotSocketConnected = true,
                robotConnected = true,
                robotId = "stackchan-bench-01",
                robotName = "Stackchan Bench",
                firmwareVersion = "bench-v1",
                lastMessageType = "heartbeat",
                activeBrainOwner = "studio-mac-01",
            ),
        )

        assertEquals("spark", uiState.activePersona)
        assertEquals("spark", uiState.settingsSurface.activePersona)
        assertEquals("review_synth", uiState.settingsSurface.voiceProfile)
        assertEquals("80", uiState.settingsSurface.displayBrightness)
        assertTrue(uiState.settingsSurface.writesEnabled)
        assertTrue(uiState.settingsSurface.writeStatus.contains("Safe local settings"))

        assertEquals("Gemma-4-E2B", uiState.modelAsset.modelId)
        assertEquals("LiteRT-LM", uiState.modelAsset.runtime)
        assertEquals("2.58 GB", uiState.modelAsset.sizeLabel)
        assertTrue(uiState.modelAsset.sourceUrl.contains("ai.google.dev/edge/litert-lm/models/gemma-4"))
        assertTrue(uiState.modelAsset.downloadStatus.contains("LiteRT-LM"))
        assertTrue(uiState.modelAsset.downloadEnabled)
        assertFalse(uiState.modelAsset.loadEnabled)
        assertFalse(uiState.modelAsset.ejectEnabled)

        assertEquals("spark", uiState.personaLibrary.activePersona)
        assertTrue(uiState.personaLibrary.installedPersonas.contains("glow"))
        assertTrue(uiState.personaLibrary.importStatus.contains("stackchan.persona-pack.v1"))
        assertTrue(uiState.personaLibrary.exportStatus.contains("active persona pack"))
        assertTrue(uiState.personaLibrary.importEnabled)
        assertTrue(uiState.personaLibrary.exportEnabled)

        assertEquals("stackchan.bridge.v1", uiState.diagnosticsSurface.protocol)
        assertEquals("v1", uiState.diagnosticsSurface.settingsVersion)
        assertEquals("1", uiState.diagnosticsSurface.trustedEndpointCount)
        assertEquals("bridge", uiState.diagnosticsSurface.audioEngine)
        assertEquals("fake", uiState.diagnosticsSurface.modelProfile)
        assertEquals("bench-v1", uiState.diagnosticsSurface.firmwareTarget)

        assertEquals("studio-mac-01", uiState.handoffSurface.owner)
        assertEquals("pc", uiState.handoffSurface.ownerKind)
        assertEquals("active", uiState.handoffSurface.state)
        assertTrue(uiState.handoffSurface.claimEnabled)
        assertFalse(uiState.handoffSurface.releaseEnabled)
        assertTrue(uiState.handoffSurface.status.contains("owner_status"))
    }

    @Test
    fun androidUiStateEnablesBrainReleaseWhenPhoneOwnsBrain() {
        val uiState = androidCompanionUiState(
            endpointHello = defaultAndroidEndpointHello(endpointId = "phone-rob-01"),
            trustedEndpoints = emptyList(),
            bridgeStatus = AndroidBridgeRuntimeStatus(
                manualBridgeUrls = listOf("ws://192.168.1.42:8765/bridge"),
                serviceStatus = "Foreground",
                serviceDetail = "Bridge ready at ws://192.168.1.42:8765/bridge",
                robotSocketConnected = true,
                robotConnected = true,
                robotId = "stackchan-bench-01",
                robotName = "Stackchan Bench",
                firmwareVersion = "bench-v1",
                activeBrainOwner = "phone-rob-01",
            ),
        )

        assertFalse(uiState.handoffSurface.claimEnabled)
        assertTrue(uiState.handoffSurface.releaseEnabled)
        assertEquals("phone-rob-01", uiState.handoffSurface.owner)
        assertEquals("android", uiState.handoffSurface.ownerKind)
    }

    @Test
    fun androidUiStateProjectsModelAndPersonaAssetStatus() {
        val uiState = androidCompanionUiState(
            endpointHello = defaultAndroidEndpointHello(endpointId = "phone-rob-01"),
            trustedEndpoints = emptyList(),
            bridgeStatus = AndroidBridgeRuntimeStatus(
                manualBridgeUrls = listOf("ws://192.168.1.42:8765/bridge"),
                serviceStatus = "Foreground",
                serviceDetail = "Bridge ready at ws://192.168.1.42:8765/bridge",
            ),
            modelAssetStatus = AndroidModelAssetStatus(
                localPath = "/storage/emulated/0/Android/data/dev.stackchan.companion/files/Download/models/gemma-4-E2B-it.litertlm",
                downloaded = true,
                loaded = true,
                downloadId = 42,
                checksumVerified = true,
            ),
            personaLibraryStatus = AndroidPersonaLibraryStatus(
                installedPersonas = listOf("glow", "nova", "spark"),
                importStatus = "Imported persona `nova`.",
                exportStatus = "Exported imported persona `nova`.",
            ),
        )

        assertFalse(uiState.modelAsset.downloadEnabled)
        assertFalse(uiState.modelAsset.loadEnabled)
        assertTrue(uiState.modelAsset.ejectEnabled)
        assertTrue(uiState.modelAsset.settingsEnabled)
        assertTrue(uiState.modelAsset.localPath.contains("gemma-4-E2B-it.litertlm"))
        assertTrue(uiState.modelAsset.downloadStatus.contains("SHA-256 verified"))
        assertTrue(uiState.modelAsset.loadStatus.contains("SHA-256 verified asset staged"))
        assertTrue(uiState.modelAsset.settingsSummary.contains("runtime validation"))
        assertTrue(uiState.personaLibrary.installedPersonas.contains("nova"))
        assertTrue(uiState.personaLibrary.importEnabled)
        assertTrue(uiState.personaLibrary.exportEnabled)
    }

    @Test
    fun androidUiStateRequiresLoadForGemmaChecksumVerification() {
        val uiState = androidCompanionUiState(
            endpointHello = defaultAndroidEndpointHello(endpointId = "phone-rob-01"),
            trustedEndpoints = emptyList(),
            bridgeStatus = AndroidBridgeRuntimeStatus(
                manualBridgeUrls = listOf("ws://192.168.1.42:8765/bridge"),
                serviceStatus = "Foreground",
                serviceDetail = "Bridge ready at ws://192.168.1.42:8765/bridge",
            ),
            modelAssetStatus = AndroidModelAssetStatus(
                localPath = "/storage/emulated/0/Android/data/dev.stackchan.companion/files/Download/models/gemma-4-E2B-it.litertlm",
                bytes = 2_588_147_712L,
                downloaded = true,
                loaded = false,
                downloadId = null,
                checksumVerified = false,
            ),
        )

        assertFalse(uiState.modelAsset.downloadEnabled)
        assertTrue(uiState.modelAsset.loadEnabled)
        assertFalse(uiState.modelAsset.ejectEnabled)
        assertTrue(uiState.modelAsset.downloadStatus.contains("Load verifies SHA-256"))
        assertTrue(uiState.modelAsset.loadStatus.contains("verify SHA-256"))
    }

    @Test
    fun stagedGemmaAssetSelectsTransparentPendingLiteRtBrainEngine() = runBlocking {
        val engine = androidBrainTurnEngine(
            AndroidModelAssetStatus(
                localPath = "/storage/emulated/0/Android/data/dev.stackchan.companion/files/Download/models/gemma-4-E2B-it.litertlm",
                bytes = 2_588_147_712L,
                downloaded = true,
                loaded = true,
                downloadId = null,
            ),
        )

        val response = engine.respond(
            BrainTurnRequest(
                seq = 81,
                text = "hello stackchan",
                source = BrainTurnSource.APP_TEXT,
            ),
        )

        assertEquals("mobile_brain_staged_pending_litert", response.intent)
        assertTrue(response.text.contains("Gemma-4-E2B asset is staged"))
        assertTrue(response.text.contains("LiteRT runtime inference is not validated"))
        assertTrue(response.text.contains("hello stackchan"))
    }

    @Test
    fun androidUiStateShowsSavedRobotsAsRemovable() {
        val currentRobot = SavedRobot(
            robotId = "stackchan-bench-01",
            robotName = "Stackchan Bench",
            firmwareVersion = "bench-v1",
            fingerprint = "bench-v1",
            lastBridgeUrl = "ws://192.168.1.42:8765/bridge",
            lastSeenMs = 2000,
        )
        val previousRobot = SavedRobot(
            robotId = "stackchan-old-01",
            robotName = "Old Stackchan",
            firmwareVersion = "old-v1",
            fingerprint = "old-v1",
            lastBridgeUrl = "ws://192.168.1.50:8765/bridge",
            lastSeenMs = 1000,
        )
        val uiState = androidCompanionUiState(
            endpointHello = defaultAndroidEndpointHello(endpointId = "phone-rob-01"),
            trustedEndpoints = emptyList(),
            savedRobots = listOf(currentRobot, previousRobot),
            bridgeStatus = AndroidBridgeRuntimeStatus(
                manualBridgeUrls = listOf("ws://192.168.1.42:8765/bridge"),
                serviceStatus = "Foreground",
                serviceDetail = "Bridge ready at ws://192.168.1.42:8765/bridge; session wake lock active",
                robotSocketConnected = true,
                robotConnected = true,
                robotId = "stackchan-bench-01",
                robotName = "Stackchan Bench",
                firmwareVersion = "bench-v1",
            ),
        )

        assertEquals(2, uiState.robotSetup.savedRobotCount)
        assertTrue(uiState.robotSetup.removalGuidance.contains("Forget on saved robot rows"))
        assertTrue(uiState.robotSetup.removalGuidance.contains("Remove on companion rows"))
        val currentRow = uiState.endpoints.first { it.endpointId == "stackchan-bench-01" }
        assertTrue(currentRow.connected)
        assertTrue(currentRow.removable)

        val previousRow = uiState.endpoints.first { it.endpointId == "stackchan-old-01" }
        assertFalse(previousRow.connected)
        assertTrue(previousRow.removable)
        assertEquals("Old Stackchan", previousRow.name)
    }

    @Test
    fun androidDiagnosticsExportRedactsTextTurnAndIncludesBridgeState() {
        val endpointHello = defaultAndroidEndpointHello(
            endpointId = "phone-rob-01",
            pairingCode = "ABC123",
        )
        val trusted = TrustedEndpoint(
            endpointId = "studio-mac-01",
            endpointName = "Studio Mac",
            endpointKind = "pc",
            publicKeyFingerprint = "sha256:abcdef0123456789",
            priority = 90,
            capabilities = listOf("settings", "diagnostics"),
            lastSeenMs = 1234,
        )
        val export = buildAndroidDiagnosticsJson(
            endpointHello = endpointHello,
            trustedEndpoints = listOf(trusted),
            savedRobots = listOf(
                SavedRobot(
                    robotId = "stackchan-bench-01",
                    robotName = "Stackchan Bench",
                    firmwareVersion = "bench-v1",
                    fingerprint = "bench-v1",
                    lastBridgeUrl = "ws://192.168.1.42:8765/bridge",
                    lastSeenMs = 1234,
                ),
            ),
            bridgeStatus = AndroidBridgeRuntimeStatus(
                manualBridgeUrls = listOf("ws://192.168.1.42:8765/bridge"),
                serviceStatus = "Foreground",
                serviceDetail = "Bridge ready at ws://192.168.1.42:8765/bridge; session wake lock active",
                robotSocketConnected = true,
                robotConnected = true,
                robotId = "stackchan-bench-01",
                robotName = "Stackchan Bench",
                firmwareVersion = "bench-v1",
                lastMessageType = "app_text_turn",
                activeBrainOwner = "phone-rob-01",
                textTurnsSubmitted = 2,
                lastTextTurn = "secret words should not leave the app",
            ),
            modelAssetStatus = AndroidModelAssetStatus(
                localPath = "/storage/emulated/0/Android/data/dev.stackchan.companion/files/Download/models/gemma-4-E2B-it.litertlm",
                bytes = 2_588_147_712L,
                downloaded = true,
                loaded = true,
                downloadId = null,
                checksumVerified = true,
            ),
            generatedAt = Instant.parse("2026-07-04T19:00:00Z"),
        )

        assertEquals("stackchan.android.diagnostics-export.v1", export["schema"]!!.jsonPrimitive.content)
        assertEquals("2026-07-04T19:00:00Z", export["generated_at"]!!.jsonPrimitive.content)

        val bridge = export["bridge"]!!.jsonObject
        assertEquals("app_text_turn", bridge["last_message_type"]!!.jsonPrimitive.content)
        assertEquals(2, bridge["text_turns_submitted"]!!.jsonPrimitive.content.toInt())
        assertTrue(bridge["last_text_turn_present"]!!.jsonPrimitive.boolean)
        assertTrue(bridge["robot_socket_connected"]!!.jsonPrimitive.boolean)

        val pairing = export["pairing"]!!.jsonObject
        assertTrue(pairing["pairing_code_present"]!!.jsonPrimitive.boolean)
        assertEquals("stackchan://pair", pairing["pairing_qr_scheme"]!!.jsonPrimitive.content)
        assertEquals(
            "wifi set ssid \"<network-name>\" pass \"<network-password>\" url \"ws://192.168.1.42:8765/bridge\"",
            pairing["wifi_provisioning_command_template"]!!.jsonPrimitive.content,
        )
        assertEquals("wifi clear", pairing["wifi_clear_command"]!!.jsonPrimitive.content)
        assertTrue(pairing["password_redacted"]!!.jsonPrimitive.boolean)
        assertFalse(export.toString().contains("network-password-secret"))

        val robot = export["robot"]!!.jsonObject
        assertTrue(robot["socket_connected"]!!.jsonPrimitive.boolean)
        assertTrue(robot["connected"]!!.jsonPrimitive.boolean)
        assertTrue(robot["saved_on_phone"]!!.jsonPrimitive.boolean)
        assertEquals("stackchan-bench-01", robot["device_id"]!!.jsonPrimitive.content)

        val model = export["model"]!!.jsonObject
        assertEquals("Gemma-4-E2B", model["model_id"]!!.jsonPrimitive.content)
        assertEquals("LiteRT-LM", model["runtime"]!!.jsonPrimitive.content)
        assertEquals("gemma-4-E2B-it.litertlm", model["expected_file"]!!.jsonPrimitive.content)
        assertEquals(2_588_147_712L, model["expected_bytes"]!!.jsonPrimitive.content.toLong())
        assertEquals(
            "181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c",
            model["expected_sha256"]!!.jsonPrimitive.content,
        )
        assertTrue(model["local_path"]!!.jsonPrimitive.content.contains("gemma-4-E2B-it.litertlm"))
        assertTrue(model["downloaded"]!!.jsonPrimitive.boolean)
        assertTrue(model["loaded"]!!.jsonPrimitive.boolean)
        assertTrue(model["checksum_verified"]!!.jsonPrimitive.boolean)
        assertEquals("litert_adapter_selected", model["runner_status"]!!.jsonPrimitive.content)
        assertEquals("mobile_brain_litert_turn", model["success_intent"]!!.jsonPrimitive.content)
        assertEquals("mobile_brain_litert_error", model["failure_intent"]!!.jsonPrimitive.content)
        assertTrue(model["requires_real_device_inference_evidence"]!!.jsonPrimitive.boolean)

        assertEquals(1, export["saved_robots"]!!.jsonArray.size)
        assertEquals(1, export["trusted_endpoints"]!!.jsonArray.size)
        assertTrue(export["recent_logs"]!!.jsonArray.isNotEmpty())
        assertEquals("none", export["privacy"]!!.jsonObject["raw_audio_retention"]!!.jsonPrimitive.content)
        assertFalse(export.toString().contains("secret words"))
    }
}
