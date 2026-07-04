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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import dev.stackchan.companion.core.EndpointHello
import dev.stackchan.companion.core.CompanionIdentity
import dev.stackchan.companion.core.SettingsRepository
import dev.stackchan.companion.core.TrustedEndpoint
import dev.stackchan.companion.core.defaultAndroidEndpointHello
import dev.stackchan.companion.ui.BrainServiceUiState
import dev.stackchan.companion.ui.BrainHandoffUiState
import dev.stackchan.companion.ui.CompanionConsole
import dev.stackchan.companion.ui.CompanionUiState
import dev.stackchan.companion.ui.ConversationMessage
import dev.stackchan.companion.ui.ConversationUiState
import dev.stackchan.companion.ui.DiagnosticsSurfaceUiState
import dev.stackchan.companion.ui.DiagnosticsExportUiState
import dev.stackchan.companion.ui.EndpointRow
import dev.stackchan.companion.ui.RobotSetupStepUiState
import dev.stackchan.companion.ui.RobotSetupUiState
import dev.stackchan.companion.ui.SettingsSurfaceUiState
import dev.stackchan.companion.ui.TelemetryReading
import java.security.MessageDigest
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

class MainActivity : ComponentActivity() {
    private val prefs by lazy { getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE) }
    private var bridgeServiceStarted = false
    private var speechTurnController: AndroidSpeechTurnController? = null
    private var pendingSpeechPermissionResult: ((Boolean) -> Unit)? = null
    private val notificationPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) {
            startBridgeServiceOnce()
        }
    private val speechPermissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            pendingSpeechPermissionResult?.invoke(granted)
            pendingSpeechPermissionResult = null
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestNotificationPermissionOrStartBridge()
        val stores = AndroidBridgeStores(this)
        val endpointHello = defaultAndroidEndpointHello(endpointId = stores.endpointId())
        val settingsRepository = stores.loadSettings()
        val manualBridgeUrls = localBridgeManualUrls()
        AndroidBridgeRuntimeStatusStore.setManualBridgeUrls(manualBridgeUrls)
        setContent {
            val bridgeStatus by AndroidBridgeRuntimeStatusStore.status.collectAsState()
            var trustedEndpoints by remember { mutableStateOf(stores.loadTrustedEndpoints().snapshot().endpoints) }
            var savedRobots by remember { mutableStateOf(stores.loadSavedRobots()) }
            var conversationMessages by remember {
                mutableStateOf(
                    listOf(
                        ConversationMessage(
                            sender = "Bridge",
                            text = "Connect Stack-chan, then send a text turn from this phone.",
                            detail = "Ready",
                        ),
                    ),
                )
            }
            var diagnosticsExport by remember {
                mutableStateOf(
                    DiagnosticsExportUiState(
                        status = "Ready",
                        path = filesDir.resolve("diagnostics").resolve("ANDROID_DIAGNOSTICS_EXPORT.json").absolutePath,
                    ),
                )
            }
            var pushToTalkStatus by remember { mutableStateOf("Microphone turns use Android speech recognition.") }
            val speechController = remember {
                AndroidSpeechTurnController(applicationContext).also {
                    speechTurnController = it
                }
            }
            val coroutineScope = rememberCoroutineScope()
            LaunchedEffect(
                bridgeStatus.robotConnected,
                bridgeStatus.robotId,
                bridgeStatus.robotName,
                bridgeStatus.firmwareVersion,
            ) {
                if (bridgeStatus.robotConnected && bridgeStatus.robotId.isNotBlank()) {
                    savedRobots = stores.rememberRobot(
                        SavedRobot(
                            robotId = bridgeStatus.robotId,
                            robotName = bridgeStatus.robotDisplayName,
                            firmwareVersion = bridgeStatus.firmwareVersion,
                            fingerprint = bridgeStatus.robotFingerprint,
                            lastBridgeUrl = bridgeStatus.primaryBridgeUrl,
                            lastSeenMs = System.currentTimeMillis(),
                        ),
                    )
                }
            }
            fun submitTurn(text: String, userDetail: String = "Sending") {
                val cleanedText = text.trim()
                if (cleanedText.isBlank()) {
                    return
                }
                conversationMessages = conversationMessages + ConversationMessage("You", cleanedText, userDetail)
                coroutineScope.launch {
                    val result = CompanionBridgeService.submitTextTurn(cleanedText)
                    conversationMessages = conversationMessages + ConversationMessage(
                        sender = "Bridge",
                        text = if (result.accepted) result.responseText else result.detail,
                        detail = if (result.accepted) "Sent seq ${result.seq}" else "Not sent",
                    )
                }
            }

            CompanionConsole(
                targetName = "Android",
                state = androidCompanionUiState(
                    endpointHello = endpointHello,
                    settingsRepository = settingsRepository,
                    trustedEndpoints = trustedEndpoints,
                    savedRobots = savedRobots,
                    bridgeStatus = bridgeStatus,
                    conversationMessages = conversationMessages,
                    diagnosticsExport = diagnosticsExport,
                    pushToTalkAvailable = speechController.isAvailable(),
                    pushToTalkStatus = pushToTalkStatus,
                ),
                onStartBrain = { startBridgeServiceOnce() },
                onStopBrain = { stopBridgeService() },
                onRestartBrain = { restartBridgeService() },
                onForgetEndpoint = { endpointId ->
                    val registry = stores.loadTrustedEndpoints()
                    registry.forget(endpointId)
                    stores.saveTrustedEndpoints(registry)
                    trustedEndpoints = registry.snapshot().endpoints
                },
                onForgetRobot = { robotId ->
                    savedRobots = stores.forgetRobot(robotId)
                },
                onSendTextTurn = { text ->
                    submitTurn(text)
                },
                onPushToTalk = {
                    if (!bridgeStatus.robotConnected) {
                        pushToTalkStatus = "Connect Stack-chan before using push-to-talk."
                        return@CompanionConsole
                    }
                    val startListening = {
                        pushToTalkStatus = "Listening..."
                        conversationMessages = conversationMessages + ConversationMessage("Mic", "Listening for a short turn.", "Push-to-talk")
                        speechController.start(
                            onListening = {
                                pushToTalkStatus = "Listening..."
                            },
                            onPartialTranscript = { transcript ->
                                pushToTalkStatus = "Heard: $transcript"
                            },
                            onFinalTranscript = { transcript ->
                                pushToTalkStatus = "Transcript ready."
                                submitTurn(transcript, userDetail = "Speech transcript")
                            },
                            onError = { message ->
                                pushToTalkStatus = message
                                conversationMessages = conversationMessages + ConversationMessage("Mic", message, "Not sent")
                            },
                        )
                    }
                    if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                        startListening()
                    } else {
                        pushToTalkStatus = "Microphone permission is required for push-to-talk."
                        pendingSpeechPermissionResult = { granted ->
                            if (granted) {
                                startListening()
                            } else {
                                pushToTalkStatus = "Microphone permission was denied."
                                conversationMessages = conversationMessages + ConversationMessage(
                                    sender = "Mic",
                                    text = "Microphone permission was denied.",
                                    detail = "Not sent",
                                )
                            }
                        }
                        speechPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                    }
                },
                onExportDiagnostics = {
                    diagnosticsExport = diagnosticsExport.copy(status = "Exporting", error = "")
                    try {
                        val result = exportAndroidDiagnostics(
                            context = this@MainActivity,
                            endpointHello = endpointHello,
                            trustedEndpoints = trustedEndpoints,
                            savedRobots = savedRobots,
                            bridgeStatus = bridgeStatus,
                        )
                        diagnosticsExport = DiagnosticsExportUiState(status = "Exported", path = result.path)
                        val shareIntent = Intent(Intent.ACTION_SEND)
                            .setType("application/json")
                            .putExtra(Intent.EXTRA_SUBJECT, "Stackchan Android diagnostics")
                            .putExtra(Intent.EXTRA_TEXT, result.json)
                        startActivity(Intent.createChooser(shareIntent, "Share Stackchan diagnostics"))
                    } catch (error: Exception) {
                        diagnosticsExport = diagnosticsExport.copy(
                            status = "Export failed",
                            error = error.message ?: error.javaClass.simpleName,
                        )
                    }
                },
            )
        }
    }

    override fun onStart() {
        super.onStart()
        showBatteryOptimizationPromptIfNeeded()
    }

    override fun onDestroy() {
        speechTurnController?.stop()
        speechTurnController = null
        super.onDestroy()
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
    settingsRepository: SettingsRepository = SettingsRepository(),
    trustedEndpoints: List<TrustedEndpoint>,
    savedRobots: List<SavedRobot> = emptyList(),
    bridgeStatus: AndroidBridgeRuntimeStatus,
    conversationMessages: List<ConversationMessage> = emptyList(),
    diagnosticsExport: DiagnosticsExportUiState = DiagnosticsExportUiState(),
    pushToTalkAvailable: Boolean = false,
    pushToTalkStatus: String = "",
): CompanionUiState {
    val settingsSurface = androidSettingsSurface(settingsRepository)
    return CompanionUiState(
        connection = bridgeStatus.connectionLabel,
        brainOwner = bridgeStatus.activeBrainOwner.ifBlank { "None" },
        heartbeatStatus = androidHeartbeatStatus(bridgeStatus),
        activePersona = settingsSurface.activePersona,
        robotState = bridgeStatus.robotState,
        servoArmed = false,
        telemetry = androidTelemetryReadings(bridgeStatus),
        audioStatus = if (bridgeStatus.robotConnected) "Bridge connected; no live meter" else "Waiting for robot bridge",
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
        settingsSurface = settingsSurface,
        diagnosticsSurface = androidDiagnosticsSurface(settingsRepository, trustedEndpoints, bridgeStatus),
        handoffSurface = androidHandoffSurface(endpointHello, trustedEndpoints, bridgeStatus),
        robotSetup = androidRobotSetup(
            endpointHello = endpointHello,
            bridgeStatus = bridgeStatus,
            trustedCompanionCount = trustedEndpoints.size,
            savedRobotCount = savedRobots.size,
        ),
        conversation = androidConversationUiState(
            bridgeStatus = bridgeStatus,
            conversationMessages = conversationMessages,
            pushToTalkAvailable = pushToTalkAvailable,
            pushToTalkStatus = pushToTalkStatus,
        ),
        diagnosticsExport = diagnosticsExport,
        consoleMessage = bridgeStatus.consoleMessage,
        endpoints = androidEndpointRows(endpointHello, trustedEndpoints, savedRobots, bridgeStatus),
    )
}

