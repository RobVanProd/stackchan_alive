package dev.stackchan.companion.desktop

import dev.stackchan.companion.core.DiagnosticsSnapshot
import dev.stackchan.companion.core.EndpointSessionSnapshot
import dev.stackchan.companion.core.SettingsSnapshot
import dev.stackchan.companion.ui.BrainHandoffUiState
import dev.stackchan.companion.ui.BrainServiceUiState
import dev.stackchan.companion.ui.C6RehearsalUiState
import dev.stackchan.companion.ui.CompanionUiState
import dev.stackchan.companion.ui.ConversationMessage
import dev.stackchan.companion.ui.ConversationUiState
import dev.stackchan.companion.ui.DiagnosticsExportUiState
import dev.stackchan.companion.ui.DiagnosticsSurfaceUiState
import dev.stackchan.companion.ui.EndpointRow
import dev.stackchan.companion.ui.ModelAssetUiState
import dev.stackchan.companion.ui.PersonaLibraryUiState
import dev.stackchan.companion.ui.RobotSetupUiState
import dev.stackchan.companion.ui.SettingsSurfaceUiState
import dev.stackchan.companion.ui.TelemetryReading
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

suspend fun DesktopCompanionRuntime.toCompanionUiState(): CompanionUiState {
    val runtime = snapshot()
    val session = sessionSnapshot()
    val diagnostics = diagnosticsSnapshot(domains = listOf("bridge", "audio", "model", "firmware", "battery"))
    val settings = settingsSnapshot()
    val modelAsset = modelAssetStatus()
    val personaLibrary = personaLibraryStatus()
    return session.toCompanionUiState(runtime, diagnostics, settings, modelAsset, personaLibrary)
}

fun desktopStartingUiState(): CompanionUiState =
    CompanionUiState(
        connection = "Starting desktop bridge",
        brainOwner = "None",
        heartbeatStatus = "Heartbeat: offline",
        robotState = "Starting",
        servoArmed = false,
        endpoints = emptyList(),
    )

private fun EndpointSessionSnapshot.toCompanionUiState(
    runtime: DesktopCompanionRuntimeSnapshot,
    diagnostics: DiagnosticsSnapshot,
    settings: SettingsSnapshot,
    modelAsset: DesktopModelAssetStatus,
    personaLibrary: DesktopPersonaLibraryStatus,
): CompanionUiState {
    val robotReady = connected && robotHelloReceived
    val connection = if (robotReady) {
        "Connected: ${deviceName.ifBlank { deviceId.ifBlank { "Robot" } }}"
    } else if (connected) {
        "Bridge session: awaiting robot hello"
    } else if (runtime.mdnsAdvertised) {
        "Listening: ${runtime.host}:${runtime.port} / mDNS"
    } else {
        "Listening: ${runtime.host}:${runtime.port}"
    }
    val owner = activeBrainOwner?.takeIf { it.isNotBlank() } ?: "None"
    val robotName = deviceName.ifBlank { deviceId.ifBlank { "Awaiting robot" } }
    val robotEndpoint = EndpointRow(
        endpointId = deviceId.ifBlank { "stackchan-robot" },
        name = robotName,
        kind = "robot",
        fingerprint = firmwareVersion.ifBlank { "No firmware hello yet" },
        priority = 100,
        connected = robotReady,
        activeBrain = false,
    )
    val desktopEndpoint = EndpointRow(
        endpointId = runtime.mdnsEndpoint?.endpointId ?: runtime.endpointId,
        name = runtime.mdnsEndpoint?.endpointName ?: "This Desktop Companion",
        kind = "pc",
        fingerprint = runtime.mdnsEndpoint?.endpointId ?: runtime.endpointId,
        priority = 50,
        connected = true,
        activeBrain = owner == runtime.endpointId || owner == runtime.mdnsEndpoint?.endpointId,
    )

    return CompanionUiState(
        connection = connection,
        brainOwner = owner,
        heartbeatStatus = heartbeatStatus(robotReady),
        robotState = if (lastMessageType.isBlank()) "Awaiting robot" else lastMessageType,
        servoArmed = false,
        telemetry = diagnostics.toTelemetryReadings(this, runtime),
        audioStatus = diagnostics.audio?.stringValue("engine")?.let { "$it; no live meter" } ?: "offline",
        consoleMessage = consoleMessage(owner, runtime),
        brainService = runtime.brainSupervisor.toBrainServiceUiState(),
        settingsSurface = settings.toSettingsSurface(),
        diagnosticsSurface = diagnostics.toDiagnosticsSurface(),
        handoffSurface = toHandoffSurface(owner, diagnostics, runtime.endpointId),
        modelAsset = modelAsset.toModelAssetSurface(diagnostics),
        personaLibrary = settings.toPersonaLibrarySurface(personaLibrary),
        robotSetup = RobotSetupUiState(
            primaryBridgeUrl = "ws://${runtime.host}:${runtime.port}/bridge",
            serviceRunning = runtime.brainSupervisor.running || runtime.mdnsAdvertised,
            robotConnected = robotReady,
            robotName = robotName,
            robotFingerprint = firmwareVersion.ifBlank { "No firmware hello yet" },
        ),
        conversation = toConversationUiState(),
        diagnosticsExport = runtime.toDiagnosticsExportUiState(),
        c6Rehearsal = runtime.toC6RehearsalUiState(),
        endpoints = listOf(robotEndpoint, desktopEndpoint),
    )
}

