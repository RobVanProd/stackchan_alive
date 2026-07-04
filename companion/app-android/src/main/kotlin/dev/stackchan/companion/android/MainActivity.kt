package dev.stackchan.companion.android

import android.Manifest
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import dev.stackchan.companion.core.EndpointHello
import dev.stackchan.companion.core.TrustedEndpoint
import dev.stackchan.companion.core.defaultAndroidEndpointHello
import dev.stackchan.companion.ui.BrainServiceUiState
import dev.stackchan.companion.ui.CompanionConsole
import dev.stackchan.companion.ui.CompanionUiState
import dev.stackchan.companion.ui.EndpointRow
import dev.stackchan.companion.ui.RobotSetupStepUiState
import dev.stackchan.companion.ui.RobotSetupUiState
import dev.stackchan.companion.ui.TelemetryReading

class MainActivity : ComponentActivity() {
    private val prefs by lazy { getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE) }
    private var bridgeServiceStarted = false
    private val notificationPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) {
            startBridgeServiceOnce()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestNotificationPermissionOrStartBridge()
        val stores = AndroidBridgeStores(this)
        val endpointHello = defaultAndroidEndpointHello(endpointId = stores.endpointId())
        val manualBridgeUrls = localBridgeManualUrls()
        AndroidBridgeRuntimeStatusStore.setManualBridgeUrls(manualBridgeUrls)
        setContent {
            val bridgeStatus by AndroidBridgeRuntimeStatusStore.status.collectAsState()
            var trustedEndpoints by remember { mutableStateOf(stores.loadTrustedEndpoints().snapshot().endpoints) }
            CompanionConsole(
                targetName = "Android",
                state = androidCompanionUiState(endpointHello, trustedEndpoints, bridgeStatus),
                onStartBrain = { startBridgeServiceOnce() },
                onStopBrain = { stopBridgeService() },
                onRestartBrain = { restartBridgeService() },
                onForgetEndpoint = { endpointId ->
                    val registry = stores.loadTrustedEndpoints()
                    registry.forget(endpointId)
                    stores.saveTrustedEndpoints(registry)
                    trustedEndpoints = registry.snapshot().endpoints
                },
            )
        }
    }

    override fun onStart() {
        super.onStart()
        showBatteryOptimizationPromptIfNeeded()
    }

    private fun requestNotificationPermissionOrStartBridge() {
        if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        } else {
            startBridgeServiceOnce()
        }
    }

    private fun startBridgeServiceOnce() {
        if (bridgeServiceStarted) {
            return
        }
        bridgeServiceStarted = true
        CompanionBridgeService.start(this)
    }

    private fun stopBridgeService() {
        bridgeServiceStarted = false
        CompanionBridgeService.stop(this)
    }

    private fun restartBridgeService() {
        bridgeServiceStarted = true
        CompanionBridgeService.restart(this)
    }

    private fun showBatteryOptimizationPromptIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return
        }
        if (prefs.getBoolean(KEY_BATTERY_PROMPT_SHOWN, false)) {
            return
        }
        val powerManager = getSystemService(PowerManager::class.java)
        if (powerManager.isIgnoringBatteryOptimizations(packageName)) {
            prefs.edit().putBoolean(KEY_BATTERY_PROMPT_SHOWN, true).apply()
            return
        }

        prefs.edit().putBoolean(KEY_BATTERY_PROMPT_SHOWN, true).apply()
        AlertDialog.Builder(this)
            .setTitle("Keep Stackchan reachable")
            .setMessage(
                "Allow Stackchan Companion to ignore battery optimizations so the robot can reach this phone " +
                    "while the screen is off during bench testing. The bridge still works if you skip this.",
            )
            .setPositiveButton("Open settings") { _, _ ->
                openBatteryOptimizationRequest()
            }
            .setNegativeButton("Not now") { dialog, _ ->
                dialog.dismiss()
            }
            .show()
    }

    private fun openBatteryOptimizationRequest() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return
        }
        val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
            data = Uri.parse("package:$packageName")
        }
        runCatching { startActivity(intent) }
            .onFailure {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            }
    }

    private companion object {
        const val PREFS_NAME = "stackchan_android_bridge"
        const val KEY_BATTERY_PROMPT_SHOWN = "battery_optimization_prompt_shown"
    }
}

