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
import dev.stackchan.companion.core.EndpointHello
import dev.stackchan.companion.core.TrustedEndpoint
import dev.stackchan.companion.core.defaultAndroidEndpointHello
import dev.stackchan.companion.ui.BrainServiceUiState
import dev.stackchan.companion.ui.CompanionConsole
import dev.stackchan.companion.ui.CompanionUiState
import dev.stackchan.companion.ui.EndpointRow

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
        val trustedEndpoints = stores.loadTrustedEndpoints().snapshot().endpoints
        val manualBridgeUrls = localBridgeManualUrls()
        AndroidBridgeRuntimeStatusStore.setManualBridgeUrls(manualBridgeUrls)
        setContent {
            val bridgeStatus by AndroidBridgeRuntimeStatusStore.status.collectAsState()
            CompanionConsole(
                targetName = "Android",
                state = CompanionUiState(
                    connection = bridgeStatus.connectionLabel,
                    brainOwner = bridgeStatus.activeBrainOwner.ifBlank { "None" },
                    heartbeatMs = if (bridgeStatus.robotConnected) 8 else 0,
                    robotState = bridgeStatus.robotState,
                    brainService = BrainServiceUiState(
                        running = bridgeStatus.serviceStatus != "Stopped" && bridgeStatus.serviceStatus != "Failed",
                        status = bridgeStatus.serviceStatus,
                        pid = "android",
                        endpoint = bridgeStatus.primaryBridgeUrl,
                        command = "CompanionBridgeService",
                        recentLogs = androidRecentLogs(endpointHello, trustedEndpoints, bridgeStatus),
                    ),
                    consoleMessage = bridgeStatus.consoleMessage,
                    endpoints = androidEndpointRows(endpointHello, trustedEndpoints, bridgeStatus),
                ),
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

private fun androidEndpointRows(
    endpointHello: EndpointHello,
    trustedEndpoints: List<TrustedEndpoint>,
    bridgeStatus: AndroidBridgeRuntimeStatus,
): List<EndpointRow> {
    val robotRow = EndpointRow(
        name = bridgeStatus.robotDisplayName,
        kind = "robot",
        fingerprint = bridgeStatus.robotFingerprint,
        priority = 100,
        connected = bridgeStatus.robotConnected,
        activeBrain = false,
    )
    val phoneRow = EndpointRow(
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
        name = endpointName.ifBlank { endpointId },
        kind = endpointKind,
        fingerprint = publicKeyFingerprint.ifBlank { endpointId },
        priority = priority,
        connected = false,
        activeBrain = activeBrainOwner == endpointId,
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
