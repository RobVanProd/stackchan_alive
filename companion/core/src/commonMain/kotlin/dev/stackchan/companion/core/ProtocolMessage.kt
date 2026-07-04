package dev.stackchan.companion.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.SerializationException
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.contentOrNull

val companionJson = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
    explicitNulls = false
}

interface BridgeMessage {
    val type: String
}

@Serializable
data class DeviceHello(
    override val type: String = "hello",
    val protocol: String = CompanionIdentity.protocol,
    @SerialName("device_id") val deviceId: String,
    @SerialName("device_name") val deviceName: String = "Stackchan Alive",
    @SerialName("firmware_version") val firmwareVersion: String = "dev",
    @SerialName("sample_rate") val sampleRate: Int = 16000,
    val capabilities: List<String> = emptyList(),
    @SerialName("trusted_endpoint_count") val trustedEndpointCount: Int = 0,
    @SerialName("active_brain_owner") val activeBrainOwner: String? = null,
) : BridgeMessage

@Serializable
data class BridgeHello(
    override val type: String = "hello",
    val protocol: String = CompanionIdentity.protocol,
    val session: String = "bench",
) : BridgeMessage

@Serializable
data class EndpointHello(
    override val type: String = "endpoint_hello",
    val protocol: String = CompanionIdentity.protocol,
    @SerialName("endpoint_id") val endpointId: String,
    @SerialName("endpoint_name") val endpointName: String,
    @SerialName("endpoint_kind") val endpointKind: String,
    @SerialName("app_version") val appVersion: String = CompanionIdentity.appVersion,
    val priority: Int,
    @SerialName("supports_binary_audio") val supportsBinaryAudio: Boolean,
    val capabilities: List<String>,
) : BridgeMessage

@Serializable
data class UtteranceStart(
    override val type: String = "utterance_start",
    val seq: Int,
    @SerialName("sample_rate") val sampleRate: Int = 16000,
) : BridgeMessage

@Serializable
data class UtteranceAudio(
    override val type: String = "utterance_audio",
    val seq: Int,
    @SerialName("pcm_b64") val pcmB64: String,
) : BridgeMessage

@Serializable
data class UtteranceEnd(
    override val type: String = "utterance_end",
    val seq: Int,
    val transcript: String? = null,
    val text: String? = null,
) : BridgeMessage

@Serializable
data class CancelMessage(
    override val type: String = "cancel",
    val seq: Int,
    val reason: String,
) : BridgeMessage

@Serializable
data class Listening(
    override val type: String = "listening",
) : BridgeMessage

@Serializable
data class Thinking(
    override val type: String = "thinking",
    val seq: Int,
) : BridgeMessage

@Serializable
data class ResponseStart(
    override val type: String = "response_start",
    val seq: Int,
    val intent: String,
    val text: String,
    val arousal: Double = 0.5,
    val valence: Double = 0.5,
) : BridgeMessage

@Serializable
data class AudioFrame(
    override val type: String = "audio",
    val seq: Int,
    val env: Double,
    val viseme: String,
    @SerialName("duration_ms") val durationMs: Int,
    val final: Boolean = false,
) : BridgeMessage

@Serializable
data class ResponseEnd(
    override val type: String = "response_end",
    val seq: Int,
) : BridgeMessage

@Serializable
data class AudioStreamStart(
    override val type: String = "audio_stream_start",
    val seq: Int,
    val format: String,
    @SerialName("sample_rate") val sampleRate: Int,
    @SerialName("audio_bytes") val audioBytes: Int,
    @SerialName("chunk_bytes") val chunkBytes: Int,
    val chunks: Int,
) : BridgeMessage

@Serializable
data class AudioStreamEnd(
    override val type: String = "audio_stream_end",
    val seq: Int,
    @SerialName("audio_bytes") val audioBytes: Int,
    val chunks: Int,
) : BridgeMessage

@Serializable
data class Heartbeat(
    override val type: String = "heartbeat",
    val seq: Int? = null,
    val owner: String? = null,
) : BridgeMessage

@Serializable
data class BridgeError(
    override val type: String = "error",
    val seq: Int? = null,
    val code: String,
    val detail: String? = null,
    val recoverable: Boolean = true,
) : BridgeMessage

@Serializable
data class ClaimBrain(
    override val type: String = "claim_brain",
    @SerialName("endpoint_id") val endpointId: String,
    val reason: String,
) : BridgeMessage

@Serializable
data class ReleaseBrain(
    override val type: String = "release_brain",
    @SerialName("endpoint_id") val endpointId: String,
    val reason: String,
) : BridgeMessage

