package dev.stackchan.companion.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import dev.stackchan.companion.core.DEFAULT_BRIDGE_PORT
import dev.stackchan.companion.ui.BrainServiceUiState
import dev.stackchan.companion.ui.CompanionConsole
import dev.stackchan.companion.ui.CompanionUiState

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        CompanionBridgeService.start(this)
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
}