private fun DesktopModelAssetStatus.toModelAssetSurface(diagnostics: DiagnosticsSnapshot): ModelAssetUiState {
    val profile = diagnostics.model?.stringValue("profile")?.takeIf { it.isNotBlank() } ?: "fake"
    val runner = diagnostics.model?.stringValue("runner_status")?.takeIf { it.isNotBlank() } ?: "deterministic_fake"
    val downloadStatus = when {
        downloaded -> "Downloaded and cached on this computer."
        downloadInProgress -> "Download running for the LiteRT-LM Gemma-4-E2B provider asset."
        else -> "Download required for Mobile Brain parity. Uses the LiteRT-LM Gemma-4-E2B provider asset."
    }
    val loadStatus = when {
        loaded -> "Loaded for local Mobile Brain routing."
        downloaded -> "Downloaded; tap Load before using this model."
        else -> "Not loaded; current runner profile remains $profile / $runner."
    }
    return ModelAssetUiState(
        modelId = "Gemma-4-E2B",
        runtime = "LiteRT-LM",
        sizeLabel = "2.58 GB",
        sourceLabel = "Google AI Edge LiteRT-LM model card",
        sourceUrl = "https://ai.google.dev/edge/litert-lm/models/gemma-4",
        localPath = localPath,
        downloadStatus = downloadStatus,
        loadStatus = loadStatus,
        settingsSummary = "Settings: Gemma-4-E2B, GPU preferred with CPU fallback, no cloud fallback, local prompts only.",
        downloadEnabled = !downloaded && !downloadInProgress,
        loadEnabled = downloaded && !loaded,
        ejectEnabled = loaded,
        settingsEnabled = downloaded,
    )
}

private fun SettingsSnapshot.toPersonaLibrarySurface(status: DesktopPersonaLibraryStatus): PersonaLibraryUiState =
    PersonaLibraryUiState(
        activePersona = settings.stringValue("persona", "active", "spark"),
        installedPersonas = status.installedPersonas,
        storageLabel = "Repository personas directory plus future imported packs",
        importStatus = status.importStatus,
        exportStatus = status.exportStatus,
        importEnabled = true,
        exportEnabled = settings.stringValue("persona", "active", "spark") in status.installedPersonas,
    )

private fun SettingsSnapshot.toSettingsSurface(): SettingsSurfaceUiState =
    SettingsSurfaceUiState(
        version = version,
        activePersona = settings.stringValue("persona", "active", "spark"),
        voiceProfile = settings.stringValue("voice", "profile", "review_synth"),
        voiceVolume = settings.stringValue("voice", "volume", "70"),
        displayBrightness = settings.stringValue("display", "brightness", "80"),
        displayReducedMotion = settings.booleanValue("display", "reduced_motion"),
        motionReduced = settings.booleanValue("motion", "reduced_motion"),
        rawAudioRetention = settings.stringValue("privacy", "raw_audio_retention", "none"),
        modelProfile = settings.stringValue("model", "profile", "fake"),
        modelStatus = settings.stringValue("model", "runner_status", "deterministic_fake"),
        writeStatus = "Safe local settings save through settings_set; protected robot writes still require hardware round-trip evidence.",
        writesEnabled = true,
    )

