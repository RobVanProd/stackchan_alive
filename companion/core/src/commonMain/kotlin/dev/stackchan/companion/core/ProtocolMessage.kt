package dev.stackchan.companion.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

val companionJson = Json {
    ignoreUnknownKeys = true
    encodeDefaults = true
    explicitNulls = false
}

@Serializable
data class EndpointHello(
    val type: String = "endpoint_hello",
    val protocol: String = CompanionIdentity.protocol,
    @SerialName("endpoint_id") val endpointId: String,
    @SerialName("endpoint_name") val endpointName: String,
    @SerialName("endpoint_kind") val endpointKind: String,
    @SerialName("app_version") val appVersion: String = CompanionIdentity.appVersion,
    val priority: Int,
    @SerialName("supports_binary_audio") val supportsBinaryAudio: Boolean,
    val capabilities: List<String>,
)

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
