package dev.stackchan.companion.android

import dev.stackchan.companion.core.EndpointSessionSnapshot
import dev.stackchan.companion.core.TrustedEndpoint
import dev.stackchan.companion.core.defaultAndroidEndpointHello
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import org.junit.Test

class AndroidBridgeRuntimeStatusTest {
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
        assertFalse(status.robotConnected)
        assertEquals("", status.robotId)
        assertEquals("", status.robotName)
        assertEquals("", status.firmwareVersion)
        assertEquals("", status.lastMessageType)
        assertEquals("", status.activeBrainOwner)
        assertEquals("Bridge failed", status.robotState)
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
        assertEquals("Android bridge", uiState.activePersona)
        assertEquals("Robot bridge connected", uiState.audioStatus)
        assertEquals("Stackchan Bench", uiState.telemetry.first { it.label == "Robot" }.value)
        assertEquals("bench-v1", uiState.telemetry.first { it.label == "Firmware" }.value)
        assertEquals("heartbeat", uiState.telemetry.first { it.label == "Last frame" }.value)
        assertEquals("Foreground", uiState.telemetry.first { it.label == "Service" }.value)
        assertTrue(uiState.telemetry.none { it.value == "87%" || it.value == "42.5 C" || it.value == "v3.1.0" })
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
        assertFalse(uiState.endpoints.first { it.kind == "android" }.removable)
        assertFalse(uiState.endpoints.first { it.kind == "robot" }.removable)
    }
}