private fun DiagnosticsSnapshot.toDiagnosticsSurface(): DiagnosticsSurfaceUiState =
    DiagnosticsSurfaceUiState(
        protocol = bridge.stringValue("protocol"),
        settingsVersion = bridge.stringValue("settings_version").takeIf { it.isNotBlank() }?.let { "v$it" }.orEmpty(),
        trustedEndpointCount = bridge.stringValue("trusted_endpoint_count"),
        audioEngine = audio?.stringValue("engine").orEmpty(),
        audioSampleRate = audio?.stringValue("output_sample_rate")?.takeIf { it.isNotBlank() }?.let { "${it}Hz out" }.orEmpty(),
        modelProfile = model?.stringValue("profile").orEmpty(),
        modelStatus = model?.stringValue("runner_status").orEmpty(),
        firmwareTarget = firmware?.stringValue("target").orEmpty(),
        batterySource = battery?.stringValue("source").orEmpty(),
    )

private fun EndpointSessionSnapshot.toHandoffSurface(
    owner: String,
    diagnostics: DiagnosticsSnapshot,
    endpointId: String,
): BrainHandoffUiState =
    BrainHandoffUiState(
        owner = owner,
        ownerKind = diagnostics.bridge.stringValue("owner_kind").ifBlank { "none" },
        state = diagnostics.bridge.stringValue("owner_state").ifBlank { if (owner == "None") "idle" else "active" },
        claimEnabled = robotHelloReceived && activeBrainOwner != endpointId,
        releaseEnabled = robotHelloReceived && activeBrainOwner == endpointId,
        status = if (robotHelloReceived) {
            "Robot is connected. Claim sends claim_brain; Release sends release_brain and waits for owner_status owner round-trip evidence."
        } else {
            "Connect Stack-chan before brain handoff can be tested."
        },
    )

private fun EndpointSessionSnapshot.toConversationUiState(): ConversationUiState =
    ConversationUiState(
        inputEnabled = robotHelloReceived,
        status = when {
            robotHelloReceived && textTurnsSubmitted > 0 ->
                "Text turns sent: $textTurnsSubmitted. Last turn: ${lastTextTurn.ifBlank { "n/a" }}"
            robotHelloReceived -> "Connected to ${deviceName.ifBlank { deviceId.ifBlank { "Stack-chan" } }}. Text turns will play through the robot bridge."
            connected -> "Bridge socket is open; waiting for Stack-chan hello before text turns are enabled."
            else -> "Connect Stack-chan before sending text turns from this desktop."
        },
        messages = if (lastTextTurn.isNotBlank()) {
            listOf(
                ConversationMessage("You", lastTextTurn, "Last sent"),
                ConversationMessage("Bridge", lastTextTurn, "Delivered"),
            )
        } else {
            listOf(
                ConversationMessage(
                    sender = "Bridge",
                    text = if (robotHelloReceived) {
                        "Stack-chan is connected. Send a short text turn to test the conversation path."
                    } else {
                        "Waiting for Stack-chan before text turns can be sent."
                    },
                    detail = if (robotHelloReceived) "Ready" else "Waiting",
                ),
            )
        },
    )

private fun DesktopBrainSupervisorSnapshot.toBrainServiceUiState(): BrainServiceUiState {
    val compactCommand = buildString {
        append(command.firstOrNull()?.substringAfterLast('\\')?.substringAfterLast('/') ?: "python")
        append(" ")
        append(scriptPath.fileName?.toString() ?: "lan_service.py")
        val args = command.drop(2)
        if (args.isNotEmpty()) {
            append(" ")
            append(args.joinToString(" "))
        }
    }
    val status = when {
        running -> "Running"
        !pythonRuntime.available -> "Python unavailable"
        !pythonRuntime.scriptAvailable -> "Brain script missing"
        exitCode != null -> "Exited $exitCode"
        else -> "Stopped"
    }
    val logs = recentLogs.ifEmpty {
        listOf(
            pythonRuntime.detail,
            "PC brain supervisor idle.",
        )
    }
    return BrainServiceUiState(
        running = running,
        status = status,
        pid = pid?.toString() ?: "n/a",
        endpoint = "$host:$port",
        command = compactCommand,
        exitCode = exitCode?.toString() ?: "n/a",
        recentLogs = logs,
    )
}

private fun DesktopCompanionRuntimeSnapshot.toDiagnosticsExportUiState(): DiagnosticsExportUiState =
    when {
        diagnosticsExportError.isNotBlank() -> DiagnosticsExportUiState(
            status = "Export failed",
            path = diagnosticsExportPath?.toString().orEmpty(),
            error = diagnosticsExportError,
        )
        diagnosticsExportPath != null -> DiagnosticsExportUiState(
            status = "Exported",
            path = diagnosticsExportPath.toString(),
        )
        else -> DiagnosticsExportUiState(
            status = "Ready",
            path = storageDir.resolve("diagnostics").resolve("DIAGNOSTICS_EXPORT.json").toString(),
    )
}

