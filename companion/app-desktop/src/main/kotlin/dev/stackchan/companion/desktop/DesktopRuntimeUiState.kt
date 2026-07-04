package dev.stackchan.companion.desktop

import dev.stackchan.companion.core.EndpointSessionSnapshot
import dev.stackchan.companion.ui.CompanionUiState
import dev.stackchan.companion.ui.EndpointRow

suspend fun DesktopCompanionRuntime.toCompanionUiState(): CompanionUiState {
    val runtime = snapshot()
    val session = sessionSnapshot()
    return session.toCompanionUiState(runtime)
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
        endpoints = listOf(robotEndpoint, desktopEndpoint),
    )
}