internal fun androidCompanionUiState(
    endpointHello: EndpointHello,
    trustedEndpoints: List<TrustedEndpoint>,
    bridgeStatus: AndroidBridgeRuntimeStatus,
): CompanionUiState =
    CompanionUiState(
        connection = bridgeStatus.connectionLabel,
        brainOwner = bridgeStatus.activeBrainOwner.ifBlank { "None" },
        heartbeatMs = if (bridgeStatus.robotConnected) 8 else 0,
        activePersona = "Android bridge",
        robotState = bridgeStatus.robotState,
        servoArmed = false,
        telemetry = androidTelemetryReadings(bridgeStatus),
        audioStatus = if (bridgeStatus.robotConnected) "Robot bridge connected" else "Waiting for robot bridge",
        brainService = BrainServiceUiState(
            running = bridgeStatus.serviceStatus != "Stopped" && bridgeStatus.serviceStatus != "Failed",
            status = bridgeStatus.serviceStatus,
            panelTitle = "Android Bridge Service",
            primaryActionRunningLabel = "Stop bridge",
            primaryActionStoppedLabel = "Start bridge",
            restartActionLabel = "Restart bridge",
            showBrainHandoffActions = false,
            pid = "android",
            endpoint = bridgeStatus.primaryBridgeUrl,
            command = "CompanionBridgeService",
            recentLogs = androidRecentLogs(endpointHello, trustedEndpoints, bridgeStatus),
        ),
        robotSetup = androidRobotSetup(bridgeStatus, trustedEndpoints.size),
        consoleMessage = bridgeStatus.consoleMessage,
        endpoints = androidEndpointRows(endpointHello, trustedEndpoints, bridgeStatus),
    )

private fun androidRobotSetup(
    bridgeStatus: AndroidBridgeRuntimeStatus,
    trustedCompanionCount: Int,
): RobotSetupUiState {
    val serviceRunning = bridgeStatus.serviceStatus != "Stopped" && bridgeStatus.serviceStatus != "Failed"
    val setupStatus = when {
        bridgeStatus.robotConnected -> "${bridgeStatus.robotDisplayName} is connected. Brain and settings controls are now available."
        serviceRunning -> "Bridge is ready. Connect Stack-chan to this phone's bridge URL."
        else -> "Start the phone bridge so Stack-chan can discover this app."
    }
    return RobotSetupUiState(
        setupStatus = setupStatus,
        primaryBridgeUrl = bridgeStatus.primaryBridgeUrl,
        otherBridgeUrls = bridgeStatus.manualBridgeUrls.drop(1),
        serviceRunning = serviceRunning,
        robotConnected = bridgeStatus.robotConnected,
        robotName = bridgeStatus.robotDisplayName,
        robotFingerprint = bridgeStatus.robotFingerprint,
        trustedCompanionCount = trustedCompanionCount,
        steps = listOf(
            RobotSetupStepUiState(
                label = "Start phone bridge",
                detail = if (serviceRunning) {
                    "The bridge is advertising on this phone."
                } else {
                    "Tap Start bridge so Stack-chan has somewhere to connect."
                },
                completed = serviceRunning,
                current = !serviceRunning,
            ),
            RobotSetupStepUiState(
                label = "Connect Stack-chan",
                detail = "Power on Stack-chan, keep it on this Wi-Fi, and enter the phone bridge URL.",
                completed = bridgeStatus.robotConnected,
                current = serviceRunning && !bridgeStatus.robotConnected,
            ),
            RobotSetupStepUiState(
                label = "Confirm robot ready",
                detail = if (bridgeStatus.robotConnected) {
                    "Robot hello received: ${bridgeStatus.robotDisplayName} / ${bridgeStatus.robotFingerprint}."
                } else {
                    "Wait here until the robot row changes from waiting to connected."
                },
                completed = bridgeStatus.robotConnected,
                current = bridgeStatus.robotConnected,
            ),
        ),
    )
}