@Serializable
data class OwnerStatus(
    override val type: String = "owner_status",
    @SerialName("active_brain_owner") val activeBrainOwner: String,
    @SerialName("owner_kind") val ownerKind: String,
    val state: String,
) : BridgeMessage

@Serializable
data class SettingsGet(
    override val type: String = "settings_get",
    val domains: List<String>,
) : BridgeMessage

@Serializable
data class SettingsSnapshot(
    override val type: String = "settings_snapshot",
    val version: Int,
    val settings: JsonObject,
) : BridgeMessage

@Serializable
data class SettingsSet(
    override val type: String = "settings_set",
    val version: Int,
    val settings: JsonObject,
) : BridgeMessage

@Serializable
data class SettingsResult(
    override val type: String = "settings_result",
    val ok: Boolean,
    val version: Int,
) : BridgeMessage

@Serializable
data class TrustedEndpoints(
    override val type: String = "trusted_endpoints",
) : BridgeMessage

@Serializable
data class TrustedEndpoint(
    @SerialName("endpoint_id") val endpointId: String,
    @SerialName("endpoint_name") val endpointName: String = "",
    @SerialName("endpoint_kind") val endpointKind: String,
    @SerialName("public_key_fingerprint") val publicKeyFingerprint: String = "",
    val priority: Int = 0,
    @SerialName("auto_connect") val autoConnect: Boolean = false,
    val capabilities: List<String> = emptyList(),
    @SerialName("last_seen_ms") val lastSeenMs: Long = 0,
)

@Serializable
data class TrustedEndpointsResult(
    override val type: String = "trusted_endpoints_result",
    val endpoints: List<TrustedEndpoint>,
) : BridgeMessage

@Serializable
data class ForgetEndpoint(
    override val type: String = "forget_endpoint",
    @SerialName("endpoint_id") val endpointId: String,
) : BridgeMessage

@Serializable
data class ForgetEndpointResult(
    override val type: String = "forget_endpoint_result",
    @SerialName("endpoint_id") val endpointId: String,
    val ok: Boolean,
) : BridgeMessage

@Serializable
data class DiagnosticsRequest(
    override val type: String = "diagnostics_request",
    val domains: List<String>,
) : BridgeMessage

@Serializable
data class DiagnosticsSnapshot(
    override val type: String = "diagnostics_snapshot",
    val bridge: JsonObject,
    val audio: JsonObject? = null,
    val model: JsonObject? = null,
    val firmware: JsonObject? = null,
    val battery: JsonObject? = null,
) : BridgeMessage

@Serializable
data class CapabilityUpdate(
    override val type: String = "capability_update",
    @SerialName("endpoint_id") val endpointId: String,
    val capabilities: List<String>,
) : BridgeMessage

data class UnknownMessage(
    override val type: String,
    val raw: JsonObject,
) : BridgeMessage

fun defaultDesktopEndpointHello(endpointId: String = "pc-companion-c0"): EndpointHello =
    EndpointHello(
        endpointId = endpointId,
        endpointName = "Stackchan Desktop Companion",
        endpointKind = "pc",
        priority = 50,
        supportsBinaryAudio = true,
        capabilities = listOf("settings", "diagnostics"),
    )

fun defaultAndroidEndpointHello(endpointId: String = "android-companion-c0"): EndpointHello =
    EndpointHello(
        endpointId = endpointId,
        endpointName = "Stackchan Android Companion",
        endpointKind = "android",
        priority = 60,
        supportsBinaryAudio = true,
        capabilities = listOf("settings", "diagnostics", "persona_select"),
    )