private fun androidHeartbeatStatus(bridgeStatus: AndroidBridgeRuntimeStatus): String =
    when {
        bridgeStatus.robotConnected && bridgeStatus.lastMessageType == "heartbeat" -> "Heartbeat: received"
        bridgeStatus.robotConnected -> "Heartbeat: waiting"
        bridgeStatus.robotSocketConnected -> "Heartbeat: awaiting hello"
        bridgeStatus.serviceStatus == "Foreground" || bridgeStatus.serviceStatus == "Running" -> "Heartbeat: waiting for robot"
        else -> "Heartbeat: offline"
    }

private fun androidSettingsSurface(settingsRepository: SettingsRepository): SettingsSurfaceUiState {
    val snapshot = settingsRepository.snapshot()
    val settings = snapshot.settings
    return SettingsSurfaceUiState(
        version = snapshot.version,
        activePersona = settings.stringValue("persona", "active", "spark"),
        voiceProfile = settings.stringValue("voice", "profile", "review_synth"),
        voiceVolume = settings.stringValue("voice", "volume", "70"),
        displayBrightness = settings.stringValue("display", "brightness", "80"),
        displayReducedMotion = settings.booleanValue("display", "reduced_motion"),
        motionReduced = settings.booleanValue("motion", "reduced_motion"),
        rawAudioRetention = settings.stringValue("privacy", "raw_audio_retention", "none"),
        modelProfile = settings.stringValue("model", "profile", "fake"),
        modelStatus = settings.stringValue("model", "runner_status", "deterministic_fake"),
        writeStatus = "Settings are visible here. Writes stay locked until robot settings_set round-trip evidence exists.",
        writesEnabled = false,
    )
}

