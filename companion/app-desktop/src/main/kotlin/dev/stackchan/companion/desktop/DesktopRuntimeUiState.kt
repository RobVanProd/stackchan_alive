package dev.stackchan.companion.desktop

import dev.stackchan.companion.core.DiagnosticsSnapshot
import dev.stackchan.companion.core.EndpointSessionSnapshot
import dev.stackchan.companion.ui.BrainServiceUiState
import dev.stackchan.companion.ui.CompanionUiState
import dev.stackchan.companion.ui.DiagnosticsExportUiState
import dev.stackchan.companion.ui.EndpointRow
import dev.stackchan.companion.ui.TelemetryReading
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

suspend fun DesktopCompanionRuntime.toCompanionUiState(): CompanionUiState {
    val runtime = snapshot()
    val session = sessionSnapshot()
    val diagnostics = diagnosticsSnapshot(domains = listOf("bridge", "audio", "model", "firmware", "battery"))
    return session.toCompanionUiState(runtime, diagnostics)
}

fun desktopStartingUiState(): CompanionUiState =
    CompanionUiState(
        connection = "Starting desktop bridge",
        brainOwner = "None",
        heartbeatMs = 0,
        robotState = "Starting",
        servoArmed = false,
        endpoints = emptyList(),
    )

private fun EndpointSessionSnapshot.toCompanionUiState(
    runtime: DesktopCompanionRuntimeSnapshot,
    diagnostics: DiagnosticsSnapshot,
): CompanionUiState {
    val connection = if (connected) {
        "Connected: ${deviceName.ifBlank { deviceId.ifBlank { "Robot" } }}"
    } else if (runtime.mdnsAdvertised) {
        "Listening: ${runtime.host}:${runtime.port} / mDNS"
    } else {
        "Listening: ${runtime.host}:${runtime.port}"
    }
    val owner = activeBrainOwner?.takeIf { it.isNotBlank() } ?: "None"
    val robotName = deviceName.ifBlank { deviceId.ifBlank { "Awaiting robot" } }
    val robotEndpoint = EndpointRow(
        name = robotName,
        kind = "robot",
        fingerprint = firmwareVersion.ifBlank { "No firmware hello yet" },
        priority = 100,
        connected = connected,
        activeBrain = false,
    )
    val desktopEndpoint = EndpointRow(
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
        heartbeatMs = if (connected) 8 else 0,
        robotState = if (lastMessageType.isBlank()) "Awaiting robot" else lastMessageType,
        servoArmed = false,
        telemetry = diagnostics.toTelemetryReadings(this, runtime),
        audioStatus = diagnostics.audio?.stringValue("engine") ?: "offline",
        consoleMessage = consoleMessage(owner, runtime),
        brainService = runtime.brainSupervisor.toBrainServiceUiState(),
        diagnosticsExport = runtime.toDiagnosticsExportUiState(),
        endpoints = listOf(robotEndpoint, desktopEndpoint),
    )
}

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
        exitCode != null -> "Exited $exitCode"
        else -> "Stopped"
    }
    return BrainServiceUiState(
        running = running,
        status = status,
        pid = pid?.toString() ?: "n/a",
        endpoint = "$host:$port",
        command = compactCommand,
        exitCode = exitCode?.toString() ?: "n/a",
        recentLogs = recentLogs.ifEmpty { listOf("PC brain supervisor idle.") },
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
    val firmwareDetail = if (session.connected) {
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
    if (connected) {
        "Robot ${deviceName.ifBlank { deviceId }} last reported `$lastMessageType`; brain owner: $owner."
    } else {
        "Awaiting robot hello at ${runtime.host}:${runtime.port}; brain owner: $owner."
    }

private fun JsonObject.stringValue(key: String): String =
    this[key]?.let { element ->
        runCatching { element.jsonPrimitive.contentOrNull }.getOrNull()
            ?: runCatching { element.jsonObject.toString() }.getOrDefault("")
    }.orEmpty()
