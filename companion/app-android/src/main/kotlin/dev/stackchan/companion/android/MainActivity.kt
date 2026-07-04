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
import dev.stackchan.companion.core.DEFAULT_BRIDGE_PORT
import dev.stackchan.companion.ui.BrainServiceUiState
import dev.stackchan.companion.ui.CompanionConsole
import dev.stackchan.companion.ui.CompanionUiState

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