private fun androidDiagnosticsSurface(
    settingsRepository: SettingsRepository,
    trustedEndpoints: List<TrustedEndpoint>,
    bridgeStatus: AndroidBridgeRuntimeStatus,
): DiagnosticsSurfaceUiState {
    val snapshot = settingsRepository.snapshot()
    return DiagnosticsSurfaceUiState(
        protocol = CompanionIdentity.protocol,
        settingsVersion = "v${snapshot.version}",
        trustedEndpointCount = trustedEndpoints.size.toString(),
        audioEngine = if (bridgeStatus.robotConnected) "bridge" else "waiting",
        audioSampleRate = if (bridgeStatus.robotConnected) "24000Hz out" else "n/a",
        modelProfile = snapshot.settings.stringValue("model", "profile", "fake"),
        modelStatus = snapshot.settings.stringValue("model", "runner_status", "deterministic_fake"),
        firmwareTarget = bridgeStatus.robotFingerprint,
        batterySource = "phone foreground service",
    )
}

private fun androidHandoffSurface(
    endpointHello: EndpointHello,
    trustedEndpoints: List<TrustedEndpoint>,
    bridgeStatus: AndroidBridgeRuntimeStatus,
): BrainHandoffUiState {
    val owner = bridgeStatus.activeBrainOwner.ifBlank { "None" }
    val ownerKind = trustedEndpoints.firstOrNull { it.endpointId == bridgeStatus.activeBrainOwner }?.endpointKind
        ?: if (bridgeStatus.activeBrainOwner == endpointHello.endpointId) endpointHello.endpointKind else "none"
    return BrainHandoffUiState(
        owner = owner,
        ownerKind = ownerKind,
        state = if (bridgeStatus.activeBrainOwner.isBlank()) "idle" else "active",
        claimEnabled = false,
        releaseEnabled = false,
        status = if (bridgeStatus.robotConnected) {
            "Robot is connected. Manual claim/release stays locked until owner_status round-trip evidence is captured."
        } else {
            "Connect Stack-chan before brain handoff can be tested."
        },
    )
}