private fun EndpointSessionSnapshot.heartbeatStatus(robotReady: Boolean): String =
    when {
        robotReady && lastMessageType == "heartbeat" -> "Heartbeat: received"
        robotReady -> "Heartbeat: connected"
        connected -> "Heartbeat: awaiting hello"
        else -> "Heartbeat: listening"
    }

private fun DesktopCompanionRuntimeSnapshot.toC6RehearsalUiState(): C6RehearsalUiState =
    when {
        c6RehearsalRunning -> C6RehearsalUiState(
            status = "Running",
            path = c6RehearsalPath?.toString()
                ?: storageDir.resolve("diagnostics").resolve("c6-gui-rehearsal").resolve("GUI_REHEARSAL.json")
                    .toString(),
        )
        c6RehearsalError.isNotBlank() -> C6RehearsalUiState(
            status = "Failed",
            path = c6RehearsalPath?.toString().orEmpty(),
            error = c6RehearsalError,
        )
        c6RehearsalPath != null -> C6RehearsalUiState(
            status = "Passed",
            path = c6RehearsalPath.toString(),
        )
        else -> C6RehearsalUiState(
            status = "Ready",
            path = storageDir.resolve("diagnostics").resolve("c6-gui-rehearsal").resolve("GUI_REHEARSAL.json")
                .toString(),
        )
    }

private fun DiagnosticsSnapshot.toTelemetryReadings(
    session: EndpointSessionSnapshot,
    runtime: DesktopCompanionRuntimeSnapshot,
): List<TelemetryReading> {
    val protocol = bridge.stringValue("protocol").ifBlank { "unknown" }
    val settingsVersion = bridge.stringValue("settings_version").ifBlank { "0" }
    val audioEngine = audio?.stringValue("engine") ?: "offline"
    val outputRate = audio?.stringValue("output_sample_rate")?.takeIf { it.isNotBlank() } ?: "0"
    val modelProfile = model?.stringValue("profile") ?: "fake"
    val runner = model?.stringValue("runner_status") ?: "deterministic_fake"
    val firmwareValue = session.firmwareVersion.ifBlank { firmware?.stringValue("target") ?: "awaiting robot" }
    val firmwareDetail = if (session.robotHelloReceived) {
        session.deviceName.ifBlank { session.deviceId.ifBlank { "Connected" } }
    } else {
        val transport = firmware?.stringValue("transport") ?: "websocket"
        "Listening ${runtime.host}:${runtime.port} / $transport"
    }

    return listOf(
        TelemetryReading("Protocol", protocol, "settings v$settingsVersion"),
        TelemetryReading("Audio", audioEngine, "${outputRate}Hz out"),
        TelemetryReading("Model", modelProfile, runner),
        TelemetryReading("Firmware", firmwareValue, firmwareDetail),
    )
}

private fun EndpointSessionSnapshot.consoleMessage(
    owner: String,
    runtime: DesktopCompanionRuntimeSnapshot,
): String =
    if (robotHelloReceived) {
        "Robot ${deviceName.ifBlank { deviceId }} last reported `$lastMessageType`; brain owner: $owner."
    } else if (connected) {
        "Bridge socket is open at ${runtime.host}:${runtime.port}; waiting for robot hello."
    } else {
        "Awaiting robot hello at ${runtime.host}:${runtime.port}; brain owner: $owner."
    }

private fun JsonObject.stringValue(key: String): String =
    this[key]?.let { element ->
        runCatching { element.jsonPrimitive.contentOrNull }.getOrNull()
            ?: runCatching { element.jsonObject.toString() }.getOrDefault("")
    }.orEmpty()

private fun JsonObject.stringValue(domain: String, key: String, fallback: String): String =
    this[domain]
        ?.jsonObjectOrNull()
        ?.get(key)
        ?.jsonPrimitive
        ?.contentOrNull
        ?.takeIf { it.isNotBlank() }
        ?: fallback

private fun JsonObject.booleanValue(domain: String, key: String): Boolean =
    stringValue(domain, key, "false").toBooleanStrictOrNull() ?: false

private fun JsonElement.jsonObjectOrNull(): JsonObject? =
    runCatching { jsonObject }.getOrNull()
