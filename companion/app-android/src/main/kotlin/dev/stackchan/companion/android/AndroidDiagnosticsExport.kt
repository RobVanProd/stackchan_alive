package dev.stackchan.companion.android

import android.content.Context
import dev.stackchan.companion.core.EndpointHello
import dev.stackchan.companion.core.TrustedEndpoint
import java.io.File
import java.time.Instant
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

data class AndroidDiagnosticsExportResult(
    val path: String,
    val json: String,
)

fun exportAndroidDiagnostics(
    context: Context,
    endpointHello: EndpointHello,
    trustedEndpoints: List<TrustedEndpoint>,
    savedRobots: List<SavedRobot> = emptyList(),
    bridgeStatus: AndroidBridgeRuntimeStatus,
    generatedAt: Instant = Instant.now(),
): AndroidDiagnosticsExportResult {
    val json = buildAndroidDiagnosticsJson(
        endpointHello = endpointHello,
        trustedEndpoints = trustedEndpoints,
        savedRobots = savedRobots,
        bridgeStatus = bridgeStatus,
        generatedAt = generatedAt,
    ).toString()
    val outputDir = File(context.filesDir, "diagnostics").apply { mkdirs() }
    val outputFile = File(outputDir, "ANDROID_DIAGNOSTICS_EXPORT.json")
    outputFile.writeText(json)
    return AndroidDiagnosticsExportResult(
        path = outputFile.absolutePath,
        json = json,
    )
}

fun buildAndroidDiagnosticsJson(
    endpointHello: EndpointHello,
    trustedEndpoints: List<TrustedEndpoint>,
    savedRobots: List<SavedRobot> = emptyList(),
    bridgeStatus: AndroidBridgeRuntimeStatus,
    generatedAt: Instant,
): JsonObject =
    buildJsonObject {
        put("schema", "stackchan.android.diagnostics-export.v1")
        put("generated_at", generatedAt.toString())
        put("endpoint", buildJsonObject {
            put("endpoint_id", endpointHello.endpointId)
            put("endpoint_name", endpointHello.endpointName)
            put("endpoint_kind", endpointHello.endpointKind)
            put("app_version", endpointHello.appVersion)
            put("priority", endpointHello.priority)
            put("supports_binary_audio", endpointHello.supportsBinaryAudio)
            put("capabilities", JsonArray(endpointHello.capabilities.map { JsonPrimitive(it) }))
        })
        put("bridge", buildJsonObject {
            put("service_status", bridgeStatus.serviceStatus)
            put("service_detail", bridgeStatus.serviceDetail)
            put("primary_bridge_url", bridgeStatus.primaryBridgeUrl)
            put("manual_bridge_urls", JsonArray(bridgeStatus.manualBridgeUrls.map { JsonPrimitive(it) }))
            put("connection_label", bridgeStatus.connectionLabel)
            put("robot_socket_connected", bridgeStatus.robotSocketConnected)
            put("robot_state", bridgeStatus.robotState)
            put("last_message_type", bridgeStatus.lastMessageType)
            put("active_brain_owner", bridgeStatus.activeBrainOwner)
            put("text_turns_submitted", bridgeStatus.textTurnsSubmitted)
            put("last_text_turn_present", bridgeStatus.lastTextTurn.isNotBlank())
        })
        put("robot", buildJsonObject {
            put("socket_connected", bridgeStatus.robotSocketConnected)
            put("connected", bridgeStatus.robotConnected)
            put("device_id", bridgeStatus.robotId)
            put("device_name", bridgeStatus.robotName)
            put("display_name", bridgeStatus.robotDisplayName)
            put("firmware_version", bridgeStatus.firmwareVersion)
            put("fingerprint", bridgeStatus.robotFingerprint)
            put("saved_on_phone", savedRobots.any { it.robotId == bridgeStatus.robotId && bridgeStatus.robotId.isNotBlank() })
        })
        put("saved_robots", JsonArray(savedRobots.map { robot ->
            buildJsonObject {
                put("robot_id", robot.robotId)
                put("robot_name", robot.robotName)
                put("firmware_version", robot.firmwareVersion)
                put("fingerprint", robot.fingerprint)
                put("last_bridge_url", robot.lastBridgeUrl)
                put("last_seen_ms", robot.lastSeenMs)
            }
        }))
        put("trusted_endpoints", JsonArray(trustedEndpoints.map { endpoint ->
            buildJsonObject {
                put("endpoint_id", endpoint.endpointId)
                put("endpoint_name", endpoint.endpointName)
                put("endpoint_kind", endpoint.endpointKind)
                put("public_key_fingerprint", endpoint.publicKeyFingerprint)
                put("priority", endpoint.priority)
                put("auto_connect", endpoint.autoConnect)
                put("capabilities", JsonArray(endpoint.capabilities.map { JsonPrimitive(it) }))
                put("last_seen_ms", endpoint.lastSeenMs)
            }
        }))
        put("recent_logs", JsonArray(
            androidRecentLogs(endpointHello, trustedEndpoints, bridgeStatus).map { JsonPrimitive(it) },
        ))
        put("privacy", buildJsonObject {
            put("local_first", true)
            put("raw_audio_retention", "none")
            put("transcript_export", "last text turn redacted to presence only")
        })
    }