private fun androidConversationUiState(
    bridgeStatus: AndroidBridgeRuntimeStatus,
    conversationMessages: List<ConversationMessage>,
    pushToTalkAvailable: Boolean,
    pushToTalkStatus: String,
): ConversationUiState {
    val connected = bridgeStatus.robotConnected
    return ConversationUiState(
        inputEnabled = connected,
        pushToTalkEnabled = connected && pushToTalkAvailable,
        pushToTalkLabel = if (pushToTalkAvailable) "Push-to-talk" else "Mic unavailable",
        pushToTalkStatus = pushToTalkStatus,
        status = when {
            connected && bridgeStatus.textTurnsSubmitted > 0 ->
                "Text turns sent: ${bridgeStatus.textTurnsSubmitted}. Last turn: ${bridgeStatus.lastTextTurn.ifBlank { "n/a" }}"
            connected -> "Connected to ${bridgeStatus.robotDisplayName}. Text turns will play through the robot bridge."
            else -> "Connect Stack-chan before sending text turns from this phone."
        },
        messages = conversationMessages.ifEmpty {
            listOf(
                ConversationMessage(
                    sender = "Bridge",
                    text = if (connected) {
                        "Stack-chan is connected. Send a short text turn to test the conversation path."
                    } else {
                        "Waiting for Stack-chan before text turns can be sent."
                    },
                    detail = if (connected) "Ready" else "Waiting",
                ),
            )
        },
    )
}