fun decodeControlMessage(text: String): BridgeMessage {
    val element = companionJson.parseToJsonElement(text)
    if (element !is JsonObject) {
        throw SerializationException("control message must be a JSON object")
    }
    val type = element["type"]?.jsonPrimitive?.contentOrNull
        ?: throw SerializationException("control message missing type")
    val protocol = element["protocol"]?.jsonPrimitive?.contentOrNull
    if (protocol != null && protocol != CompanionIdentity.protocol) {
        throw SerializationException("unsupported protocol: $protocol")
    }

    return when (type) {
        "hello" -> if ("device_id" in element) decodeAs<DeviceHello>(element) else decodeAs<BridgeHello>(element)
        "endpoint_hello" -> decodeAs<EndpointHello>(element)
        "utterance_start" -> decodeAs<UtteranceStart>(element)
        "utterance_audio" -> decodeAs<UtteranceAudio>(element)
        "utterance_end" -> decodeAs<UtteranceEnd>(element)
        "cancel" -> decodeAs<CancelMessage>(element)
        "listening" -> decodeAs<Listening>(element)
        "thinking" -> decodeAs<Thinking>(element)
        "response_start" -> decodeAs<ResponseStart>(element)
        "audio" -> decodeAs<AudioFrame>(element)
        "response_end" -> decodeAs<ResponseEnd>(element)
        "audio_stream_start" -> decodeAs<AudioStreamStart>(element)
        "audio_stream_end" -> decodeAs<AudioStreamEnd>(element)
        "heartbeat" -> decodeAs<Heartbeat>(element)
        "error" -> decodeAs<BridgeError>(element)
        "claim_brain" -> decodeAs<ClaimBrain>(element)
        "release_brain" -> decodeAs<ReleaseBrain>(element)
        "owner_status" -> decodeAs<OwnerStatus>(element)
        "settings_get" -> decodeAs<SettingsGet>(element)
        "settings_snapshot" -> decodeAs<SettingsSnapshot>(element)
        "settings_set" -> decodeAs<SettingsSet>(element)
        "settings_result" -> decodeAs<SettingsResult>(element)
        "trusted_endpoints" -> decodeAs<TrustedEndpoints>(element)
        "trusted_endpoints_result" -> decodeAs<TrustedEndpointsResult>(element)
        "forget_endpoint" -> decodeAs<ForgetEndpoint>(element)
        "forget_endpoint_result" -> decodeAs<ForgetEndpointResult>(element)
        "diagnostics_request" -> decodeAs<DiagnosticsRequest>(element)
        "diagnostics_snapshot" -> decodeAs<DiagnosticsSnapshot>(element)
        "capability_update" -> decodeAs<CapabilityUpdate>(element)
        else -> UnknownMessage(type = type, raw = element)
    }
}

inline fun <reified T : BridgeMessage> decodeAs(element: JsonObject): T =
    companionJson.decodeFromJsonElement(element)

fun encodeControlMessage(message: BridgeMessage): String {
    val element = when (message) {
        is DeviceHello -> companionJson.encodeToJsonElement(message)
        is BridgeHello -> companionJson.encodeToJsonElement(message)
        is EndpointHello -> companionJson.encodeToJsonElement(message)
        is UtteranceStart -> companionJson.encodeToJsonElement(message)
        is UtteranceAudio -> companionJson.encodeToJsonElement(message)
        is UtteranceEnd -> companionJson.encodeToJsonElement(message)
        is CancelMessage -> companionJson.encodeToJsonElement(message)
        is Listening -> companionJson.encodeToJsonElement(message)
        is Thinking -> companionJson.encodeToJsonElement(message)
        is ResponseStart -> companionJson.encodeToJsonElement(message)
        is AudioFrame -> companionJson.encodeToJsonElement(message)
        is ResponseEnd -> companionJson.encodeToJsonElement(message)
        is AudioStreamStart -> companionJson.encodeToJsonElement(message)
        is AudioStreamEnd -> companionJson.encodeToJsonElement(message)
        is Heartbeat -> companionJson.encodeToJsonElement(message)
        is BridgeError -> companionJson.encodeToJsonElement(message)
        is ClaimBrain -> companionJson.encodeToJsonElement(message)
        is ReleaseBrain -> companionJson.encodeToJsonElement(message)
        is OwnerStatus -> companionJson.encodeToJsonElement(message)
        is SettingsGet -> companionJson.encodeToJsonElement(message)
        is SettingsSnapshot -> companionJson.encodeToJsonElement(message)
        is SettingsSet -> companionJson.encodeToJsonElement(message)
        is SettingsResult -> companionJson.encodeToJsonElement(message)
        is TrustedEndpoints -> companionJson.encodeToJsonElement(message)
        is TrustedEndpointsResult -> companionJson.encodeToJsonElement(message)
        is ForgetEndpoint -> companionJson.encodeToJsonElement(message)
        is ForgetEndpointResult -> companionJson.encodeToJsonElement(message)
        is DiagnosticsRequest -> companionJson.encodeToJsonElement(message)
        is DiagnosticsSnapshot -> companionJson.encodeToJsonElement(message)
        is CapabilityUpdate -> companionJson.encodeToJsonElement(message)
        is UnknownMessage -> message.raw
        else -> throw SerializationException("unsupported message implementation: ${message::class}")
    }
    return element.toString()
}
