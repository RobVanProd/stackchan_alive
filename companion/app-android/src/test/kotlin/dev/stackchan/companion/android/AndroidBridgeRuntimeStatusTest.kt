package dev.stackchan.companion.android

import dev.stackchan.companion.core.defaultAndroidEndpointHello
import kotlin.test.assertEquals
import kotlin.test.assertFalse
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
        assertEquals("Awaiting robot", status.robotState)
        assertEquals("Bridge stopped: ws://192.168.1.42:8765/bridge", status.connectionLabel)
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
}