private fun androidRobotSetup(
    endpointHello: EndpointHello,
    bridgeStatus: AndroidBridgeRuntimeStatus,
    trustedCompanionCount: Int,
    savedRobotCount: Int,
): RobotSetupUiState {
    val serviceRunning = bridgeStatus.serviceStatus != "Stopped" && bridgeStatus.serviceStatus != "Failed"
    val robotDetected = bridgeStatus.robotSocketConnected || bridgeStatus.robotConnected
    val pairingSeed = "${endpointHello.endpointId}|${endpointHello.appVersion}|${bridgeStatus.primaryBridgeUrl}"
    val pairingFingerprint = "sha256:${sha256Hex(pairingSeed).take(32)}"
    val pairingShortCode = sha256Hex("$pairingSeed|pair").take(6).uppercase()
    val pairingInstruction = when {
        bridgeStatus.robotConnected ->
            "This phone is saved for ${bridgeStatus.robotDisplayName}. Use Forget below before pairing a replacement robot."
        bridgeStatus.robotSocketConnected ->
            "Stack-chan reached this phone. Confirm the robot display shows this code/fingerprint, then wait for hello."
        serviceRunning ->
            "On Stack-chan, choose companion pairing, enter the bridge URL, then confirm this pairing code and fingerprint."
        else ->
            "Start the phone bridge to make this pairing ticket usable."
    }
    val setupStatus = when {
        bridgeStatus.robotConnected -> "${bridgeStatus.robotDisplayName} is connected. Brain and settings controls are now available."
        bridgeStatus.robotSocketConnected -> "Stack-chan reached this phone. Waiting for the bridge hello before controls unlock."
        serviceRunning -> "Bridge is ready. Connect Stack-chan to this phone's bridge URL."
        else -> "Start the phone bridge so Stack-chan can discover this app."
    }
    val nextActionTitle = when {
        bridgeStatus.robotConnected -> "Ready to test"
        bridgeStatus.robotSocketConnected -> "Confirm the robot hello"
        serviceRunning -> "Pair on Stack-chan"
        else -> "Start this phone bridge"
    }
    val nextActionDetail = when {
        bridgeStatus.robotConnected ->
            "Open Talk for a short text turn, then keep this robot saved or use Forget below before pairing a replacement."
        bridgeStatus.robotSocketConnected ->
            "Compare the code and fingerprint shown here with Stack-chan, then wait for firmware to send hello."
        serviceRunning ->
            "On Stack-chan, open companion pairing, choose this phone, and enter ${bridgeStatus.primaryBridgeUrl} plus code $pairingShortCode."
        else ->
            "Tap Start bridge so the phone advertises mDNS, UDP beacon, and this manual bridge URL."
    }
    val removalGuidance = if (savedRobotCount > 0 || trustedCompanionCount > 0) {
        "Use Forget on saved robot rows to remove phone-side robot records. Use Remove on companion rows to revoke old phones, PCs, or test nodes."
    } else {
        "After first pairing, saved robot and trusted companion rows appear here with Forget or Remove actions."
    }
    return RobotSetupUiState(
        setupTitle = when {
            bridgeStatus.robotConnected -> "Stack-chan ready"
            bridgeStatus.robotSocketConnected -> "Finish Stack-chan pairing"
            else -> "Add your Stack-chan"
        },
        setupStatus = setupStatus,
        nextActionTitle = nextActionTitle,
        nextActionDetail = nextActionDetail,
        primaryBridgeUrl = bridgeStatus.primaryBridgeUrl,
        otherBridgeUrls = bridgeStatus.manualBridgeUrls.drop(1),
        pairingShortCode = pairingShortCode,
        pairingFingerprint = pairingFingerprint,
        pairingMode = if (serviceRunning) "mDNS + UDP + manual URL" else "Bridge stopped",
        pairingInstruction = pairingInstruction,
        serviceRunning = serviceRunning,
        robotConnected = bridgeStatus.robotConnected,
        robotName = bridgeStatus.robotDisplayName,
        robotFingerprint = bridgeStatus.robotFingerprint,
        removalGuidance = removalGuidance,
        trustedCompanionCount = trustedCompanionCount,
        savedRobotCount = savedRobotCount,
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
                detail = "Power on Stack-chan, keep it on this Wi-Fi, and enter the phone bridge URL plus pairing code.",
                completed = robotDetected,
                current = serviceRunning && !robotDetected,
            ),
            RobotSetupStepUiState(
                label = "Confirm robot ready",
                detail = if (bridgeStatus.robotConnected) {
                    "Robot hello received: ${bridgeStatus.robotDisplayName} / ${bridgeStatus.robotFingerprint}."
                } else if (bridgeStatus.robotSocketConnected) {
                    "Socket is open. Waiting for Stack-chan firmware to send the bridge hello."
                } else {
                    "Wait here until the robot row changes from waiting to connected."
                },
                completed = bridgeStatus.robotConnected,
                current = robotDetected,
            ),
        ),
    )
}

