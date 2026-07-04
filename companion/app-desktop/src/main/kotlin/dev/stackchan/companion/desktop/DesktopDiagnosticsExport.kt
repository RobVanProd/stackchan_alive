package dev.stackchan.companion.desktop

import dev.stackchan.companion.core.DiagnosticsSnapshot
import dev.stackchan.companion.core.EndpointSessionSnapshot
import dev.stackchan.companion.core.companionJson
import java.time.Instant
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.put

suspend fun DesktopCompanionRuntime.exportDiagnosticsEvidenceJson(
    domains: List<String> = listOf("bridge", "audio", "model", "firmware", "battery"),
    generatedAt: Instant = Instant.now(),
): String {
    val runtime = snapshot()
    val session = sessionSnapshot()
    val diagnostics = diagnosticsSnapshot(domains)
    return buildJsonObject {
        put("schema", "stackchan.companion.diagnostics-export.v1")
        put("generated_at", generatedAt.toString())
        put("runtime", runtime.toJson())
        put("session", session.toJson())
        put("diagnostics", diagnostics.toJson())
        put("brain_service", runtime.brainSupervisor.toJson())
    }.toString()
}

private fun DesktopCompanionRuntimeSnapshot.toJson(): JsonObject =
    buildJsonObject {
        put("host", host)
        put("port", port)
        put("storage_dir", storageDir.toString())
        put("endpoint_id", endpointId)
        put("mdns_advertised", mdnsAdvertised)
        put("mdns_error", mdnsError)
        mdnsEndpoint?.let { endpoint ->
            put("mdns_endpoint", buildJsonObject {
                put("endpoint_id", endpoint.endpointId)
                put("endpoint_name", endpoint.endpointName)
                put("endpoint_kind", endpoint.endpointKind)
                put("host", endpoint.host)
                put("port", endpoint.port)
                put("protocol", endpoint.protocol)
                put("capabilities", JsonArray(endpoint.capabilities.map { JsonPrimitive(it) }))
            })
        }
    }

private fun EndpointSessionSnapshot.toJson(): JsonObject =
    buildJsonObject {
        put("connected", connected)
        put("device_id", deviceId)
        put("device_name", deviceName)
        put("firmware_version", firmwareVersion)
        put("sample_rate", sampleRate)
        activeBrainOwner?.let { put("active_brain_owner", it) }
        put("capabilities", JsonArray(capabilities.map { JsonPrimitive(it) }))
        put("messages_received", messagesReceived)
        put("last_message_type", lastMessageType)
        put("last_error", lastError)
        put("audio_bytes_received", audioBytesReceived)
        put("audio_bytes_sent", audioBytesSent)
    }

private fun DiagnosticsSnapshot.toJson() =
    companionJson.encodeToJsonElement(this)

private fun DesktopBrainSupervisorSnapshot.toJson(): JsonObject =
    buildJsonObject {
        put("running", running)
        pid?.let { put("pid", it) }
        put("host", host)
        put("port", port)
        put("script_path", scriptPath.toString())
        put("command", JsonArray(command.map { JsonPrimitive(it) }))
        startedAt?.let { put("started_at", it.toString()) }
        stoppedAt?.let { put("stopped_at", it.toString()) }
        exitCode?.let { put("exit_code", it) }
        put("recent_logs", JsonArray(recentLogs.map { JsonPrimitive(it) }))
    }