private fun androidTelemetryReadings(bridgeStatus: AndroidBridgeRuntimeStatus): List<TelemetryReading> =
    listOf(
        TelemetryReading(
            label = "Robot",
            value = bridgeStatus.robotDisplayName,
            detail = if (bridgeStatus.robotConnected) "Connected" else "Waiting",
        ),
        TelemetryReading(
            label = "Firmware",
            value = bridgeStatus.robotFingerprint,
            detail = if (bridgeStatus.robotConnected) "Version signal" else "No robot hello",
        ),
        TelemetryReading(
            label = "Last frame",
            value = bridgeStatus.lastMessageType.ifBlank { if (bridgeStatus.robotConnected) "connected" else "none" },
            detail = "Bridge frame",
        ),
        TelemetryReading(
            label = "Service",
            value = bridgeStatus.serviceStatus,
            detail = "Foreground state",
        ),
    )

private fun androidEndpointRows(
    endpointHello: EndpointHello,
    trustedEndpoints: List<TrustedEndpoint>,
    bridgeStatus: AndroidBridgeRuntimeStatus,
): List<EndpointRow> {
    val robotRow = EndpointRow(
        endpointId = bridgeStatus.robotId.ifBlank { "stackchan-robot" },
        name = bridgeStatus.robotDisplayName,
        kind = "robot",
        fingerprint = bridgeStatus.robotFingerprint,
        priority = 100,
        connected = bridgeStatus.robotConnected,
        activeBrain = false,
    )
    val phoneRow = EndpointRow(
        endpointId = endpointHello.endpointId,
        name = "${endpointHello.endpointName} (This Phone)",
        kind = endpointHello.endpointKind,
        fingerprint = endpointHello.endpointId,
        priority = endpointHello.priority,
        connected = true,
        activeBrain = bridgeStatus.activeBrainOwner == endpointHello.endpointId,
    )
    return listOf(robotRow, phoneRow) + trustedEndpoints.map { it.toEndpointRow(bridgeStatus.activeBrainOwner) }
}

private fun TrustedEndpoint.toEndpointRow(activeBrainOwner: String): EndpointRow =
    EndpointRow(
        endpointId = endpointId,
        name = endpointName.ifBlank { endpointId },
        kind = endpointKind,
        fingerprint = publicKeyFingerprint.ifBlank { endpointId },
        priority = priority,
        connected = false,
        activeBrain = activeBrainOwner == endpointId,
        removable = true,
    )

private fun androidRecentLogs(
    endpointHello: EndpointHello,
    trustedEndpoints: List<TrustedEndpoint>,
    bridgeStatus: AndroidBridgeRuntimeStatus,
): List<String> = buildList {
    add(bridgeStatus.serviceDetail)
    add("Endpoint ID: ${endpointHello.endpointId}")
    add("Manual fallback URL: ${bridgeStatus.primaryBridgeUrl}")
    if (bridgeStatus.manualBridgeUrls.size > 1) {
        add("Other LAN URLs: ${bridgeStatus.manualBridgeUrls.drop(1).joinToString(", ")}")
    }
    if (bridgeStatus.robotConnected) {
        add("Robot: ${bridgeStatus.robotDisplayName} / ${bridgeStatus.robotFingerprint}")
        add("Last bridge frame: ${bridgeStatus.lastMessageType.ifBlank { "connected" }}")
        add("Brain owner: ${bridgeStatus.activeBrainOwner.ifBlank { "None" }}")
    } else {
        add("Robot session: waiting for handshake")
    }
    add("Trusted endpoints stored: ${trustedEndpoints.size}")
    add("Android NSD advertises _stackchan-bridge._tcp.local.")
    add("UDP beacon broadcasts endpoint metadata on port 8766.")
}
