package dev.stackchan.companion.android

import android.Manifest
import android.app.AlertDialog
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
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
import dev.stackchan.companion.ui.ModelAssetUiState
import dev.stackchan.companion.ui.PersonaLibraryUiState
import dev.stackchan.companion.ui.RobotSetupStepUiState
import dev.stackchan.companion.ui.RobotSetupUiState
import dev.stackchan.companion.ui.SettingsSurfaceUiState
import dev.stackchan.companion.ui.TelemetryReading
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

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
        val manualBridgeUrls = localBridgeManualUrls()
        AndroidBridgeRuntimeStatusStore.setManualBridgeUrls(manualBridgeUrls)
        setContent {
            val bridgeStatus by AndroidBridgeRuntimeStatusStore.status.collectAsState()
            var settingsRepository by remember { mutableStateOf(stores.loadSettings()) }
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
            var modelAssetStatus by remember { mutableStateOf(stores.modelAssetStatus()) }
            var personaLibraryStatus by remember { mutableStateOf(stores.personaLibraryStatus()) }
            var pendingPersonaExportId by remember {
                mutableStateOf(settingsRepository.snapshot().settings.stringValue("persona", "active", "spark"))
            }
            var pushToTalkStatus by remember { mutableStateOf("Microphone turns use Android speech recognition.") }
            var microphonePermissionDenied by remember { mutableStateOf(false) }
            var wifiConnected by remember { mutableStateOf(isWifiConnected()) }
            val speechController = remember {
                AndroidSpeechTurnController(applicationContext).also {
                    speechTurnController = it
                }
            }
            val coroutineScope = rememberCoroutineScope()
            val personaImportLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
                if (uri == null) {
                    return@rememberLauncherForActivityResult
                }
                runCatching {
                    contentResolver.openInputStream(uri)?.use { input ->
                        stores.importPersonaZip(input)
                    } ?: error("Could not open persona zip.")
                }.onSuccess { status ->
                    personaLibraryStatus = status
                    Toast.makeText(this@MainActivity, status.importStatus, Toast.LENGTH_SHORT).show()
                }.onFailure { error ->
                    personaLibraryStatus = personaLibraryStatus.copy(
                        importStatus = "Import failed: ${error.message ?: error.javaClass.simpleName}",
                    )
                }
            }
            val personaExportLauncher =
                rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/zip")) { uri ->
                    if (uri == null) {
                        return@rememberLauncherForActivityResult
                    }
                    runCatching {
                        contentResolver.openOutputStream(uri)?.use { output ->
                            stores.exportPersonaZip(pendingPersonaExportId, output)
                        } ?: error("Could not create persona zip.")
                    }.onSuccess { status ->
                        personaLibraryStatus = status
                        Toast.makeText(this@MainActivity, status.exportStatus, Toast.LENGTH_SHORT).show()
                    }.onFailure { error ->
                        personaLibraryStatus = personaLibraryStatus.copy(
                            exportStatus = "Export failed: ${error.message ?: error.javaClass.simpleName}",
                        )
                    }
                }
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
            fun applySettingsPatch(successMessage: String, patch: JsonObject) {
                val serviceResult = CompanionBridgeService.applySettingsPatch(patch)
                if (serviceResult?.ok == true) {
                    settingsRepository = stores.loadSettings()
                    Toast.makeText(this@MainActivity, successMessage, Toast.LENGTH_SHORT).show()
                    if (bridgeStatus.robotConnected) {
                        coroutineScope.launch {
                            val robotResult = CompanionBridgeService.submitSettingsPatchToRobot(patch)
                            Toast.makeText(
                                this@MainActivity,
                                robotResult.detail,
                                if (robotResult.accepted) Toast.LENGTH_SHORT else Toast.LENGTH_LONG,
                            ).show()
                        }
                    }
                    return
                }
                val localResult = settingsRepository.set(settingsRepository.snapshot().version, patch)
                if (localResult.result.ok) {
                    stores.saveSettings(settingsRepository)
                    settingsRepository = stores.loadSettings()
                    Toast.makeText(this@MainActivity, successMessage, Toast.LENGTH_SHORT).show()
                    if (bridgeStatus.robotConnected) {
                        coroutineScope.launch {
                            val robotResult = CompanionBridgeService.submitSettingsPatchToRobot(patch)
                            Toast.makeText(
                                this@MainActivity,
                                robotResult.detail,
                                if (robotResult.accepted) Toast.LENGTH_SHORT else Toast.LENGTH_LONG,
                            ).show()
                        }
                    }
                } else {
                    Toast.makeText(
                        this@MainActivity,
                        "Settings not saved: ${localResult.errorCode.ifBlank { "version conflict" }}",
                        Toast.LENGTH_LONG,
                    ).show()
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
                    pushToTalkPermissionGranted =
                        checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED,
                    pushToTalkPermissionDenied = microphonePermissionDenied,
                    pushToTalkStatus = pushToTalkStatus,
                    modelAssetStatus = modelAssetStatus,
                    personaLibraryStatus = personaLibraryStatus,
                    wifiConnected = wifiConnected,
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
                onDownloadModel = {
                    runCatching { stores.startGemmaModelDownload() }
                        .onSuccess { status ->
                            modelAssetStatus = status
                            Toast.makeText(this@MainActivity, "Gemma-4-E2B download started.", Toast.LENGTH_SHORT)
                                .show()
                        }
                        .onFailure { error ->
                            Toast.makeText(
                                this@MainActivity,
                                "Model download failed: ${error.message ?: error.javaClass.simpleName}",
                                Toast.LENGTH_LONG,
                            ).show()
                        }
                },
                onLoadModel = {
                    runCatching { stores.loadGemmaModel() }
                        .onSuccess { status ->
                            modelAssetStatus = status
                            restartBridgeService()
                        }
                        .onFailure { error ->
                            Toast.makeText(
                                this@MainActivity,
                                "Load failed: ${error.message ?: error.javaClass.simpleName}",
                                Toast.LENGTH_LONG,
                            ).show()
                        }
                },
                onEjectModel = {
                    modelAssetStatus = stores.ejectGemmaModel()
                    restartBridgeService()
                },
                onModelSettings = {
                    Toast.makeText(
                        this@MainActivity,
                        "Gemma-4-E2B uses LiteRT-LM, local prompts, GPU preferred with CPU fallback.",
                        Toast.LENGTH_LONG,
                    ).show()
                },
                onImportPersona = {
                    personaImportLauncher.launch(arrayOf("application/zip", "application/octet-stream"))
                },
                onExportPersona = {
                    pendingPersonaExportId = settingsRepository.snapshot().settings.stringValue("persona", "active", "spark")
                    personaExportLauncher.launch("${pendingPersonaExportId}-persona.zip")
                },
                onSelectPersona = {
                    val installed = personaLibraryStatus.installedPersonas.ifEmpty { listOf("spark", "glow") }
                    val active = settingsRepository.snapshot().settings.stringValue("persona", "active", "spark")
                    val next = installed.nextAfter(active)
                    applySettingsPatch(
                        successMessage = "Persona switched to $next.",
                        patch = buildJsonObject {
                            put("persona", buildJsonObject {
                                put("active", JsonPrimitive(next))
                            })
                        },
                    )
                },
                onSaveDisplaySettings = {
                    val current = settingsRepository.snapshot().settings.booleanValue("display", "reduced_motion")
                    val next = !current
                    applySettingsPatch(
                        successMessage = if (next) "Reduced display motion enabled." else "Normal display motion enabled.",
                        patch = buildJsonObject {
                            put("display", buildJsonObject {
                                put("reduced_motion", JsonPrimitive(next))
                            })
                        },
                    )
                },
                onPrivacySettings = {
                    val current = settingsRepository.snapshot().settings.booleanValue("privacy", "export_logs")
                    val next = !current
                    applySettingsPatch(
                        successMessage = if (next) "Diagnostics log export enabled." else "Diagnostics log export disabled.",
                        patch = buildJsonObject {
                            put("privacy", buildJsonObject {
                                put("export_logs", JsonPrimitive(next))
                            })
                        },
                    )
                },
                onClaimBrain = {
                    coroutineScope.launch {
                        val result = CompanionBridgeService.claimBrain()
                        Toast.makeText(
                            this@MainActivity,
                            result.detail,
                            if (result.accepted) Toast.LENGTH_SHORT else Toast.LENGTH_LONG,
                        ).show()
                    }
                },
                onReleaseBrain = {
                    coroutineScope.launch {
                        val result = CompanionBridgeService.releaseBrain()
                        Toast.makeText(
                            this@MainActivity,
                            result.detail,
                            if (result.accepted) Toast.LENGTH_SHORT else Toast.LENGTH_LONG,
                        ).show()
                    }
                },
                onOpenWifiSettings = {
                    wifiConnected = isWifiConnected()
                    startActivity(Intent(Settings.ACTION_WIFI_SETTINGS))
                },
                onPushToTalk = {
                    if (!bridgeStatus.robotConnected) {
                        pushToTalkStatus = "Connect Stack-chan before using push-to-talk."
                        return@CompanionConsole
                    }
                    val startListening = {
                        microphonePermissionDenied = false
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
                        if (
                            microphonePermissionDenied &&
                            !shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO)
                        ) {
                            pushToTalkStatus =
                                "Microphone permission denied. Enable it in Android app settings, then retry. No transcript was sent."
                            conversationMessages = conversationMessages + ConversationMessage(
                                sender = "Mic",
                                text = "Microphone permission denied. Open Android app settings to allow it, then retry.",
                                detail = "Not sent",
                            )
                            startActivity(
                                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                                    data = Uri.parse("package:$packageName")
                                },
                            )
                            return@CompanionConsole
                        }
                        pendingSpeechPermissionResult = { granted ->
                            if (granted) {
                                microphonePermissionDenied = false
                                startListening()
                            } else {
                                microphonePermissionDenied = true
                                pushToTalkStatus =
                                    "Microphone permission denied. Enable it in Android app settings, then retry. No transcript was sent."
                                conversationMessages = conversationMessages + ConversationMessage(
                                    sender = "Mic",
                                    text = "Microphone permission denied. No transcript was sent.",
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
                            modelAssetStatus = modelAssetStatus,
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
    pushToTalkPermissionGranted: Boolean = false,
    pushToTalkPermissionDenied: Boolean = false,
    pushToTalkStatus: String = "",
    modelAssetStatus: AndroidModelAssetStatus = AndroidModelAssetStatus(
        localPath = "Android app model cache: missing",
        downloaded = false,
        loaded = false,
        downloadId = null,
        downloadInProgress = false,
    ),
    personaLibraryStatus: AndroidPersonaLibraryStatus = AndroidPersonaLibraryStatus(
        installedPersonas = listOf("spark", "glow"),
        importStatus = "Ready to import stackchan.persona-pack.v1 zip files.",
        exportStatus = "Ready to export active persona pack zip.",
    ),
    wifiConnected: Boolean = true,
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
        modelAsset = androidModelAssetSurface(modelAssetStatus),
        personaLibrary = androidPersonaLibrarySurface(settingsSurface, personaLibraryStatus),
        robotSetup = androidRobotSetup(
            endpointHello = endpointHello,
            bridgeStatus = bridgeStatus,
            trustedCompanionCount = trustedEndpoints.size,
            savedRobotCount = savedRobots.size,
            wifiConnected = wifiConnected,
        ),
        conversation = androidConversationUiState(
            bridgeStatus = bridgeStatus,
            conversationMessages = conversationMessages,
            pushToTalkAvailable = pushToTalkAvailable,
            pushToTalkPermissionGranted = pushToTalkPermissionGranted,
            pushToTalkPermissionDenied = pushToTalkPermissionDenied,
            pushToTalkStatus = pushToTalkStatus,
        ),
        diagnosticsExport = diagnosticsExport,
        consoleMessage = bridgeStatus.consoleMessage,
        endpoints = androidEndpointRows(endpointHello, trustedEndpoints, savedRobots, bridgeStatus),
    )
}

private fun androidModelAssetSurface(status: AndroidModelAssetStatus): ModelAssetUiState {
    val downloadStatus = when {
        status.checksumVerified -> "Downloaded and SHA-256 verified on this device."
        status.downloaded -> "Downloaded with the expected size; Load verifies SHA-256 target 181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c before staging."
        status.downloadInProgress -> "Download running in Android Download Manager: ${status.downloadId}."
        status.bytes > 0 -> "Found an incomplete or wrong-size model file (${status.bytes} bytes); expected 2588147712 bytes. Download again."
        else -> "Download required for Mobile Brain. Uses the LiteRT-LM Gemma-4-E2B provider asset."
    }
    val loadStatus = when {
        status.loaded -> "SHA-256 verified asset staged for Mobile Brain; LiteRT runtime adapter still pending validation."
        status.downloaded -> "Downloaded; tap Load to verify SHA-256 and stage this asset."
        else -> "Not loaded; deterministic fake runner remains active until the model is downloaded."
    }
    return ModelAssetUiState(
        modelId = "Gemma-4-E2B",
        runtime = "LiteRT-LM",
        sizeLabel = "2.58 GB",
        sourceLabel = "Google AI Edge LiteRT-LM model card",
        sourceUrl = "https://ai.google.dev/edge/litert-lm/models/gemma-4",
        localPath = status.localPath,
        downloadStatus = downloadStatus,
        loadStatus = loadStatus,
        settingsSummary = "Settings target: Gemma-4-E2B, GPU preferred with CPU fallback, no cloud fallback, local prompts only; real inference remains gated on LiteRT runtime validation.",
        downloadEnabled = !status.downloaded && !status.downloadInProgress,
        loadEnabled = status.downloaded && !status.loaded,
        ejectEnabled = status.loaded,
        settingsEnabled = status.downloaded,
    )
}

private fun androidPersonaLibrarySurface(
    settingsSurface: SettingsSurfaceUiState,
    status: AndroidPersonaLibraryStatus,
): PersonaLibraryUiState =
    PersonaLibraryUiState(
        activePersona = settingsSurface.activePersona,
        installedPersonas = status.installedPersonas,
        storageLabel = "Android app persona store plus bundled packs",
        importStatus = status.importStatus,
        exportStatus = status.exportStatus,
        importEnabled = true,
        exportEnabled = settingsSurface.activePersona in status.installedPersonas,
    )

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
        writeStatus = "Safe local settings are saved on this phone; protected robot writes still require settings_set round-trip evidence.",
        writesEnabled = true,
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
        claimEnabled = bridgeStatus.robotConnected && bridgeStatus.activeBrainOwner != endpointHello.endpointId,
        releaseEnabled = bridgeStatus.robotConnected && bridgeStatus.activeBrainOwner == endpointHello.endpointId,
        status = if (bridgeStatus.robotConnected) {
            "Robot is connected. Claim sends claim_brain; Release sends release_brain and waits for owner_status from firmware."
        } else {
            "Connect Stack-chan before brain handoff can be tested."
        },
    )
}

private fun androidConversationUiState(
    bridgeStatus: AndroidBridgeRuntimeStatus,
    conversationMessages: List<ConversationMessage>,
    pushToTalkAvailable: Boolean,
    pushToTalkPermissionGranted: Boolean,
    pushToTalkPermissionDenied: Boolean,
    pushToTalkStatus: String,
): ConversationUiState {
    val connected = bridgeStatus.robotConnected
    val effectivePushToTalkStatus = when {
        !pushToTalkAvailable ->
            "Android speech recognition is unavailable. Enable Android Speech Services, then retry."
        connected && !pushToTalkPermissionGranted && pushToTalkPermissionDenied ->
            "Microphone permission denied. Enable it in Android app settings, then retry. No transcript was sent."
        connected && !pushToTalkPermissionGranted ->
            "Tap Allow mic and approve microphone access. Denied turns are not sent."
        pushToTalkStatus.isNotBlank() -> pushToTalkStatus
        else -> "Microphone turns use Android speech recognition."
    }
    return ConversationUiState(
        inputEnabled = connected,
        pushToTalkEnabled = connected && pushToTalkAvailable,
        pushToTalkLabel = when {
            !pushToTalkAvailable -> "Mic unavailable"
            connected && !pushToTalkPermissionGranted -> "Allow mic"
            else -> "Push-to-talk"
        },
        pushToTalkStatus = effectivePushToTalkStatus,
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
    wifiConnected: Boolean,
): RobotSetupUiState {
    val serviceRunning = bridgeStatus.serviceStatus != "Stopped" && bridgeStatus.serviceStatus != "Failed"
    val robotDetected = bridgeStatus.robotSocketConnected || bridgeStatus.robotConnected
    val pairingFingerprint = androidPairingFingerprint(endpointHello, bridgeStatus.primaryBridgeUrl)
    val pairingShortCode = endpointHello.pairingCode
        ?: androidPairingShortCode(endpointHello, bridgeStatus.primaryBridgeUrl)
    val pairingQrPayload = androidPairingQrPayload(
        bridgeUrl = bridgeStatus.primaryBridgeUrl,
        pairingShortCode = pairingShortCode,
        pairingFingerprint = pairingFingerprint,
        endpointId = endpointHello.endpointId,
    )
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
            "On Stack-chan, open companion pairing, choose this phone, and enter ${bridgeStatus.primaryBridgeUrl} plus code $pairingShortCode. If firmware is still in lab setup, use the Wi-Fi command below."
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
        wifiStatus = if (wifiConnected) {
            "Phone Wi-Fi is active. Keep Stack-chan on this same LAN before pairing."
        } else {
            "Phone Wi-Fi is not active. Connect this phone to the robot's LAN before starting pairing."
        },
        wifiInstruction = if (serviceRunning) {
            "The app advertises this phone by mDNS and UDP, then falls back to the manual bridge URL. Firmware still needs Wi-Fi credentials or its pairing menu before it can reach the phone."
        } else {
            "Open Wi-Fi settings first, join the same network Stack-chan will use, then start the bridge."
        },
        wifiActionLabel = "Open Wi-Fi settings",
        wifiActionEnabled = true,
        wifiProvisioningSummary = androidWifiProvisioningSummary(serviceRunning),
        wifiProvisioningCommand = androidWifiProvisioningCommand(bridgeStatus.primaryBridgeUrl, serviceRunning),
        wifiClearCommand = "wifi clear",
        primaryBridgeUrl = bridgeStatus.primaryBridgeUrl,
        otherBridgeUrls = bridgeStatus.manualBridgeUrls.drop(1),
        pairingShortCode = pairingShortCode,
        pairingFingerprint = pairingFingerprint,
        pairingMode = if (serviceRunning) "mDNS + UDP + manual URL" else "Bridge stopped",
        pairingQrPayload = if (serviceRunning && bridgeStatus.primaryBridgeUrl.isNotBlank()) pairingQrPayload else "",
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
                label = "Join Wi-Fi",
                detail = if (wifiConnected) {
                    "This phone reports an active Wi-Fi network."
                } else {
                    "Open Wi-Fi settings and join the same LAN Stack-chan will use."
                },
                completed = wifiConnected || robotDetected,
                current = !wifiConnected && !robotDetected,
            ),
            RobotSetupStepUiState(
                label = "Start phone bridge",
                detail = if (serviceRunning) {
                    "The bridge is advertising on this phone."
                } else {
                    "Tap Start bridge so Stack-chan has somewhere to connect."
                },
                completed = serviceRunning,
                current = wifiConnected && !serviceRunning,
            ),
            RobotSetupStepUiState(
                label = "Connect Stack-chan",
                detail = "Power on Stack-chan, keep it on this Wi-Fi, and enter the phone bridge URL plus pairing code.",
                completed = robotDetected,
                current = wifiConnected && serviceRunning && !robotDetected,
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

internal fun androidWifiProvisioningCommand(primaryBridgeUrl: String, serviceRunning: Boolean): String =
    if (serviceRunning && primaryBridgeUrl.isNotBlank()) {
        "wifi set ssid <network-name> pass <network-password> url $primaryBridgeUrl"
    } else {
        ""
    }

private fun androidWifiProvisioningSummary(serviceRunning: Boolean): String =
    if (serviceRunning) {
        "For lab firmware without a consumer Wi-Fi menu, enter this on the robot serial console. Replace the placeholders locally; the app never records the password."
    } else {
        "Start the phone bridge before generating the robot Wi-Fi provisioning command."
    }

internal fun androidPairingQrPayload(
    bridgeUrl: String,
    pairingShortCode: String,
    pairingFingerprint: String,
    endpointId: String,
): String =
    "stackchan://pair" +
        "?bridge=${bridgeUrl.qrQueryValue()}" +
        "&code=${pairingShortCode.qrQueryValue()}" +
        "&fingerprint=${pairingFingerprint.qrQueryValue()}" +
        "&endpoint_id=${endpointId.qrQueryValue()}"

private fun String.qrQueryValue(): String =
    buildString {
        for (char in this@qrQueryValue) {
            if (char.isQrQueryUnreserved()) {
                append(char)
            } else {
                append('%')
                append(char.code.toString(16).uppercase().padStart(2, '0'))
            }
        }
    }

private fun Char.isQrQueryUnreserved(): Boolean =
    this in 'A'..'Z' ||
        this in 'a'..'z' ||
        this in '0'..'9' ||
        this == '-' ||
        this == '_' ||
        this == '.' ||
        this == '~'

private fun Context.isWifiConnected(): Boolean {
    val connectivityManager = getSystemService(ConnectivityManager::class.java) ?: return false
    val network = connectivityManager.activeNetwork ?: return false
    val capabilities = connectivityManager.getNetworkCapabilities(network) ?: return false
    return capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
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

private fun List<String>.nextAfter(current: String): String {
    val normalized = distinct().sorted()
    if (normalized.isEmpty()) {
        return current
    }
    val index = normalized.indexOf(current)
    return normalized[(if (index < 0) 0 else index + 1) % normalized.size]
}