private fun androidTelemetryReadings(bridgeStatus: AndroidBridgeRuntimeStatus): List<TelemetryReading> =
    listOf(
        TelemetryReading(
            label = "Robot",
            value = bridgeStatus.robotDisplayName,
            detail = when {
                bridgeStatus.robotConnected -> "Connected"
                bridgeStatus.robotSocketConnected -> "Waiting for hello"
                else -> "Waiting"
            },
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
    savedRobots: List<SavedRobot>,
    bridgeStatus: AndroidBridgeRuntimeStatus,
): List<EndpointRow> {
    val savedRobotIds = savedRobots.map { it.robotId }.toSet()
    val robotRow = EndpointRow(
        endpointId = bridgeStatus.robotId.ifBlank { "stackchan-robot" },
        name = bridgeStatus.robotDisplayName,
        kind = "robot",
        fingerprint = bridgeStatus.robotFingerprint,
        priority = 100,
        connected = bridgeStatus.robotConnected,
        activeBrain = false,
        removable = bridgeStatus.robotId.isNotBlank() && bridgeStatus.robotId in savedRobotIds,
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
    val savedRobotRows = savedRobots
        .filterNot { it.robotId == bridgeStatus.robotId }
        .map { it.toEndpointRow() }
    return listOf(robotRow, phoneRow) + savedRobotRows + trustedEndpoints.map { it.toEndpointRow(bridgeStatus.activeBrainOwner) }
}

private fun SavedRobot.toEndpointRow(): EndpointRow =
    EndpointRow(
        endpointId = robotId,
        name = robotName.ifBlank { robotId },
        kind = "robot",
        fingerprint = fingerprint.ifBlank { firmwareVersion.ifBlank { "Saved robot" } },
        priority = 100,
        connected = false,
        activeBrain = false,
        removable = true,
    )

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

internal fun androidRecentLogs(
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

private fun sha256Hex(value: String): String =
    MessageDigest.getInstance("SHA-256")
        .digest(value.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }

private fun JsonObject.stringValue(domain: String, key: String, fallback: String): String =
    this[domain]
        ?.jsonObject
        ?.get(key)
        ?.jsonPrimitive
        ?.contentOrNull
        ?.takeIf { it.isNotBlank() }
        ?: fallback

private fun JsonObject.booleanValue(domain: String, key: String): Boolean =
    stringValue(domain, key, "false").toBooleanStrictOrNull() ?: false
