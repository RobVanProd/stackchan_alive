package dev.stackchan.companion.android

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import dev.stackchan.companion.core.DEFAULT_BRIDGE_PORT
import dev.stackchan.companion.ui.BrainServiceUiState
import dev.stackchan.companion.ui.CompanionConsole
import dev.stackchan.companion.ui.CompanionUiState

class MainActivity : ComponentActivity() {
    private var bridgeServiceStarted = false
    private val notificationPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) {
            startBridgeServiceOnce()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestNotificationPermissionOrStartBridge()
        setContent {
            CompanionConsole(
                targetName = "Android",
                state = CompanionUiState(
                    connection = "Bridge service active on this phone",
                    brainOwner = "Android",
                    brainService = BrainServiceUiState(
                        running = true,
                        status = "Foreground",
                        pid = "android",
                        endpoint = "0.0.0.0:$DEFAULT_BRIDGE_PORT",
                        command = "CompanionBridgeService",
                        recentLogs = listOf(
                            "Foreground bridge hosts /bridge for robot testing.",
                            "Android NSD advertises _stackchan-bridge._tcp.local.",
                            "Settings and trusted endpoints persist on this phone.",
                        ),
                    ),
                    consoleMessage = "Awaiting Stack-chan bridge handshake on Android.",
                ),
            )
        }
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

}
